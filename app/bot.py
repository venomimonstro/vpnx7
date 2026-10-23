from __future__ import annotations

import asyncio
from datetime import datetime, timezone

from aiogram import Bot, Dispatcher
from aiogram.filters import Command
from aiogram.types import Message

from app.db import db, init_db
from app.settings import settings


dp = Dispatcher()


def access_for_telegram(telegram_id: str):
    with db() as conn:
        return conn.execute(
            """
            SELECT name, subscription_token, enabled, expires_at
            FROM clients
            WHERE telegram_id=?
            ORDER BY created_at DESC
            LIMIT 1
            """,
            (telegram_id,),
        ).fetchone()


def active(row) -> bool:
    if not row or not row["enabled"]:
        return False
    try:
        return datetime.fromisoformat(row["expires_at"]) > datetime.now(timezone.utc)
    except ValueError:
        return False


@dp.message(Command("start"))
async def start(message: Message) -> None:
    row = access_for_telegram(str(message.from_user.id))
    if active(row):
        await message.answer(
            "VPNX7 готов.\n"
            "Команды:\n/access — ссылка для подключения\n/status — срок доступа"
        )
    else:
        await message.answer(
            "VPNX7. Доступ пока не активирован. "
            f"Ваш Telegram ID: {message.from_user.id}\n"
            "Передайте этот ID администратору или оформите доступ на сайте."
        )


@dp.message(Command("status"))
async def status(message: Message) -> None:
    row = access_for_telegram(str(message.from_user.id))
    if not active(row):
        await message.answer("Активного доступа нет.")
        return
    await message.answer(f'Доступ активен до {row["expires_at"]}.')


@dp.message(Command("access"))
async def access(message: Message) -> None:
    row = access_for_telegram(str(message.from_user.id))
    if not active(row):
        await message.answer("Активного доступа нет.")
        return
    connect_url = f'{settings.public_url}/connect/{row["subscription_token"]}'
    await message.answer(f"Страница подключения:\n{connect_url}")


async def main() -> None:
    init_db()
    if not settings.telegram_bot_token:
        raise SystemExit("VPNX7_TELEGRAM_BOT_TOKEN is not configured")
    bot = Bot(settings.telegram_bot_token)
    await dp.start_polling(bot)


if __name__ == "__main__":
    asyncio.run(main())
