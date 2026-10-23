from __future__ import annotations

from dataclasses import dataclass
import os


def _clean_url(value: str) -> str:
    return value.strip().rstrip("/")


@dataclass(frozen=True)
class Settings:
    bind: str = os.getenv("VPNX7_BIND", "0.0.0.0")
    port: int = int(os.getenv("VPNX7_PORT", "8080"))
    database_path: str = os.getenv("VPNX7_DATABASE", "/var/lib/vpnx7/vpnx7.db")
    public_url: str = _clean_url(os.getenv("VPNX7_PUBLIC_URL", "http://127.0.0.1:8080"))
    admin_token: str = os.getenv("VPNX7_ADMIN_TOKEN", "")
    node_bootstrap_token: str = os.getenv("VPNX7_NODE_BOOTSTRAP_TOKEN", "")
    provider_name: str = os.getenv("VPNX7_PROVIDER_NAME", "VPNX7")
    support_url: str = _clean_url(os.getenv("VPNX7_SUPPORT_URL", ""))
    telegram_bot_token: str = os.getenv("VPNX7_TELEGRAM_BOT_TOKEN", "")


settings = Settings()
