from __future__ import annotations

from datetime import datetime, timedelta, timezone
import html
import json
import uuid
from urllib.parse import quote, urlencode

from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.responses import HTMLResponse, PlainTextResponse
from pydantic import BaseModel, Field

from app.db import db, init_db, utcnow_iso
from app.security import random_token, secure_equal, token_hash
from app.settings import settings


app = FastAPI(title="VPNX7", version="0.1.0")


@app.on_event("startup")
def startup() -> None:
    init_db()
    if not settings.admin_token:
        raise RuntimeError("VPNX7_ADMIN_TOKEN is required")
    if not settings.node_bootstrap_token:
        raise RuntimeError("VPNX7_NODE_BOOTSTRAP_TOKEN is required")


class NodeRegister(BaseModel):
    bootstrap_token: str
    name: str = Field(min_length=1, max_length=80)
    geo: str = Field(min_length=2, max_length=80)
    host: str | None = Field(default=None, max_length=255)
    port: int = Field(default=443, ge=1, le=65535)
    sni: str = Field(min_length=1, max_length=255)
    public_key: str = Field(min_length=16, max_length=256)
    short_id: str = Field(min_length=2, max_length=32)


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
    with db() as conn:
        row = conn.execute(
            "SELECT token_hash, enabled FROM nodes WHERE id = ?",
            (node_id,),
        ).fetchone()
    if not row or not row["enabled"] or not secure_equal(token_hash(supplied), row["token_hash"]):
        raise HTTPException(status_code=401, detail="node authentication failed")


def is_client_active(row) -> bool:
    if not row["enabled"]:
        return False
    try:
        expiry = datetime.fromisoformat(row["expires_at"])
    except ValueError:
        return False
    return expiry > datetime.now(timezone.utc)


def create_client_record(name: str, email: str | None, telegram_id: str | None, days: int) -> dict:
    client_id = str(uuid.uuid4())
    client_uuid = str(uuid.uuid4())
    sub_token = random_token(28)
    created_at = utcnow_iso()
    expires_at = (
        datetime.now(timezone.utc) + timedelta(days=days)
    ).replace(microsecond=0).isoformat()

    with db() as conn:
        conn.execute(
            """
            INSERT INTO clients
            (id, name, email, telegram_id, uuid, subscription_token, enabled, expires_at, created_at)
            VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?)
            """,
            (
                client_id,
                name,
                email,
                telegram_id,
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
    return {"status": "ok", "service": "vpnx7-control"}


@app.post("/api/v1/nodes/register")
def register_node(payload: NodeRegister, request: Request):
    if not secure_equal(payload.bootstrap_token, settings.node_bootstrap_token):
        raise HTTPException(status_code=401, detail="invalid bootstrap token")

    node_token = random_token(36)
    node_token_hash = token_hash(node_token)
    host = (payload.host or (request.client.host if request.client else "")).strip()
    if not host:
        raise HTTPException(status_code=400, detail="node host could not be detected")

    now = utcnow_iso()
    with db() as conn:
        existing = conn.execute(
            "SELECT id FROM nodes WHERE name = ?",
            (payload.name,),
        ).fetchone()
        if existing:
            node_id = existing["id"]
            conn.execute(
                """
                UPDATE nodes
                SET geo=?, host=?, port=?, sni=?, public_key=?, short_id=?,
                    token_hash=?, enabled=1, last_seen=?
                WHERE id=?
                """,
                (
                    payload.geo,
                    host,
                    payload.port,
                    payload.sni,
                    payload.public_key,
                    payload.short_id,
                    node_token_hash,
                    now,
                    node_id,
                ),
            )
        else:
            node_id = str(uuid.uuid4())
            conn.execute(
                """
                INSERT INTO nodes
                (id, name, geo, host, port, sni, public_key, short_id,
                 token_hash, enabled, created_at, last_seen)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
                """,
                (
                    node_id,
                    payload.name,
                    payload.geo,
                    host,
                    payload.port,
                    payload.sni,
                    payload.public_key,
                    payload.short_id,
                    node_token_hash,
                    now,
                    now,
                ),
            )

    return {
        "node_id": node_id,
        "node_token": node_token,
        "sync_url": f"{settings.public_url}/api/v1/nodes/{node_id}/desired",
    }


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
        clients = conn.execute(
            """
            SELECT id, name, uuid, expires_at
            FROM clients
            WHERE enabled = 1 AND expires_at > ?
            ORDER BY created_at ASC
            """,
            (now,),
        ).fetchall()

    return {
        "node": {
            "id": node["id"],
            "name": node["name"],
            "geo": node["geo"],
            "port": node["port"],
            "sni": node["sni"],
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
            WHERE enabled = 1 AND public_key <> ''
            ORDER BY geo, name
            """
        ).fetchall()

    if not nodes:
        raise HTTPException(status_code=503, detail="no active VPN nodes")

    body = "\n".join(build_vless_link(client, node) for node in nodes)
    headers = {
        "Cache-Control": "no-store, private",
        "profile-title": settings.provider_name,
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
            "SELECT geo, name FROM nodes WHERE enabled=1 ORDER BY geo, name"
        ).fetchall()

    if not client or not is_client_active(client):
        raise HTTPException(status_code=404, detail="access is inactive")

    subscription_url = f"{settings.public_url}/sub/{subscription_token}"
    incy_url = f"incy://import/{subscription_url}"
    node_html = "".join(
        f"<li>{html.escape(row['geo'])} — {html.escape(row['name'])}</li>" for row in nodes
    ) or "<li>Ноды ещё не подключены</li>"

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
<p>Установите INCY, затем добавьте подписку одной кнопкой. При появлении новых гео повторно получать ключ не нужно.</p>
<p><a class="btn" href="{html.escape(incy_url)}">Добавить в INCY</a></p>
<p class="small">Если кнопка не открылась — скопируйте URL подписки вручную:</p>
<code id="sub">{html.escape(subscription_url)}</code>
<button onclick="navigator.clipboard.writeText(document.getElementById('sub').innerText)">Скопировать</button>
</div>
<div class="card"><h3>Доступные серверы</h3><ul>{node_html}</ul>
<p class="small">Доступ до {html.escape(client["expires_at"])}</p></div>
</body></html>""")


@app.post("/api/public/orders")
def create_order(payload: OrderCreate):
    if not payload.email and not payload.telegram_id:
        raise HTTPException(status_code=400, detail="email or telegram_id is required")
    order_id = str(uuid.uuid4())
    with db() as conn:
        conn.execute(
            """
            INSERT INTO orders
            (id, email, telegram_id, plan, status, created_at)
            VALUES (?, ?, ?, ?, 'pending', ?)
            """,
            (order_id, payload.email, payload.telegram_id, payload.plan, utcnow_iso()),
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
                result["connect_url"] = f'{settings.public_url}/connect/{client["subscription_token"]}'
    return result


@app.get("/api/admin/nodes")
def admin_nodes(authorization: str | None = Header(default=None)):
    require_admin(authorization)
    with db() as conn:
        rows = conn.execute(
            """
            SELECT id,name,geo,host,port,sni,enabled,created_at,last_seen
            FROM nodes ORDER BY geo,name
            """
        ).fetchall()
    return [dict(row) for row in rows]


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
def admin_create_client(payload: ClientCreate, authorization: str | None = Header(default=None)):
    require_admin(authorization)
    return create_client_record(
        payload.name,
        payload.email,
        payload.telegram_id,
        payload.days,
    )


@app.post("/api/admin/clients/{client_id}/toggle")
def admin_toggle_client(client_id: str, authorization: str | None = Header(default=None)):
    require_admin(authorization)
    with db() as conn:
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
def admin_activate_order(order_id: str, authorization: str | None = Header(default=None)):
    require_admin(authorization)
    with db() as conn:
        order = conn.execute("SELECT * FROM orders WHERE id=?", (order_id,)).fetchone()
    if not order:
        raise HTTPException(status_code=404, detail="order not found")
    if order["status"] == "active" and order["activated_client_id"]:
        raise HTTPException(status_code=409, detail="order already activated")

    client = create_client_record(
        name=order["email"] or f'Telegram {order["telegram_id"]}',
        email=order["email"],
        telegram_id=order["telegram_id"],
        days=30,
    )
    with db() as conn:
        conn.execute(
            "UPDATE orders SET status='active', activated_client_id=? WHERE id=?",
            (client["id"], order_id),
        )
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
<p>Лёгкий VPN с выбором географии. Один URL подписки — все доступные серверы.</p>
<div class="card">
<h2>Запросить доступ</h2>
<input id="email" type="email" placeholder="Email">
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
function auth(){localStorage.setItem('vpnx7-admin',document.getElementById('token').value||localStorage.getItem('vpnx7-admin')||'');return {'Authorization':'Bearer '+localStorage.getItem('vpnx7-admin')}}
async function getj(u){const r=await fetch(u,{headers:auth()});return [r,await r.json()]}
async function loadAll(){for(const [id,u] of [['nodes','/api/admin/nodes'],['clients','/api/admin/clients'],['orders','/api/admin/orders']]){const [r,j]=await getj(u);document.getElementById(id).innerText=JSON.stringify(j,null,2)}}
async function createClient(){const body={name:document.getElementById('name').value,email:document.getElementById('email').value||null,telegram_id:document.getElementById('tg').value||null,days:Number(document.getElementById('days').value||30)};const r=await fetch('/api/admin/clients',{method:'POST',headers:{...auth(),'Content-Type':'application/json'},body:JSON.stringify(body)});document.getElementById('created').innerText=JSON.stringify(await r.json(),null,2);loadAll()}
document.getElementById('token').value=localStorage.getItem('vpnx7-admin')||'';
</script></body></html>""")
