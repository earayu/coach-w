# Deploy

One Linux host runs the whole server side with docker compose: Caddy (TLS), LiveKit Server, the token API and the coach agent. Design and port rationale: `docs/spec.md` section 10.

Not yet deployed to a real host (no server yet). What was checked locally on 2026-11-21: the Caddyfile validates and routes correctly in front of the local stack; `livekit.yaml` starts with LiveKit v1.13.11. The image build and `docker compose config` run in CI.

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
git clone https://github.com/earayu/coach-w.git && cd coach-w/deploy
cp .env.example .env && chmod 600 .env
docker run --rm livekit/livekit-server:v1.13.11 generate-keys   # → LIVEKIT_API_KEY / SECRET
openssl rand -hex 8                                              # one invite code per person
$EDITOR .env        # COACHW_DOMAIN, NODE_IP, LiveKit keys, DASHSCOPE_API_KEY, COACHW_INVITES
docker compose up -d --build
docker compose logs -f caddy      # wait for "certificate obtained successfully"
```

Check from any machine:

```sh
curl https://coach.example.com/                     # LiveKit answers "OK"
curl -X POST https://coach.example.com/v1/session \
  -H 'Content-Type: application/json' \
  -d '{"invite_code":"<code>","athlete_id":"'"$(uuidgen)"'"}'   # 200 with a token
```

## Operating

- **Update:** `git pull && docker compose up -d --build`.
- **Invite someone / change minutes:** edit `COACHW_INVITES` in `.env`, then `docker compose up -d api`. Restarting the API forgets today's used minutes (in-memory, spec 3.1).
- **Logs:** `docker compose logs -f agent api`. Logs carry `athlete_id` and room names only; no names, invite codes or metric values (spec 11). Keep the agent at the default INFO level: DEBUG logs conversation text.
- **Secrets** live only in `deploy/.env` on the host. Never commit it.

## Not done yet

- TURN/TLS on 443 (for networks that block UDP and port 7881). Needs a second domain and Caddy's layer-4 module; add if mobile-network tests need it (spec 14.2).
- Automated provisioning (cloud-init / SSH deploy script) once the host exists.
