# VPNX7 stability audit

Audit date: 2026-10-23.

This document separates **repository-level correctness** from **physical VPN acceptance**. A VPN cannot honestly be called 100% reliable from source review alone because the final path includes the real VPS kernel, provider firewall, routing, ISP/client network and the client application.

## Release blocker policy

A revision is not releasable when any of these is true:

- GitHub CI is red.
- Python compilation fails.
- Shell syntax or ShellCheck fails.
- legacy SQLite migration test fails.
- control-plane lifecycle/API self-test fails.
- real pinned-Xray runtime/config test fails.
- the staged control installer cannot create a verified backup.
- live health fails after a control update.
- node update final verification fails.

The installers are fail-closed: failed validation must preserve or restore the previous working state.

## Audited architecture

The stability-oriented topology is intentionally small:

- control plane: FastAPI, one Uvicorn worker, SQLite WAL, systemd;
- node: one pinned Xray binary, one Xray systemd service, one one-shot sync service/timer;
- data path: client -> geo node directly;
- control plane is not in the packet path;
- VLESS + XTLS Vision + REALITY over TCP/443;
- one subscription URL publishes only recently healthy nodes.

No Redis, Kubernetes, Marzban, message broker or mandatory container runtime is required.

## Critical defects found and fixed during audit

### Node identity rotation on reinstall

Risk: regenerating REALITY keys/token during a reinstall could leave the control plane and node with different identities.

Fix: enrolled nodes reuse the stored REALITY private key and per-node token. Existing credentials are verified before update. Silent control-plane migration, rename, geo, host, port or SNI changes during runtime update are blocked.

### Duplicate node takeover

Risk: a second install using the same node name could overwrite an existing node.

Fix: duplicate first enrollment returns HTTP 409. Existing enrollment remains untouched.

### Unverified Xray download

Risk: corrupt or unexpected binary could be installed.

Fix: Xray is pinned to v26.10.21 and the architecture-specific ZIP SHA-256 is checked before extraction/install.

### Xray x25519 output compatibility

Risk: current Xray prints the public value as `Password (PublicKey)`, which breaks parsers expecting older labels.

Fix: the installer parses the current output and can derive the public key from the stored private key during an update.

### REALITY target false-positive preflight

Risk: `xray tls ping` may finish even when an individual handshake is unsuccessful.

Fix: the installer parses the SNI section and requires an explicit successful TLS handshake.

### Bad generated Xray config

Risk: desired state could overwrite a working configuration with invalid JSON/Xray settings.

Fix: configuration is generated into a temporary file and validated by the real pinned Xray before replacement.

### Config starts but Xray fails after restart

Risk: static validation alone is insufficient.

Fix: after restart the sync checks service state, validates the installed config again and confirms the listen port. If changed config fails runtime validation, the previous config is restored.

### Node runtime update partial failure

Risk: updating the sync script, systemd units or Xray binary one-by-one could leave a half-updated node.

Fix: existing runtime state is backed up before replacement. Final verification failure restores prior node runtime state.

### Control release partial failure

Risk: replacing application files/systemd units in place could make the management server unbootable.

Fix: control updates use a staged checkout and staged unit files. Compile, shell, migration and API tests run before the switch. Code and units are rolled back together after a failed live health check.

### Database loss/corruption during deployment

Risk: a release or restore can damage the access database.

Fix: SQLite uses WAL, busy timeout and synchronous FULL. A consistent online backup with `PRAGMA integrity_check` is mandatory before a release switch. Daily persistent backups are installed. Restore validates the requested backup and automatically returns to a pre-restore backup if application health fails.

### Database migration rollback compatibility

Risk: application code can be rolled back while a new schema migration has already touched the live database.

Fix/policy: the normal rolling update path permits only backward-compatible additive migrations (new tables, indexes or nullable/defaulted columns). Destructive or semantic migrations are a maintenance operation and must use a separately tested database restore/migration procedure. The current schema migrations follow the additive rule.

### Stale/dead node in new subscriptions

Risk: a node may remain enabled in the database even though its runtime is broken.

Fix: a node is published only after a recent successful node runtime report. Stale nodes age out of newly refreshed subscriptions.

### Disabled node still serving cached credentials

Risk: simply hiding a node from subscriptions does not stop users who already have its VLESS link.

Fix: disabled nodes remain authenticated to the control plane, receive `enabled=false`, stop/disable Xray and expose no VPN listener. Re-enabling allows the timer to bring Xray back with current credentials.

### Subscription secret in application access logs

Risk: subscription/connect tokens are path components and must not be copied to ordinary Uvicorn access logs.

Fix: the production systemd command disables Uvicorn access logging. Any future reverse proxy must also redact or disable request-path logging for `/sub/*` and `/connect/*`.

### First node with zero customers

Risk: the most common first-install state has no client UUIDs and can differ from an already-used node.

Fix: CI explicitly exercises an enabled node with zero clients using the real pinned Xray config validator, then a node with a real test UUID, then the administratively disabled state.

## Failure semantics

| Event | Required result |
| --- | --- |
| control plane temporarily offline | existing active Xray tunnels continue |
| desired-state request fails | last valid Xray config remains |
| generated config invalid | live config is untouched |
| changed config fails after restart | previous config is restored |
| candidate Xray/runtime update fails | prior node runtime is restored |
| node stops reporting success | it ages out of refreshed subscriptions |
| one geo node fails | other healthy nodes remain available |
| client is disabled/expired | UUID disappears on the next successful node sync |
| node is disabled | it disappears from subscriptions and Xray stops |
| bad control release | prior application + unit set restored |
| bad database restore | pre-restore database restored |

## Deliberate constraints

These are stability constraints, not accidental omissions:

- only amd64 and arm64 Linux nodes are accepted by the installer;
- automatic node address discovery is IPv4; a DNS hostname may also be supplied;
- raw IPv6 literals are rejected instead of generating an invalid VLESS URI;
- a runtime reinstall cannot silently change an enrolled node's identity/network parameters;
- plaintext HTTP control traffic is rejected unless `VPNX7_ALLOW_HTTP=1` is explicitly set for a private test;
- automatic payments are not claimed as complete until a concrete payment provider and credentials are configured and its idempotent webhook flow is separately tested.

## Physical two-server acceptance gate

Repository CI cannot prove provider networking. Before calling the installed pair stable, perform all of these on the actual servers:

1. install/update the control server with no errors;
2. enroll node 1 and node 2 with unique names;
3. require both nodes to report healthy;
4. create a real client and import the subscription into INCY;
5. connect through node 1 and verify external IP/route;
6. connect through node 2 and verify external IP/route;
7. transfer sustained HTTPS traffic through each node;
8. reboot node 1 and require automatic recovery;
9. reboot node 2 and require automatic recovery;
10. reboot the control server and require automatic recovery;
11. stop the control service while a tunnel is active and confirm the active tunnel keeps passing traffic;
12. restore the control service and require node sync to recover;
13. disable a client and confirm access is removed from both nodes after sync;
14. re-enable that client and confirm recovery;
15. disable one node centrally and confirm its TCP/443 listener disappears;
16. re-enable it and confirm automatic recovery;
17. confirm a dead/unreporting node disappears from a refreshed subscription after the health window;
18. run `diagnose.sh` on every host and require zero failures;
19. create a database backup and perform a controlled restore test;
20. rerun both installers once to prove idempotent update behavior.

Only the actual deployed pair that passes this gate should be labelled accepted for daily work.

## Commercial gate

Before selling access publicly, additionally require:

- trusted HTTPS for every public control/subscription URL;
- reverse-proxy log redaction for secret URL paths;
- external monitoring from a network independent of the VPS provider;
- real payment integration with idempotent webhook handling;
- customer renewal/expiry tests;
- appropriate legal/fiscal flow;
- abuse handling and operational limits.

These commercial items must not be mixed into the VPN data path or weaken the simple core.
