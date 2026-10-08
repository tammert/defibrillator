# defibrillator

shocks your LLM server back to life over the network when someone asks for a reply, and lets it flatline again when you're done

A single-binary reverse proxy for an Ollama endpoint that lives on a box
you power off when idle (S5, `systemctl poweroff`). defibrillator sits
between your clients and the box and closes the loop:

- **request + box is on** → forward the request verbatim
  (SSE / chunked streaming intact, `FlushInterval: -1`).
- **request + box is off** → send a Wake-on-LAN magic packet, wait up to
  `WAKE_TIMEOUT` (retransmitting every 3s and probing the backend) until
  Ollama accepts TCP, then forward. **Every concurrent request that
  arrives while the box is booting joins the same wake round** — one
  packet loop, one timeout, no stampede.
- **no request for `IDLE_TIMEOUT`** → `ssh `$SSH_TARGET` systemctl
  poweroff``. Idempotent: if the backend is already unreachable the box
  is already off and nothing is sent. A proxy that has never served a
  request never powers the box off (it may be running ahead of the box
  coming online).

Go stdlib only. No deps. No CGO. One file + `go build`.

## Quickstart

```sh
go build -o defibrillator .
WOL_MAC=aa:bb:cc:dd:ee:ff ./defibrillator          # WOL_MAC is required
```

Or Docker (multi-stage; Alpine base carries the `ssh` client the idle
poweroff shells out to — a bare `scratch` image cannot do SSH at all):

```sh
docker build -t tammert/defibrillator .
docker run --rm -it \
  --network host \
  -e WOL_MAC=aa:bb:cc:dd:ee:ff \
  -e BACKEND=192.168.1.50:11434 \
  -e SSH_TARGET=tammert@192.168.1.50 \
  -v ~/.ssh/defibrillator:/root/.ssh:ro \
  tammert/defibrillator
```

`--network host` is required: the proxy needs to emit unicast
WOL (UDP `:9`) and reach the LAN directly. For idle poweroff the ssh
key lives in a read-only mount on `/root/.ssh` (dir `700`, key `600`).

## Deploying next to hermes-agent

`docker-compose.yml` + `.env.example` run the full loop on one small
box (e.g. a NAS): the gateway, its always-on small model, and this
proxy for the big model on the sleep-and-wake GPU box. Hermes points
its OpenAI-compatible provider at `http://127.0.0.1:8080/v1`, so every
turn goes through the proxy and the idle clock counts real usage:

```sh
cp .env.example .env   # fill WOL_MAC, HERMES_API_KEY (+ SSH_TARGET)
mkdir -p ssh && cp your_ed25519_key ssh/id_ed25519 && chmod 600 ssh/id_ed25519
chmod 700 ssh && chown -R root:root ssh   # the 5090 must accept this key
docker compose up -d
```

## Configuration

All via environment variables. Defaults in parentheses.

| var             | default             | notes                                                        |
|-----------------|---------------------|--------------------------------------------------------------|
| `LISTEN`        | `:8080`             | address to bind                                              |
| `BACKEND`       | `127.0.0.1:11434`   | Ollama (OpenAI V1) endpoint on the GPU box                   |
| `WOL_MAC`       | *(required)*        | NIC MAC of the box, `aa:bb:cc:dd:ee:ff`                      |
| `WOL_BROADCAST` | `255.255.255.255:9` | WoL destination. Use the box's own `ip:9` on a routed LAN    |
| `WAKE_TIMEOUT`  | `5m`                | how long to wait for the box to come up per request          |
| `IDLE_TIMEOUT`  | `30m`               | silence before the proxy asks the box to power off           |
| `SSH_TARGET`    | *(unset)*           | `user@box`; empty/absent disables idle shutdown entirely     |
| `POWEROFF_CMD`  | `systemctl poweroff` | remote command executed over ssh; use `sudo systemctl poweroff` on boxes without polkit |

`WAKE_TIMEOUT` applies per wake round, per request that joined it — a
client never waits longer than that.

## Behaviour details

- **Power-state is stateless.** Each decision probes the backend (`TCP
  connect`, 1.5s). There is no `awake=true` flag in the proxy that can
  lie; a box that died mid-request gets re-woken on the next request.
- **Shared wake.** `acquireRound` hands every caller waiting on a down
  backend the same `*wakeRound`; the leader's goroutine runs the packet
  loop and `close(done)` broadcasts the outcome to all waiters at once.
- **SSE-friendly.** `httputil.ReverseProxy` with `FlushInterval: -1`
  forwards chunks as they arrive; response bodies stream through.
- **Graceful shutdown** on SIGINT/SIGTERM.
- **ASCII-only log and client strings.**

## Test matrix

`test.sh` runs a full scenario matrix with a fake Ollama and a local
WoL sniffer on `127.0.0.1:59999` (no LAN, no real GPU box, no sshd
needed — ssh is stubbed with a fake `bin/ssh`):

| | scenario | asserts |
|---|---|---|
| A | backend up | JSON + chunked stream pass through verbatim |
| B | backend stays down | 503 + `Retry-After` after `WAKE_TIMEOUT`; N byte-exact magic packets, 0 corrupt |
| C | backend comes up mid-wait | waiting request succeeds within budget |
| D | 10 concurrent requests, down | all 503 (or success if late), all in one wake loop — packet count proves latch |
| E | serve → idle past threshold → box on | exactly one correct `ssh … systemctl poweroff`; no repeat after box off |
| F | box off while proxy idles | zero ssh calls; "already down" logged |
| G | fresh proxy, zero traffic | never powers off a box it never served |

```sh
bash test.sh           # 17 assertions
```

## Requirements on the box side (not part of this repo)

- BIOS / UEFI **Wake on LAN from S5 / hard-off** enabled on the NIC and
  on the BMC/UEFI path that owns it.
- An SSH user that can run `systemctl poweroff` keylessly (or an
  authorized `sudoers` entry). defibrillator calls ssh with
  `BatchMode=yes`, so it fails fast if the key isn't set up.
- LUKS on the disk: use a keyfile (or `tpm2-totp`) so S5 → S0 boot
  doesn't hang at a passphrase prompt. If the box cannot boot
  unattended, WOL wakes a box that still needs you at the keyboard.

## Roadmap / not done

- Health probe: currently the proxy considers the backend "up" as soon
  as any TCP connect succeeds. A real HTTP `/api/version` poll would be
  stricter, but it costs the box extra wake-time before first reply.
- TLS on the proxy itself. Put a real terminator in front.

## License

MIT — see [LICENSE](LICENSE).
