# Deploy

Server deployment lands in M2: one cloud host running docker compose with Caddy (TLS), LiveKit Server, the coach agent and the token API. See `docs/spec.md` section 10.

Secrets (LiveKit API secret, DashScope key) live only in the host's environment, never in this repository.
