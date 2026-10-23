# VPNX7 architecture

## Reliability first

VPNX7 deliberately separates the **control plane** from the **data plane**.

### Control plane

One small FastAPI process on the main server:

- SQLite with WAL mode.
- Admin API and minimal web UI.
- Customer/order records.
- Subscription endpoint.
- Node registration and desired-state API.
- Optional Telegram bot as a separate process.

The control plane is not in the user's VPN traffic path. If it reboots, existing Xray tunnels on the nodes keep working with the last valid configuration.

### VPN node

Each geo server runs only:

1. a pinned Xray-core binary;
2. one systemd Xray service;
3. one shell sync job triggered by a systemd timer.

There is no permanent Python agent on a node. The sync job pulls the active UUID list from the control plane, builds a new Xray config, validates it with `xray run -test`, and only then atomically replaces the live config.

A failed control-plane request or invalid config does **not** overwrite the last working configuration.

## Protocol

Milestone 1 uses:

- VLESS
- XTLS Vision
- REALITY
- TCP/443

This gives a small number of moving pieces, no certificate lifecycle on VPN nodes, and direct compatibility with INCY subscription links.

## Secrets

- Admin token exists only on the control plane and administrator device.
- Global node bootstrap token is used only during node installation.
- After registration, each node receives its own random token; only its SHA-256 hash is stored centrally.
- REALITY private keys stay on the node.
- The control plane stores only each node's REALITY public key.

## Subscription lifecycle

A client has one UUID and one opaque subscription token.

The subscription endpoint emits one VLESS link per active node. Therefore:

- adding a new geo does not require issuing new customer credentials;
- disabling a node removes it from the next subscription refresh;
- disabling or expiring a client removes its UUID from all node configs on the next sync.

## Failure model

| Failure | Expected behavior |
| --- | --- |
| Control plane down | Existing VPN sessions continue; nodes retain last valid config |
| Node cannot sync | Existing config remains untouched |
| Invalid desired config | Xray validation fails; live config remains untouched |
| One node down | Other geo nodes remain in the subscription |
| Main database locked briefly | SQLite busy timeout + WAL reduce write contention |
| Installer rerun | Control installer is idempotent; node registration rotates only that node token |

## Commercial hardening after tunnel proof

Before public sales:

- HTTPS for the control plane/subscription domain.
- Payment provider + webhook idempotency.
- Rate limiting on public order endpoints.
- Backups of the SQLite database.
- Node health probes from more than one network.
- Abuse controls and traffic quotas if required.
- Optional second protocol only after the primary path is proven.
