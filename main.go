// defibrillator: a reverse proxy in front of an Ollama (OpenAI V1)
// endpoint that lives on a box which powers off when idle.
//
//   - Request + backend up   -> forward verbatim (SSE streaming included).
//   - Request + backend down -> send a WoL magic packet, wait (retrying
//     every few seconds, up to WAKE_TIMEOUT) for Ollama to accept TCP,
//     then forward. Concurrent requests share one wake (mutex latch).
//   - No request for IDLE_TIMEOUT and the backend is reachable
//     -> ssh SSH_TARGET 'systemctl poweroff'.
//     If the backend is already down the box is already off: no-op.
//
// Stdlib only. Configure via environment variables.
package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

type config struct {
	listen      string
	backend     string // ollama host:port on the GPU box
	mac         net.HardwareAddr
	broadcast   string // WoL destination, default 255.255.255.255:9
	wakeTimeout time.Duration
	idleTimeout time.Duration
	sshTarget   string // e.g. "tammert@192.168.1.50"; empty disables shutdown
}

type proxy struct {
	cfg        config
	rp         *httputil.ReverseProxy
	servedOnce atomic.Bool  // has any request been handled? (gates poweroff)
	lastReq    atomic.Int64 // unix nanos of the most recent request

	roundMu sync.Mutex
	round   *wakeRound // in-flight wake shared by all concurrent callers
}

// wakeRound is one WoL wake shared by every request that arrives while
// the box is coming up. done is closed exactly once when the round
// resolves; closing a channel broadcasts to all waiters, which then
// read the guarded outcome field (a channel value would be claimed by
// a single receiver).
type wakeRound struct {
	done chan struct{}
	mu   sync.Mutex
	err  error
}

func newWakeRound() *wakeRound { return &wakeRound{done: make(chan struct{})} }

// setErr records the round's outcome; exactly one call, from runRound,
// and always before close(round.done), so the close happens-before the
// waiters read it (result is also mutex-guarded for clarity).
func (r *wakeRound) setErr(err error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.err = err
}

func (r *wakeRound) result() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.err
}

func envOr(key, def string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return def
}

func envDuration(key string, def time.Duration) time.Duration {
	v := strings.TrimSpace(os.Getenv(key))
	if v == "" {
		return def
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		log.Fatalf("%s: %v (want e.g. 10s, 30m, 1h)", key, err)
	}
	return d
}

func newConfig() (config, error) {
	c := config{
		listen:      envOr("LISTEN", ":8080"),
		backend:     envOr("BACKEND", "127.0.0.1:11434"),
		broadcast:   envOr("WOL_BROADCAST", "255.255.255.255:9"),
		wakeTimeout: envDuration("WAKE_TIMEOUT", 5*time.Minute),
		idleTimeout: envDuration("IDLE_TIMEOUT", 30*time.Minute),
		sshTarget:   envOr("SSH_TARGET", ""),
	}
	raw := strings.TrimSpace(os.Getenv("WOL_MAC"))
	if raw == "" {
		return c, errors.New("WOL_MAC is required, e.g. AA:BB:CC:DD:EE:FF")
	}
	m, err := net.ParseMAC(raw)
	if err != nil {
		return c, fmt.Errorf("WOL_MAC: %w", err)
	}
	c.mac = m
	return c, nil
}

// reachable reports whether the backend accepts a TCP connection.
func reachable(addr string) bool {
	c, err := net.DialTimeout("tcp", addr, 1500*time.Millisecond)
	if err != nil {
		return false
	}
	_ = c.Close()
	return true
}

// magicPacket: 6 x 0xFF followed by the MAC address repeated 16 times.
func magicPacket(mac net.HardwareAddr) []byte {
	pkt := bytes.Repeat([]byte{0xFF}, 6)
	for range 16 {
		pkt = append(pkt, mac...)
	}
	return pkt
}

func sendWoL(mac net.HardwareAddr, broadcast string) error {
	conn, err := net.Dial("udp", broadcast)
	if err != nil {
		return fmt.Errorf("dial %s: %w", broadcast, err)
	}
	defer conn.Close()
	_, err = conn.Write(magicPacket(mac))
	return err
}

// ensureAwake blocks until the backend accepts TCP. If it is down it
// joins (or starts) the in-flight wake round: one WoL loop with
// retransmits every 3s, bounded by WAKE_TIMEOUT, shared by every
// request that is waiting on it.
func (p *proxy) ensureAwake(ctx context.Context) error {
	if reachable(p.cfg.backend) {
		return nil
	}
	round := p.acquireRound()
	select {
	case <-round.done:
	case <-ctx.Done():
		return ctx.Err()
	}
	return round.result()
}

// acquireRound joins the in-flight wake round if there is one, or
// starts the next one. One leader loop runs per round: the caller that
// created it drives the wake, and close(round.done) wakes every waiting
// caller at once when the box is up (or the timeout is reached).
func (p *proxy) acquireRound() *wakeRound {
	p.roundMu.Lock()
	defer p.roundMu.Unlock()

	if p.round != nil {
		select {
		case <-p.round.done:
			// already resolved: fall through and start a fresh round
		default:
			return p.round // join the in-flight one
		}
	}

	round := newWakeRound()
	p.round = round
	log.Printf("backend %s down - wake started (mac %s, timeout %s)",
		p.cfg.backend, p.cfg.mac, p.cfg.wakeTimeout)
	go p.runRound(round)
	return round
}

// runRound is the single wake loop for one round. Exactly one of the
// two exits sets no error (box came up) or the timeout error.
func (p *proxy) runRound(r *wakeRound) {
	defer func() {
		p.roundMu.Lock()
		if p.round == r {
			p.round = nil
		}
		p.roundMu.Unlock()
		close(r.done)
	}()
	deadline := time.Now().Add(p.cfg.wakeTimeout)
	for {
		if err := sendWoL(p.cfg.mac, p.cfg.broadcast); err != nil {
			log.Printf("wol: %v", err)
		}
		if reachable(p.cfg.backend) {
			log.Printf("backend %s is up", p.cfg.backend)
			return
		}
		if time.Now().After(deadline) {
			r.setErr(errors.New("backend did not come up within WAKE_TIMEOUT"))
			return
		}
		time.Sleep(3 * time.Second)
	}
}

func (p *proxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	p.lastReq.Store(time.Now().UnixNano())
	p.servedOnce.Store(true)
	if err := p.ensureAwake(r.Context()); err != nil {
		log.Printf("%s %s: %v", r.Method, r.URL.Path, err)
		w.Header().Set("Retry-After", "10")
		http.Error(w, "ollama box is powering on - retry shortly",
			http.StatusServiceUnavailable)
		return
	}
	p.rp.ServeHTTP(w, r)
}

// poweroff asks the box to shut down over SSH (10s cap so a hung ssh
// cannot wedge the idle loop).
func (p *proxy) poweroff(ctx context.Context) error {
	cctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	out, err := exec.CommandContext(cctx,
		"ssh",
		"-o", "BatchMode=yes",
		"-o", "ConnectTimeout=5",
		"-o", "StrictHostKeyChecking=accept-new",
		p.cfg.sshTarget,
		"systemctl poweroff",
	).CombinedOutput()
	if err != nil {
		return fmt.Errorf("%w: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

// idleLoop asks the box to power off after IDLE_TIMEOUT of silence.
// Ticks every 10s; while idle past the threshold it first checks whether
// the box is even on, so it never SSHes an already-dead box.
func (p *proxy) idleLoop(ctx context.Context) {
	if p.cfg.sshTarget == "" {
		log.Printf("idle shutdown disabled (no SSH_TARGET)")
		return
	}
	log.Printf("idle shutdown: no traffic for %s -> ssh %s",
		p.cfg.idleTimeout, p.cfg.sshTarget)

	t := time.NewTicker(10 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		idled := time.Since(time.Unix(0, p.lastReq.Load()))
		if idled < p.cfg.idleTimeout {
			continue
		}
		// Never power off a box we have not served a single request:
		// the proxy may be running ahead of the box coming online.
		if !p.servedOnce.Load() {
			continue
		}
		if !reachable(p.cfg.backend) {
			log.Printf("idle %s but backend already down - nothing to do",
				idled.Round(time.Second))
			p.lastReq.Store(time.Now().UnixNano())
			continue
		}
		log.Printf("idle %s - requesting poweroff of %s",
			idled.Round(time.Second), p.cfg.sshTarget)
		if err := p.poweroff(ctx); err != nil {
			log.Printf("poweroff request failed: %v", err)
		} else {
			log.Printf("poweroff requested")
		}
		// Box is shutting down; restart the clock so we don't retry
		// against a half-dead box for the next IDLE_TIMEOUT.
		p.lastReq.Store(time.Now().UnixNano())
	}
}

func newProxy(c config) *proxy {
	p := &proxy{
		cfg: c,
		rp: &httputil.ReverseProxy{
			Director: func(r *http.Request) {
				r.URL.Scheme = "http"
				r.URL.Host = c.backend
				r.Host = c.backend
			},
			FlushInterval: -1, // forward SSE chunks immediately
		},
	}
	return p
}

func main() {
	cfg, err := newConfig()
	if err != nil {
		log.Fatal(err)
	}
	ctx, cancel := signal.NotifyContext(context.Background(),
		os.Interrupt, syscall.SIGTERM)
	defer cancel()

	p := newProxy(cfg)
	go p.idleLoop(ctx)

	srv := &http.Server{Addr: cfg.listen, Handler: p}
	go func() {
		<-ctx.Done()
		shutdownCtx, c := context.WithTimeout(context.Background(), 5*time.Second)
		defer c()
		_ = srv.Shutdown(shutdownCtx)
	}()

	log.Printf("defibrillator: listening on %s -> %s (wake %s, idle %s)",
		cfg.listen, cfg.backend, cfg.wakeTimeout, cfg.idleTimeout)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}
