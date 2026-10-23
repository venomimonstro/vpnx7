from __future__ import annotations

import asyncio
from datetime import datetime, timezone

from aiogram import Bot, Dispatcher
from aiogram.filters import Command
from aiogram.types import Message

from app.db import db, init_db
from app.settings import settings


dp = Dispatcher()


def utcnow_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def access_for_telegram(telegram_id: str):
    with db() as conn:
        return conn.execute(
            """
            SELECT name, subscription_token, enabled, expires_at
            FROM clients
            WHERE telegram_id=?
              AND enabled=1
              AND expires_at > ?
            ORDER BY expires_at DESC
            LIMIT 1
            """,
            (telegram_id, utcnow_iso()),
        ).fetchone()


def telegram_id(message: Message) -> str | None:
    if not message.from_user:
        return None
    return str(message.from_user.id)


@dp.message(Command("start"))
async def start(message: Message) -> None:
    tg_id = telegram_id(message)
    if not tg_id:
        return
    row = access_for_telegram(tg_id)
    if row:
        await message.answer(
            "VPNX7 готов.\n"
            "Команды:\n/access — ссылка для подключения\n/status — срок доступа"
        )
    else:
        await message.answer(
            "VPNX7. Активного доступа пока нет. "
            f"Ваш Telegram ID: {tg_id}\n"
            "Передайте этот ID администратору или создайте запрос на сайте."
        )


@dp.message(Command("status"))
async def status(message: Message) -> None:
    tg_id = telegram_id(message)
    if not tg_id:
        return
    row = access_for_telegram(tg_id)
    if not row:
        await message.answer("Активного доступа нет.")
        return
    await message.answer(f'Доступ активен до {row["expires_at"]}.')


@dp.message(Command("access"))
async def access(message: Message) -> None:
    tg_id = telegram_id(message)
    if not tg_id:
        return
    row = access_for_telegram(tg_id)
    if not row:
        await message.answer("Активного доступа нет.")
        return
    connect_url = f'{settings.public_url}/connect/{row["subscription_token"]}'
    await message.answer(f"Страница подключения:\n{connect_url}")


async def main() -> None:
    init_db()
    if not settings.telegram_bot_token:
        raise SystemExit("VPNX7_TELEGRAM_BOT_TOKEN is not configured")
    bot = Bot(settings.telegram_bot_token)
    try:
        await dp.start_polling(
            bot,
            allowed_updates=dp.resolve_used_update_types(),
        )
    finally:
        await bot.session.close()


if __name__ == "__main__":
    asyncio.run(main())
