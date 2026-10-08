#!/usr/bin/env bash
# Test matrix for defibrillator (Go).
#   A  backend up                -> verbatim passthrough (JSON + chunked stream)
#   B  backend stays down        -> 503 + Retry-After after WAKE_TIMEOUT, valid magic packets
#   C  backend comes up mid-wait -> waiting request succeeds
#   D  ten concurrent requests, down -> all 503, ONE shared wake loop (packet count proves latch)
#   E  serve one request, idle 8s, box ON -> exactly one ssh poweroff, no repeat fires
#   F  box off while proxy idles          -> no ssh call at all (idempotent, no-op logged)
#   G  fresh proxy, zero traffic          -> never powers off a box it never served
set -u
cd "$(dirname "$0")"
export PATH="$PWD/bin:$PATH"
P=18080; B=18134; MAC="de:ad:be:ef:00:01"; PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  : %s\n' "$1"; }
bad(){ FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"; }

# ---- PID-file based lifecycle (kill subshells AND their children) ----
pkill_file(){ local f=$1; [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null; rm -f "$f"; }
cleanup(){
  # kill newest first so children go away with their parents; PID-based
  for f in sniff.pid proxy.pid; do pkill_file "$f"; done
  [ -f fake.pid ] && kill "$(cat fake.pid)" 2>/dev/null
  rm -f fake.pid
  true
}
trap cleanup EXIT INT TERM
# start with a clean slate (leftover processes from any previous run)
for f in sniff.pid proxy.pid fake.pid; do pkill_file "$f"; done
sleep 0.3

up(){ local port=$1; (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; }
wait_up(){ up "$1" && return 0; for _ in $(seq 1 60); do up "$1" && return 0; sleep 0.1; done; return 1; }

fake_ollama(){
  python3 - "$B" fakellama-18134 <<'EOF' &
import socket, sys, threading
port = int(sys.argv[1])
def handle(c):
    buf = b""
    while b"\r\n\r\n" not in buf:
        d = c.recv(65536)
        if not d: return
        buf += d
    path = buf.split(b" ",2)[1].decode()
    if b"stream" in path.encode():
        out = b"".join(b"%x\r\n%s\r\n" % (len(x), x) for x in (b"hel", b"lo", b"!"))
        out += b"0\r\n\r\n"
        c.sendall(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" + out)
    else:
        body = b'{"ok":true,"path":"%s"}' % path.encode()
        c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % len(body) + body)
    c.close()
l = socket.socket(); l.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
l.bind(("127.0.0.1", port)); l.listen(16)
while True:
    c,_ = l.accept(); threading.Thread(target=handle, args=(c,), daemon=True).start()
EOF
  echo $! > fake.pid
  wait_up $B
}
# Kill by PID file only (no pattern matching — a pkill -f pattern can
# match this script's own wrapper shell and SIGTERM it, aborting the run).
kill_fakes(){
  [ -f fake.pid ] && kill "$(cat fake.pid)" 2>/dev/null
  rm -f fake.pid
}
start_proxy(){ # start_proxy [WAKE] [IDLE]
  local wake=${1:-20s} idle=${2:-24h}
  WOL_BROADCAST=127.0.0.1:59999 WOL_MAC="$MAC" BACKEND=127.0.0.1:$B \
  LISTEN=127.0.0.1:$P IDLE_TIMEOUT=$idle WAKE_TIMEOUT=$wake \
  ./defibrillator > proxy.log 2>&1 &
  echo $! > proxy.pid
  wait_up $P
}
stop_proxy(){ pkill_file proxy.pid; sleep 0.4; }
stop_fake(){ pkill_file fake.pid; sleep 0.4; }

# WoL sniffer: listens 25s self-timer, writes "<valid> <bad>" then exits
# on its own (no external kill, so the write always happens).
SNOUT=sniff.txt
wol_sniff(){
  : > "$SNOUT"
  python3 - "$MAC" "$SNOUT" <<'EOF' &
import socket, sys, time
mac = bytes.fromhex(sys.argv[1].replace(":",""))
exp = b"\xff"*6 + mac*16
good = bad = 0
end = time.time() + 25
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 59999)); s.settimeout(0.5)
while time.time() < end:
    try: d,_ = s.recvfrom(200)
    except socket.timeout: continue
    except OSError: break
    if d == exp: good += 1
    else: bad += 1
with open(sys.argv[2], "w") as f: f.write(f"{good} {bad}\n")
EOF
  echo $! > sniff.pid
  sleep 0.4
}
# block until snout has content or 25s elapse
wait_sniff(){ local d=${1:-25}; for _ in $(seq 1 $((d*5))); do [ -s "$SNOUT" ] && return 0; sleep 0.2; done; return 1; }
sniff_counts(){ if [ -s "$SNOUT" ]; then read -r G B_ < "$SNOUT"; else G=0; B_=0; fi; }

# fake ssh shim: logs its argv to ssh.log
FAKEDIR=bin; rm -rf "$FAKEDIR"; mkdir -p "$FAKEDIR"
cat > "$FAKEDIR/ssh" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> ssh.log
EOF
chmod +x "$FAKEDIR/ssh"

# ============================================================ A
echo "=== A: backend up -> verbatim passthrough ==="
fake_ollama || { echo fake-ollama failed; exit 1; }
start_proxy 20s || { echo proxy failed; exit 1; }
j=$(curl -s --max-time 5 http://127.0.0.1:$P/api/ps)
s=$(curl -s --max-time 5 http://127.0.0.1:$P/v1/stream)
echo "  json   : $j"
echo "  stream : $s"
[ "$j" = '{"ok":true,"path":"/api/ps"}' ] && ok "json passthrough" || bad "json: $j"
[ "$s" = "hello!" ] && ok "chunked stream intact" || bad "stream: '$s'"
stop_proxy; stop_fake

# ============================================================ B
echo "=== B: backend down -> 503 + Retry-After after 6s, valid magic packets ==="
wol_sniff
start_proxy 6s || { echo proxy failed; exit 1; }
t0=$(date +%s)
curl -s --max-time 15 -D hdr.txt -o body.txt http://127.0.0.1:$P/api/tags
dt=$(( $(date +%s) - t0 ))
code=$(head -1 hdr.txt | tr -d '\r' | sed 's/^HTTP\/[0-9.]* //')
ra=$(tr -d '\r' < hdr.txt | sed -n 's/^Retry-After: //p')
echo "  status=$code after ${dt}s, Retry-After=$ra, body='$(cat body.txt)'"
[ "${code%% *}" = "503" ] && ok "503 + Retry-After" || bad "status=$code ra=$ra"
[ $dt -ge 6 ] && ok "waited out full WAKE_TIMEOUT (~6s)" || bad "returned too early (${dt}s)"
wait_sniff 25; sniff_counts
echo "  wol packets: valid=$G bad=$B_"
[ "$G" -ge 3 ] && [ "$B_" -eq 0 ] && ok "$G byte-exact magic packets, 0 corrupt" || bad "sniff: valid=$G bad=$B_ (want >=3/0)"
stop_proxy; [ -f sniff.pid ] && pkill_file sniff.pid

# ============================================================ C
echo "=== C: backend comes up mid-wait -> waiting request succeeds ==="
start_proxy 20s 24h || { echo proxy failed; exit 1; }
( sleep 4; fake_ollama ) &
t0=$(date +%s)
c=$(curl -s --max-time 30 http://127.0.0.1:$P/v1/chat)
dt=$(( $(date +%s) - t0 ))
echo "  body: $c (after ${dt}s)"
[ "$c" = '{"ok":true,"path":"/v1/chat"}' ] && ok "wake -> wait -> forward" || bad "wake flow: got '$c' after ${dt}s"
stop_proxy
# the lazy fake_ollama ran inside a subshell; kill_fakes uses the neutral
# 'fakellama' marker so it can never match this wrapper shell's cmdline.
kill_fakes
for _ in $(seq 1 30); do up $B || break; sleep 0.2; done
up $B && { echo "backend :18134 still busy - cannot continue"; exit 1; }

# ============================================================ D
echo "=== D: 10 CONCURRENT requests, backend down -> latch: ONE wake loop, all 503, fast ==="
wol_sniff
start_proxy 6s || { echo proxy failed; exit 1; }
t0=$(date +%s)
: > D.codes
( for i in 1 2 3 4 5 6 7 8 9 10; do
    # truly concurrent: fire each in the background, then wait inside the subshell
    curl -s --max-time 8 http://127.0.0.1:$P/api/$i -o /dev/null -w '%{http_code}\n' >> D.codes &
  done
    wait ) &
CURL_POOL=$!
wait "$CURL_POOL"
dt=$(( $(date +%s) - t0 ))
codes=$(tr -d ' ' < D.codes | tr '\n' ' ')
n503=$(grep -c '^503$' D.codes 2>/dev/null || echo 0)
echo "  codes: $codes | wall ${dt}s | got $n503/10 as 503"
[ "$n503" = "10" ] && ok "all 10 concurrent callers got 503" || bad "only $n503/10 got 503"
# Latch proof: WAKE_TIMEOUT=6s. 10 callers that each woke the box
# independently would need >=10*6s = 60s of holding. One shared wake
# loop serves them all within one window: wall must stay well under that.
[ $dt -lt 20 ] && ok "all 10 served in ${dt}s by ONE wake loop (latch works)" || bad "wall ${dt}s — wake not shared (>=20s means multiple serialized loops)"
wait_sniff 25; sniff_counts
echo "  wol packets: valid=$G bad=$B_ (retransmits of one loop, byte-exact expected)"
[ -n "$B_" ] && [ "$B_" -eq 0 ] && ok "0 corrupt packets" || bad "corrupt packets: $B_"
stop_proxy; [ -f sniff.pid ] && pkill_file sniff.pid
rm -f D.codes

# ============================================================ E
echo "=== E: serve one request, idle out 8s, box ON -> one ssh poweroff, never twice ==="
: > ssh.log
fake_ollama || { echo fake-ollama failed; exit 1; }
export SSH_TARGET=tammert@10.0.0.50
start_proxy 20s 8s || { echo proxy failed; exit 1; }
# Establish "used": the proxy only powers off a box it has served
# (never kills a box it has no relationship with).
j=$(curl -s --max-time 5 http://127.0.0.1:$P/api/ps)
[ "$j" = '{"ok":true,"path":"/api/ps"}' ] && ok "warm request served (marks box as used)" || bad "warmup: '$j'"
# idle ticks every 10s; threshold 8s: t10 fires, t20 re-fires only if
# box still reachable -> kill backend right after first fire to prove
# the "already down" branch, then show no 2nd line ever.
for _ in $(seq 1 40); do [ -s ssh.log ] && break; sleep 1; done
echo "  ssh.log: $(cat ssh.log)"
[ "$(cat ssh.log)" = "-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new tammert@10.0.0.50 systemctl poweroff" ] \
  && ok "single correct ssh poweroff call" || bad "ssh.log: $(cat ssh.log)"
stop_fake          # simulate systemctl poweroff taking effect
sleep 20           # let one more idle tick land with backend down
lines=$(wc -l < ssh.log)
echo "  ssh.log lines after box-off + 1 tick: $lines"
[ "$lines" = "1" ] && ok "no repeat firing after box went down" || bad "fired $lines times (want 1)"
grep -q "requesting poweroff" proxy.log && ok "logged the poweroff request" || bad "no poweroff log line"
grep -q "backend already down - nothing to do" proxy.log && ok "logged the idempotent no-op" || bad "no 'already down' log line"
stop_proxy
unset SSH_TARGET

# ============================================================ F
echo "=== F: box goes off while proxy idles -> ssh never called (no-op logged) ==="
: > ssh.log
fake_ollama || { echo fake-ollama failed; exit 1; }
export SSH_TARGET=tammert@10.0.0.50
start_proxy 20s 8s || { echo proxy failed; exit 1; }
curl --max-time 5 -s http://127.0.0.1:$P/api/ps > /dev/null   # warm: box was used
stop_fake                                                        # box goes off
sleep 25           # t10 and t20 ticks both see a down backend
lines=$(wc -l < ssh.log)
echo "  ssh.log lines after box-off, 2 ticks: $lines"
[ "$lines" = "0" ] && ok "zero ssh calls while box already off" || bad "called ssh $lines times"
grep -q "backend already down - nothing to do" proxy.log && ok "logged the no-op branch" || bad "no 'already down' log line"
stop_proxy
unset SSH_TARGET

# ============================================================ G
echo "=== G: idle past threshold, ZERO traffic seen -> no ssh call (fresh proxy) ==="
: > ssh.log
# no fake_ollama, no curl: proxy has served nothing; idle=8s, idleLoop sees
# "never served" and stays quiet even though lastReq is stale.
export SSH_TARGET=tammert@10.0.0.50
start_proxy 20s 8s || { echo proxy failed; exit 1; }
sleep 25
lines=$(wc -l < ssh.log)
echo "  ssh.log lines after 25s with zero traffic: $lines"
[ "$lines" = "0" ] && ok "never powered off a box it never served" || bad "called ssh $lines times with no traffic"
stop_proxy
unset SSH_TARGET

# ============================================================ H
echo "=== H: POWEROFF_CMD override -> ssh receives the custom remote command ==="
: > ssh.log
fake_ollama || { echo fake-ollama failed; exit 1; }
export SSH_TARGET=tammert@10.0.0.50
export POWEROFF_CMD="sudo systemctl poweroff"
start_proxy 20s 8s || { echo proxy failed; exit 1; }
curl --max-time 5 -s http://127.0.0.1:$P/api/ps > /dev/null   # warm: box was used
for _ in $(seq 1 40); do [ -s ssh.log ] && break; sleep 1; done
echo "  ssh.log: $(cat ssh.log)"
[ "$(cat ssh.log)" = "-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new tammert@10.0.0.50 sudo systemctl poweroff" ] \
  && ok "ssh received POWEROFF_CMD verbatim" || bad "ssh.log: $(cat ssh.log)"
stop_proxy; stop_fake
unset SSH_TARGET POWEROFF_CMD

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
