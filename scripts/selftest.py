from __future__ import annotations

import os
import tempfile
from pathlib import Path
import sys

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

root = Path(tempfile.mkdtemp(prefix="vpnx7-selftest-"))
os.environ["VPNX7_DATABASE"] = str(root / "vpnx7.db")
os.environ["VPNX7_PUBLIC_URL"] = "https://vpn.test"
os.environ["VPNX7_ADMIN_TOKEN"] = "a" * 64
os.environ["VPNX7_NODE_BOOTSTRAP_TOKEN"] = "b" * 64
os.environ["VPNX7_PROVIDER_NAME"] = "VPNX7 Test"

from fastapi.testclient import TestClient

from app.main import app


ADMIN = {"Authorization": "Bearer " + ("a" * 64)}


def expect(response, status: int):
    if response.status_code != status:
        raise AssertionError(
            f"{response.request.method} {response.request.url}: "
            f"expected {status}, got {response.status_code}: {response.text}"
        )
    return response


with TestClient(app) as client:
    expect(client.get("/healthz"), 200)
    expect(client.get("/api/admin/nodes"), 401)

    registration = expect(
        client.post(
            "/api/v1/nodes/register",
            json={
                "bootstrap_token": "b" * 64,
                "name": "de-1",
                "geo": "Germany",
                "host": "203.0.113.10",
                "port": 443,
                "sni": "www.microsoft.com",
                "public_key": "P" * 43,
                "short_id": "0011223344556677",
            },
        ),
        200,
    ).json()
    node_id = registration["node_id"]
    node_token = registration["node_token"]
    node_auth = {"Authorization": "Bearer " + node_token}

    expect(
        client.post(
            "/api/v1/nodes/register",
            json={
                "bootstrap_token": "b" * 64,
                "name": "de-1",
                "geo": "Germany",
                "host": "203.0.113.10",
                "port": 443,
                "sni": "www.microsoft.com",
                "public_key": "Q" * 43,
                "short_id": "8899aabbccddeeff",
            },
        ),
        409,
    )

    expect(client.get(f"/api/v1/nodes/{node_id}/desired", headers=node_auth), 200)

    created = expect(
        client.post(
            "/api/admin/clients",
            headers=ADMIN,
            json={"name": "Self Test", "days": 30},
        ),
        200,
    ).json()
    sub_token = created["subscription_token"]

    # A registered node is not exposed until it confirms a healthy Xray state.
    expect(client.get(f"/sub/{sub_token}"), 503)

    expect(
        client.post(
            f"/api/v1/nodes/{node_id}/report",
            headers=node_auth,
            json={"ok": True, "xray_version": "Xray 26.10.21"},
        ),
        200,
    )

    sub = expect(client.get(f"/sub/{sub_token}"), 200)
    body = sub.text
    required = [
        "vless://",
        "@203.0.113.10:443?",
        "security=reality",
        "flow=xtls-rprx-vision",
        "sni=www.microsoft.com",
        "pbk=",
        "sid=0011223344556677",
    ]
    for fragment in required:
        if fragment not in body:
            raise AssertionError(f"subscription missing {fragment!r}: {body}")

    page = expect(client.get(f"/connect/{sub_token}"), 200).text
    if f"incy://import/https://vpn.test/sub/{sub_token}" not in page:
        raise AssertionError("INCY import deep-link is missing")

    expect(client.post(f"/api/admin/clients/{created['id']}/toggle", headers=ADMIN), 200)
    expect(client.get(f"/sub/{sub_token}"), 404)
    expect(client.post(f"/api/admin/clients/{created['id']}/toggle", headers=ADMIN), 200)

    order = expect(
        client.post("/api/public/orders", json={"email": "test@example.com", "plan": "month"}),
        200,
    ).json()
    activation1 = expect(
        client.post(f"/api/admin/orders/{order['order_id']}/activate", headers=ADMIN),
        200,
    ).json()
    activation2 = expect(
        client.post(f"/api/admin/orders/{order['order_id']}/activate", headers=ADMIN),
        200,
    ).json()
    if activation1["id"] != activation2["id"]:
        raise AssertionError("order activation is not idempotent")

    expect(client.post(f"/api/admin/nodes/{node_id}/toggle", headers=ADMIN), 200)
    expect(client.get(f"/sub/{sub_token}"), 503)
    expect(client.post(f"/api/admin/nodes/{node_id}/toggle", headers=ADMIN), 200)
    expect(
        client.post(
            f"/api/v1/nodes/{node_id}/report",
            headers=node_auth,
            json={"ok": True, "xray_version": "Xray 26.10.21"},
        ),
        200,
    )
    expect(client.get(f"/sub/{sub_token}"), 200)

print("VPNX7 CONTROL SELFTEST PASS")
