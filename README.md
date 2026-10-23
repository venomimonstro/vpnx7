# VPNX7

Lightweight self-hosted VPN control plane and node system without Marzban.

## Design goal

VPNX7 is intentionally small:

- **Control plane:** FastAPI + SQLite + systemd.
- **VPN nodes:** Xray-core + a shell sync agent + systemd timer.
- **Protocol:** VLESS + XTLS Vision + REALITY over TCP/443.
- **Client:** subscription URL compatible with INCY and other VLESS clients.
- **No Redis, no Kubernetes, no Marzban, no mandatory Docker.**

The first milestone is operational reliability on low-resource VPS instances. Billing and advanced commercial features come after the end-to-end tunnel is proven.

See `docs/ARCHITECTURE.md` and `docs/SPRINTS.md`.
