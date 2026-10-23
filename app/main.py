from __future__ import annotations

from datetime import datetime, timedelta, timezone
import html
import uuid
from urllib.parse import quote, urlencode

from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.responses import HTMLResponse, PlainTextResponse, Response
from pydantic import BaseModel, Field

from app.db import db, init_db, utcnow_iso
from app.security import random_token, secure_equal, token_hash
from app.settings import settings


NODE_FRESH_SECONDS = 180
ORDER_RATE_WINDOW_SECONDS = 600
ORDER_RATE_MAX = 10
VALID_PLANS = {"month": 30}

app = FastAPI(
    title="VPNX7",
    version="0.2.0",
    docs_url=None,
    redoc_url=None,
)


@app.on_event("startup")
def startup() -> None:
    init_db()
    if len(settings.admin_token) < 32:
        raise RuntimeError("VPNX7_ADMIN_TOKEN must contain at least 32 characters")
    if len(settings.node_bootstrap_token) < 32:
        raise RuntimeError("VPNX7_NODE_BOOTSTRAP_TOKEN must contain at least 32 characters")


@app.middleware("http")
async def safety_headers(request: Request, call_next):
    if request.method in {"POST", "PUT", "PATCH"}:
        raw_length = request.headers.get("content-length", "")
        if raw_length.isdigit() and int(raw_length) > 65536:
            return Response(status_code=413)
    response = await call_next(request)
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Referrer-Policy"] = "no-referrer"
    response.headers["X-Frame-Options"] = "DENY"
    if request.url.path.startswith(("/admin", "/connect/", "/sub/")):
        response.headers["Cache-Control"] = "no-store, private"
    return response


class NodeRegister(BaseModel):
    bootstrap_token: str = Field(min_length=16, max_length=256)
    name: str = Field(min_length=1, max_length=80)
    geo: str = Field(min_length=2, max_length=80)
    host: str | None = Field(default=None, max_length=255)
    port: int = Field(default=443, ge=1, le=65535)
    sni: str = Field(min_length=1, max_length=255)
    public_key: str = Field(min_length=16, max_length=256)
    short_id: str = Field(min_length=2, max_length=32)


class NodeAnnounce(BaseModel):
    geo: str = Field(min_length=2, max_length=80)
    host: str = Field(min_length=1, max_length=255)
    port: int = Field(default=443, ge=1, le=65535)
    sni: str = Field(min_length=1, max_length=255)
    public_key: str = Field(min_length=16, max_length=256)
    short_id: str = Field(min_length=2, max_length=32)


class NodeReport(BaseModel):
    ok: bool
    xray_version: str | None = Field(default=None, max_length=120)
    error: str | None = Field(default=None, max_length=500)


class ClientCreate(BaseModel):
    name: str = Field(min_length=1, max_length=120)
    email: str | None = Field(default=None, max_length=255)
    telegram_id: str | None = Field(default=None, max_length=64)
    days: int = Field(default=30, ge=1, le=3650)


class OrderCreate(BaseModel):
    email: str | None = Field(default=None, max_length=255)
    telegram_id: str | None = Field(default=None, max_length=64)
    plan: str = Field(default="month", min_length=1, max_length=40)


def bearer_token(authorization: str | None) -> str:
    if not authorization or not authorization.lower().startswith("bearer "):
        return ""
    return authorization.split(" ", 1)[1].strip()


def require_admin(authorization: str | None) -> None:
    if not secure_equal(bearer_token(authorization), settings.admin_token):
        raise HTTPException(status_code=401, detail="admin authentication required")


def require_node(node_id: str, authorization: str | None) -> None:
    supplied = bearer_token(authorization)
    if not supplied:
        raise HTTPException(status_code=401, detail="node authentication failed")
    with db() as conn:
        row = conn.execute(
            "SELECT token_hash FROM nodes WHERE id = ?",
            (node_id,),
        ).fetchone()
    if not row or not secure_equal(
        token_hash(supplied), row["token_hash"]
    ):
        raise HTTPException(status_code=401, detail="node authentication failed")


def _parse_expiry(value: str) -> datetime | None:
    try:
        expiry = datetime.fromisoformat(value)
        if expiry.tzinfo is None:
            expiry = expiry.replace(tzinfo=timezone.utc)
        return expiry.astimezone(timezone.utc)
    except (TypeError, ValueError):
        return None


def is_client_active(row) -> bool:
    if not row or not row["enabled"]:
        return False
    expiry = _parse_expiry(row["expires_at"])
    return bool(expiry and expiry > datetime.now(timezone.utc))


def fresh_cutoff_iso() -> str:
    return (
        datetime.now(timezone.utc) - timedelta(seconds=NODE_FRESH_SECONDS)
    ).replace(microsecond=0).isoformat()


def node_is_healthy(row) -> bool:
    if (
        not row
        or not row["enabled"]
        or not row["last_sync_ok"]
        or row["last_error"]
    ):
        return False
    try:
        last_ok = datetime.fromisoformat(row["last_sync_ok"])
        if last_ok.tzinfo is None:
            last_ok = last_ok.replace(tzinfo=timezone.utc)
    except (TypeError, ValueError):
        return False
    return last_ok.astimezone(timezone.utc) >= (
        datetime.now(timezone.utc) - timedelta(seconds=NODE_FRESH_SECONDS)
    )


def _insert_client(conn, name: str, email: str | None, telegram_id: str | None, days: int):
    client_id = str(uuid.uuid4())
    client_uuid = str(uuid.uuid4())
    sub_token = random_token(28)
    created_at = utcnow_iso()
    expires_at = (
        datetime.now(timezone.utc) + timedelta(days=days)
    ).replace(microsecond=0).isoformat()
    conn.execute(
        """
        INSERT INTO clients
        (id, name, email, telegram_id, uuid, subscription_token, enabled, expires_at, created_at)
        VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?)
        """,
        (
            client_id,
            name.strip(),
            email.strip() if email else None,
            telegram_id.strip() if telegram_id else None,
            client_uuid,
            sub_token,
            expires_at,
            created_at,
        ),
    )
    return {
        "id": client_id,
        "uuid": client_uuid,
        "subscription_token": sub_token,
        "expires_at": expires_at,
        "subscription_url": f"{settings.public_url}/sub/{sub_token}",
        "connect_url": f"{settings.public_url}/connect/{sub_token}",
    }


def create_client_record(
    name: str, email: str | None, telegram_id: str | None, days: int
) -> dict:
    with db(immediate=True) as conn:
        return _insert_client(conn, name, email, telegram_id, days)


def client_payload_from_id(conn, client_id: str) -> dict | None:
    row = conn.execute(
        """
        SELECT id, uuid, subscription_token, expires_at
        FROM clients WHERE id=?
        """,
        (client_id,),
    ).fetchone()
    if not row:
        return None
    return {
        "id": row["id"],
        "uuid": row["uuid"],
        "subscription_token": row["subscription_token"],
        "expires_at": row["expires_at"],
        "subscription_url": f'{settings.public_url}/sub/{row["subscription_token"]}',
        "connect_url": f'{settings.public_url}/connect/{row["subscription_token"]}',
    }


def build_vless_link(client, node) -> str:
    params = {
        "encryption": "none",
        "flow": "xtls-rprx-vision",
        "security": "reality",
        "type": "tcp",
        "sni": node["sni"],
        "fp": "chrome",
        "pbk": node["public_key"],
        "sid": node["short_id"],
        "spx": "/",
    }
    label = quote(f'{node["geo"]} · {node["name"]}', safe="")
    return (
        f'vless://{client["uuid"]}@{node["host"]}:{node["port"]}'
        f'?{urlencode(params)}#{label}'
    )


@app.get("/healthz")
def healthz():
    with db() as conn:
        conn.execute("SELECT 1").fetchone()
    return {"status": "ok", "service": "vpnx7-control", "version": app.version}


@app.post("/api/v1/nodes/register")
def register_node(payload: NodeRegister, request: Request):
    if not secure_equal(payload.bootstrap_token, settings.node_bootstrap_token):
        raise HTTPException(status_code=401, detail="invalid bootstrap token")

    host = (payload.host or (request.client.host if request.client else "")).strip()
    if not host:
        raise HTTPException(status_code=400, detail="node host could not be detected")

    now = utcnow_iso()
    node_id = str(uuid.uuid4())
    node_token = random_token(36)
    with db(immediate=True) as conn:
        existing = conn.execute(
            "SELECT id FROM nodes WHERE name = ?",
            (payload.name.strip(),),
        ).fetchone()
        if existing:
            raise HTTPException(
                status_code=409,
                detail="node name already registered; update the enrolled node with its stored credentials, or enroll replacement hardware under a new unique node name",
            )
        conn.execute(
            """
            INSERT INTO nodes
            (id, name, geo, host, port, sni, public_key, short_id,
             token_hash, enabled, created_at, last_seen)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
            """,
            (
                node_id,
                payload.name.strip(),
                payload.geo.strip(),
                host,
                payload.port,
                payload.sni.strip(),
                payload.public_key.strip(),
                payload.short_id.strip(),
                token_hash(node_token),
                now,
                now,
            ),
        )

    return {
        "node_id": node_id,
        "node_token": node_token,
        "sync_url": f"{settings.public_url}/api/v1/nodes/{node_id}/desired",
    }


@app.post("/api/v1/nodes/{node_id}/announce")
def node_announce(
    node_id: str,
    payload: NodeAnnounce,
    authorization: str | None = Header(default=None),
):
    require_node(node_id, authorization)
    with db(immediate=True) as conn:
        conn.execute(
            """
            UPDATE nodes
            SET geo=?, host=?, port=?, sni=?, public_key=?, short_id=?, last_seen=?
            WHERE id=?
            """,
            (
                payload.geo.strip(),
                payload.host.strip(),
                payload.port,
                payload.sni.strip(),
                payload.public_key.strip(),
                payload.short_id.strip(),
                utcnow_iso(),
                node_id,
            ),
        )
    return {"status": "ok", "node_id": node_id}


@app.post("/api/v1/nodes/{node_id}/report")
def node_report(
    node_id: str,
    payload: NodeReport,
    authorization: str | None = Header(default=None),
):
    require_node(node_id, authorization)
    now = utcnow_iso()
    with db(immediate=True) as conn:
        if payload.ok:
            conn.execute(
                """
                UPDATE nodes
                SET last_seen=?, last_sync_ok=?, last_error=NULL, xray_version=?
                WHERE id=?
                """,
                (now, now, payload.xray_version, node_id),
            )
        else:
            conn.execute(
                """
                UPDATE nodes
                SET last_seen=?, last_error=?, xray_version=?
                WHERE id=?
                """,
                (now, payload.error or "node reported a failure", payload.xray_version, node_id),
            )
    return {"status": "ok"}


@app.get("/api/v1/nodes/{node_id}/desired")
def node_desired(node_id: str, authorization: str | None = Header(default=None)):
    require_node(node_id, authorization)
    now = utcnow_iso()
    with db() as conn:
        node = conn.execute(
            "SELECT * FROM nodes WHERE id = ?",
            (node_id,),
        ).fetchone()
        conn.execute(
            "UPDATE nodes SET last_seen = ? WHERE id = ?",
            (now, node_id),
        )
        if node["enabled"]:
            clients = conn.execute(
                """
                SELECT id, name, uuid, expires_at
                FROM clients
                WHERE enabled = 1 AND expires_at > ?
                ORDER BY created_at ASC
                """,
                (now,),
            ).fetchall()
        else:
            # A disabled node remains authenticated so it can drain safely.
            # Empty desired clients removes every credential from its Xray config.
            clients = []

    return {
        "node": {
            "id": node["id"],
            "name": node["name"],
            "geo": node["geo"],
            "host": node["host"],
            "port": node["port"],
            "sni": node["sni"],
            "enabled": bool(node["enabled"]),
        },
        "clients": [
            {
                "id": row["id"],
                "name": row["name"],
                "uuid": row["uuid"],
                "email": f'vpnx7-{row["id"][:8]}',
                "flow": "xtls-rprx-vision",
            }
            for row in clients
        ],
        "generated_at": now,
    }


@app.get("/sub/{subscription_token}")
def subscription(subscription_token: str):
    with db() as conn:
        client = conn.execute(
            "SELECT * FROM clients WHERE subscription_token = ?",
            (subscription_token,),
        ).fetchone()
        if not client or not is_client_active(client):
            raise HTTPException(status_code=404, detail="subscription is inactive")
        nodes = conn.execute(
            """
            SELECT * FROM nodes
            WHERE enabled = 1
              AND public_key <> ''
              AND last_sync_ok IS NOT NULL
              AND last_error IS NULL
              AND last_sync_ok >= ?
            ORDER BY geo, name
            """,
            (fresh_cutoff_iso(),),
        ).fetchall()

    if not nodes:
        raise HTTPException(status_code=503, detail="no healthy VPN nodes")

    body = "\n".join(build_vless_link(client, node) for node in nodes)
    headers = {
        "Cache-Control": "no-store, private",
        "profile-title": settings.provider_name,
        "profile-update-interval": "1",
        "sort-order": "ping",
    }
    if settings.support_url:
        headers["support-url"] = settings.support_url
    return PlainTextResponse(body, media_type="text/plain; charset=utf-8", headers=headers)


@app.get("/connect/{subscription_token}", response_class=HTMLResponse)
def connect_page(subscription_token: str):
    with db() as conn:
        client = conn.execute(
            "SELECT * FROM clients WHERE subscription_token = ?",
            (subscription_token,),
        ).fetchone()
        nodes = conn.execute(
            """
            SELECT geo, name FROM nodes
            WHERE enabled=1 AND last_sync_ok IS NOT NULL AND last_sync_ok >= ?
            ORDER BY geo, name
            """,
            (fresh_cutoff_iso(),),
        ).fetchall()

    if not client or not is_client_active(client):
        raise HTTPException(status_code=404, detail="access is inactive")

    subscription_url = f"{settings.public_url}/sub/{subscription_token}"
    incy_url = f"incy://import/{subscription_url}"
    node_html = "".join(
        f"<li>{html.escape(row['geo'])} — {html.escape(row['name'])}</li>" for row in nodes
    ) or "<li>Сейчас нет подтверждённых рабочих нод</li>"

    return HTMLResponse(f"""<!doctype html>
<html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{html.escape(settings.provider_name)} — подключение</title>
<style>
body{{font-family:system-ui,sans-serif;max-width:720px;margin:50px auto;padding:0 18px;background:#0b0d10;color:#eef2f7}}
.card{{background:#151922;border:1px solid #2b3240;border-radius:18px;padding:24px;margin:18px 0}}
a.btn,button{{display:inline-block;background:#fff;color:#111;padding:12px 18px;border-radius:12px;text-decoration:none;border:0;font-weight:700}}
code{{display:block;overflow-wrap:anywhere;background:#0b0d10;padding:12px;border-radius:10px;margin:12px 0}}
.small{{color:#aeb8c7}}
</style></head><body>
<h1>{html.escape(settings.provider_name)}</h1>
<div class="card">
<h2>Подключение через INCY</h2>
<p>Добавьте подписку один раз. Рабочие гео-ноды будут обновляться в ней автоматически.</p>
<p><a class="btn" href="{html.escape(incy_url)}">Добавить в INCY</a></p>
<p class="small">Если кнопка не открылась — скопируйте URL подписки вручную:</p>
<code id="sub">{html.escape(subscription_url)}</code>
<button onclick="navigator.clipboard.writeText(document.getElementById('sub').innerText)">Скопировать</button>
</div>
<div class="card"><h3>Рабочие серверы</h3><ul>{node_html}</ul>
<p class="small">Доступ до {html.escape(client["expires_at"])}</p></div>
</body></html>""")


@app.post("/api/public/orders")
def create_order(payload: OrderCreate, request: Request):
    email = payload.email.strip() if payload.email else None
    telegram_id = payload.telegram_id.strip() if payload.telegram_id else None
    if not email and not telegram_id:
        raise HTTPException(status_code=400, detail="email or telegram_id is required")
    if payload.plan not in VALID_PLANS:
        raise HTTPException(status_code=400, detail="unknown plan")

    request_ip = request.client.host if request.client else ""
    now = datetime.now(timezone.utc).replace(microsecond=0)
    window_start = (now - timedelta(seconds=ORDER_RATE_WINDOW_SECONDS)).isoformat()

    order_id = str(uuid.uuid4())
    with db(immediate=True) as conn:
        if request_ip:
            recent = conn.execute(
                """
                SELECT COUNT(*) AS n
                FROM orders
                WHERE request_ip=? AND created_at >= ?
                """,
                (request_ip, window_start),
            ).fetchone()["n"]
            if recent >= ORDER_RATE_MAX:
                raise HTTPException(status_code=429, detail="too many requests")
        conn.execute(
            """
            INSERT INTO orders
            (id, email, telegram_id, plan, status, created_at, request_ip)
            VALUES (?, ?, ?, ?, 'pending', ?, ?)
            """,
            (
                order_id,
                email,
                telegram_id,
                payload.plan,
                now.isoformat(),
                request_ip or None,
            ),
        )
    return {"order_id": order_id, "status": "pending"}


@app.get("/api/public/orders/{order_id}")
def order_status(order_id: str):
    with db() as conn:
        row = conn.execute(
            "SELECT id, status, activated_client_id FROM orders WHERE id=?",
            (order_id,),
        ).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="order not found")
        result = dict(row)
        if row["activated_client_id"]:
            client = conn.execute(
                "SELECT subscription_token FROM clients WHERE id=?",
                (row["activated_client_id"],),
            ).fetchone()
            if client:
                result["connect_url"] = (
                    f'{settings.public_url}/connect/{client["subscription_token"]}'
                )
    return result


@app.get("/api/admin/nodes")
def admin_nodes(authorization: str | None = Header(default=None)):
    require_admin(authorization)
    with db() as conn:
        rows = conn.execute(
            """
            SELECT id,name,geo,host,port,sni,enabled,created_at,last_seen,
                   last_sync_ok,last_error,xray_version
            FROM nodes ORDER BY geo,name
            """
        ).fetchall()
    result = []
    for row in rows:
        item = dict(row)
        item["healthy"] = node_is_healthy(row)
        result.append(item)
    return result


@app.post("/api/admin/nodes/{node_id}/toggle")
def admin_toggle_node(node_id: str, authorization: str | None = Header(default=None)):
    require_admin(authorization)
    with db(immediate=True) as conn:
        row = conn.execute("SELECT enabled FROM nodes WHERE id=?", (node_id,)).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="node not found")
        enabled = 0 if row["enabled"] else 1
        disabled_at = utcnow_iso() if not enabled else None
        if enabled:
            # A previously disabled node may have a fresh "ok" report that only
            # means "Xray is intentionally stopped". Never expose it until a
            # post-enable sync starts Xray and reports success again.
            conn.execute(
                """
                UPDATE nodes
                SET enabled=1, disabled_at=NULL, last_sync_ok=NULL,
                    last_error='awaiting post-enable node sync'
                WHERE id=?
                """,
                (node_id,),
            )
        else:
            conn.execute(
                "UPDATE nodes SET enabled=0, disabled_at=? WHERE id=?",
                (disabled_at, node_id),
            )
    return {
        "id": node_id,
        "enabled": bool(enabled),
        "state": "active" if enabled else "draining",
    }


@app.get("/api/admin/clients")
def admin_clients(authorization: str | None = Header(default=None)):
    require_admin(authorization)
    with db() as conn:
        rows = conn.execute(
            """
            SELECT id,name,email,telegram_id,enabled,expires_at,created_at,subscription_token
            FROM clients ORDER BY created_at DESC
            """
        ).fetchall()
    result = []
    for row in rows:
        item = dict(row)
        item["connect_url"] = f'{settings.public_url}/connect/{row["subscription_token"]}'
        item.pop("subscription_token", None)
        result.append(item)
    return result


@app.post("/api/admin/clients")
def admin_create_client(
    payload: ClientCreate,
    authorization: str | None = Header(default=None),
):
    require_admin(authorization)
    return create_client_record(
        payload.name,
        payload.email,
        payload.telegram_id,
        payload.days,
    )


@app.post("/api/admin/clients/{client_id}/toggle")
def admin_toggle_client(
    client_id: str,
    authorization: str | None = Header(default=None),
):
    require_admin(authorization)
    with db(immediate=True) as conn:
        row = conn.execute("SELECT enabled FROM clients WHERE id=?", (client_id,)).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="client not found")
        enabled = 0 if row["enabled"] else 1
        conn.execute("UPDATE clients SET enabled=? WHERE id=?", (enabled, client_id))
    return {"id": client_id, "enabled": bool(enabled)}


@app.get("/api/admin/orders")
def admin_orders(authorization: str | None = Header(default=None)):
    require_admin(authorization)
    with db() as conn:
        rows = conn.execute(
            "SELECT * FROM orders ORDER BY created_at DESC LIMIT 200"
        ).fetchall()
    return [dict(row) for row in rows]


@app.post("/api/admin/orders/{order_id}/activate")
def admin_activate_order(
    order_id: str,
    authorization: str | None = Header(default=None),
):
    require_admin(authorization)
    with db(immediate=True) as conn:
        order = conn.execute("SELECT * FROM orders WHERE id=?", (order_id,)).fetchone()
        if not order:
            raise HTTPException(status_code=404, detail="order not found")

        if order["status"] == "active" and order["activated_client_id"]:
            existing = client_payload_from_id(conn, order["activated_client_id"])
            if existing:
                return existing

        if order["status"] != "pending":
            raise HTTPException(status_code=409, detail="order is not pending")

        days = VALID_PLANS.get(order["plan"])
        if not days:
            raise HTTPException(status_code=409, detail="order plan is invalid")

        client = _insert_client(
            conn,
            name=order["email"] or f'Telegram {order["telegram_id"]}',
            email=order["email"],
            telegram_id=order["telegram_id"],
            days=days,
        )
        updated = conn.execute(
            """
            UPDATE orders
            SET status='active', activated_client_id=?
            WHERE id=? AND status='pending'
            """,
            (client["id"], order_id),
        ).rowcount
        if updated != 1:
            raise HTTPException(status_code=409, detail="order activation conflict")
        return client


@app.get("/", response_class=HTMLResponse)
def home():
    return HTMLResponse(f"""<!doctype html>
<html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{html.escape(settings.provider_name)}</title>
<style>
body{{font-family:system-ui,sans-serif;max-width:760px;margin:60px auto;padding:0 18px;background:#0b0d10;color:#eef2f7}}
.card{{background:#151922;border:1px solid #2b3240;border-radius:18px;padding:26px}}
input,select,button{{box-sizing:border-box;width:100%;padding:13px;border-radius:11px;border:1px solid #343c4b;margin:7px 0;background:#0b0d10;color:#fff}}
button{{background:#fff;color:#111;font-weight:700;cursor:pointer}}
.small{{color:#9eabba}}
</style></head><body>
<h1>{html.escape(settings.provider_name)}</h1>
<p>VPNX7: один доступ, несколько гео-серверов.</p>
<div class="card">
<h2>Запросить доступ</h2>
<input id="email" type="email" maxlength="255" placeholder="Email">
<select id="plan"><option value="month">1 месяц</option></select>
<button onclick="send()">Продолжить</button>
<p id="result" class="small"></p>
</div>
<script>
async function send(){{
 const email=document.getElementById('email').value.trim();
 const plan=document.getElementById('plan').value;
 const r=await fetch('/api/public/orders',{{method:'POST',headers:{{'Content-Type':'application/json'}},body:JSON.stringify({{email,plan}})}});
 const j=await r.json();
 document.getElementById('result').innerText=r.ok?'Заявка создана: '+j.order_id:'Ошибка: '+(j.detail||'неизвестно');
}}
</script></body></html>""")


@app.get("/admin", response_class=HTMLResponse)
def admin_page():
    return HTMLResponse("""<!doctype html>
<html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>VPNX7 Admin</title>
<style>
body{font-family:system-ui,sans-serif;max-width:1100px;margin:35px auto;padding:0 18px;background:#0b0d10;color:#eef2f7}
.card{background:#151922;border:1px solid #2b3240;border-radius:16px;padding:18px;margin:14px 0}
input,button{padding:10px;border-radius:9px;border:1px solid #343c4b;background:#0b0d10;color:#fff;margin:4px}
button{background:#fff;color:#111;font-weight:700;cursor:pointer}
pre{white-space:pre-wrap;overflow-wrap:anywhere}.row{display:flex;flex-wrap:wrap}
</style></head><body>
<h1>VPNX7 Admin</h1>
<div class="card"><input id="token" type="password" placeholder="Admin token"><button onclick="loadAll()">Войти / обновить</button></div>
<div class="card"><h3>Создать доступ</h3><div class="row">
<input id="name" placeholder="Имя"><input id="email" placeholder="Email"><input id="tg" placeholder="Telegram ID"><input id="days" type="number" value="30">
<button onclick="createClient()">Создать</button></div><pre id="created"></pre></div>
<div class="card"><h3>Ноды</h3><pre id="nodes"></pre></div>
<div class="card"><h3>Клиенты</h3><pre id="clients"></pre></div>
<div class="card"><h3>Заявки</h3><pre id="orders"></pre></div>
<script>
function auth(){sessionStorage.setItem('vpnx7-admin',document.getElementById('token').value||sessionStorage.getItem('vpnx7-admin')||'');return {'Authorization':'Bearer '+sessionStorage.getItem('vpnx7-admin')}}
async function getj(u){const r=await fetch(u,{headers:auth()});return [r,await r.json()]}
async function loadAll(){for(const [id,u] of [['nodes','/api/admin/nodes'],['clients','/api/admin/clients'],['orders','/api/admin/orders']]){const [r,j]=await getj(u);document.getElementById(id).innerText=JSON.stringify(j,null,2)}}
async function createClient(){const body={name:document.getElementById('name').value,email:document.getElementById('email').value||null,telegram_id:document.getElementById('tg').value||null,days:Number(document.getElementById('days').value||30)};const r=await fetch('/api/admin/clients',{method:'POST',headers:{...auth(),'Content-Type':'application/json'},body:JSON.stringify(body)});document.getElementById('created').innerText=JSON.stringify(await r.json(),null,2);loadAll()}
document.getElementById('token').value=sessionStorage.getItem('vpnx7-admin')||'';
</script></body></html>""")
