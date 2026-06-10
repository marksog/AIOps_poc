import asyncio

from sqlalchemy import Column, DateTime, Integer, String, func, text
from sqlalchemy.ext.asyncio import (
    AsyncSession,
    create_async_engine,
    async_sessionmaker
)
from sqlalchemy.orm import DeclarativeBase

from app.config import settings


class Base(DeclarativeBase):
    pass


class Checkout(Base):
    """One row per successful /checkout. The point isn't the schema —
    it's that /checkout does a REAL write, so /healthz checking DB
    connectivity actually means something, and so DB stalls are
    observable as real round-trips."""
    __tablename__ = "checkouts"

    id = Column(Integer, primary_key=True)
    item = Column(String, nullable=False)
    created_at = Column(DateTime(timezone=True), server_default=func.now())


# --- Engine ---------------------------------------------------------------
# pool_size = db_pool_size is the lever for the exhaustion dial.
# max_overflow=0 means: do NOT allow temporary extra connections beyond
# the pool. Without this, the pool would silently grow and we'd never
# see exhaustion. Setting it to 0 makes "pool full -> requests wait" real.
#
# SQLite note: it ignores pool_size meaningfully. That's expected.
# This dial does its real work against Postgres/RDS.
_is_sqlite = settings.database_url.startswith("sqlite")

engine_kwargs = {"echo": False}
if not _is_sqlite:
    engine_kwargs.update(
        pool_size=settings.db_pool_size,
        max_overflow=0,
        pool_timeout=5,  # seconds a request waits for a free conn before erroring
    )

engine = create_async_engine(settings.database_url, **engine_kwargs)

SessionLocal = async_sessionmaker(
    engine,
    class_=AsyncSession,
    expire_on_commit=False,
)


async def init_db():
    """Create tables. Fine for demo purposes; in prod you'd use Alembic migrations or similar."""
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)


async def db_sleep(seconds: float) -> None:
    """Burn time INSIDE the DB layer so it's attributed as DB latency,
    not app latency. On Postgres we use a real server-side sleep so the
    time is genuinely spent in the round-trip. On SQLite we fall back to
    an async sleep (no SQL sleep fn exists) — less pure, still tagged as
    DB time by where we call it."""
    if seconds <= 0:
        return
    if _is_sqlite:
        await asyncio.sleep(seconds)
    else:
        async with engine.connect() as conn:
            await conn.execute(text("SELECT pg_sleep(:s)"), {"s": seconds})