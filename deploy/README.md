# Deploy

One Linux host runs the whole server side with docker compose: Caddy (TLS), LiveKit Server, the token API and the coach agent. Design and port rationale: `docs/spec.md` section 10.

Deployed and verified on 2026-11-22 on a 2 vCPU / 4 GB Hong Kong host (Ubuntu 24.04, Docker 29.10, Compose v5.8): certificate issuance, token API, webhook isolation and a voice smoke test over both UDP and the 7881/TCP fallback (`docs/spec.md` 14.1). The image build and `docker compose config` also run in CI.

## Files

| File | Purpose |
|---|---|
| `docker-compose.yml` | the four services, all with host networking (as in LiveKit's VM guide; WebRTC needs the host's UDP ports) |
| `Caddyfile` | TLS for `COACHW_DOMAIN`; `/v1/*` → token API, everything else → LiveKit signalling |
| `livekit.yaml` | production LiveKit config; keys, webhook key and public IP come from the environment |
| `livekit.dev.yaml` | local config used by `scripts/dev.sh` |
| `.env.example` | every setting; copy to `deploy/.env` on the host |
| `../server/Dockerfile` | one image for both `coachw.api` and `coachw.agent` |

## Prerequisites

- Linux host, 2 vCPU / 4 GB or more, public IPv4, Docker with the compose plugin.
- A domain whose A record points at the host. Mainland China hosts need ICP filing before serving 80/443 on a domain; otherwise use Hong Kong (spec 10).
- Firewall / security group inbound:

| Port | Use |
|---|---|
| 80/TCP | Let's Encrypt HTTP challenge, redirect to HTTPS |
| 443/TCP | HTTPS: token API and LiveKit signalling (WebSocket) through Caddy |
| 7881/TCP | WebRTC over TCP, when UDP is blocked |
| 50000–60000/UDP | WebRTC media |

Keep 7880 (LiveKit API) and 8000 (token API) closed; they listen on 127.0.0.1.

## First deploy

```sh
cd /opt && git clone https://github.com/earayu/coach-w.git && cd coach-w/deploy
cp .env.example .env && chmod 600 .env
docker run --rm livekit/livekit-server:v1.13.11 generate-keys   # → LIVEKIT_API_KEY / SECRET
openssl rand -hex 8                                              # one invite code per person
$EDITOR .env        # COACHW_DOMAIN, NODE_IP, LiveKit keys, DASHSCOPE_API_KEY, COACHW_INVITES
docker compose up -d --build
docker compose logs -f caddy      # wait for "certificate obtained successfully"
```

The first build takes a few minutes on 2 vCPU; the certificate came about 10 seconds after Caddy started.

Check from any machine:

```sh
curl https://coach.example.com/                     # LiveKit answers "OK"
curl -X POST https://coach.example.com/v1/session \
  -H 'Content-Type: application/json' \
  -d '{"invite_code":"<code>","athlete_id":"'"$(uuidgen)"'"}'   # 200, server_url wss://coach.example.com
curl -X POST https://coach.example.com/livekit/webhook          # 404: the webhook is internal
```

Voice smoke test against the host, from a Mac with the server deps (`cd server && uv sync`). It reads the agent log over SSH to check that `get_metrics` was called, and records the ICE path (`udp` or `tcp ...:7881`) in `artifacts/smoke_voice.json`:

```sh
cd server && uv run python tests/e2e/smoke_voice.py --invite <code> --api https://coach.example.com \
  --agent-log-cmd "ssh root@<host> docker compose -f /opt/coach-w/deploy/docker-compose.yml logs --no-color --no-log-prefix agent"
```

To exercise the 7881/TCP fallback, drop UDP from your own address on the host for one run and remove the rule afterwards: `iptables -I INPUT 1 -s <your-ip> -p udp --dport 50000:60000 -j DROP`, then the same rule with `-D`.

## Operating

- **Update:** `git pull && docker compose up -d --build`.
- **Invite someone / change minutes:** edit `COACHW_INVITES` in `.env`, then `docker compose up -d api`. Restarting the API forgets today's used minutes (in-memory, spec 3.1).
- **Resources:** `docker stats --no-stream`. On 2 vCPU / 4 GB with `COACHW_AGENT_IDLE_PROCESSES=2` the agent uses about 500 MB (idle and during one session), the other three containers about 130 MB together.
- **Logs:** `docker compose logs -f agent api`; each container keeps at most 5 × 10 MB. Logs carry `athlete_id` and room names only; no names, invite codes or metric values (spec 11). Keep the agent at the default INFO level: DEBUG logs conversation text.
- **Transcripts:** the agent keeps every conversation, one JSON Lines file per session, in the `transcripts` volume (`/data/transcripts/<YYYY-MM-DD>/<room>.jsonl`; types `user`, `coach`, `cue`). Read them with `docker compose exec agent sh -c 'tail -n +1 /data/transcripts/$(date -u +%F)/*.jsonl'`. They are conversation text and may contain spoken numbers such as heart rate: they stay on the host, never in the repo. Set `COACHW_TRANSCRIPT_DIR=` (empty) in `.env` to turn them off.
- **Secrets** live only in `deploy/.env` on the host. Never commit it.

## Not done yet

- TURN/TLS on 443 (for networks that block UDP and port 7881). Needs a second domain and Caddy's layer-4 module; add if mobile-network tests need it (spec 14.2).
- Automated provisioning (cloud-init / SSH deploy script).
