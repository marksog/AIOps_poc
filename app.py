import os
import random
import asyncio
import time
import contextlib
from fastapi import FastAPI, HTTPException, Response
from prometheus_client import Counter, Histogram, Gauge, generate_latest, CONTENT_TYPE_LATEST
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession, async_sessionmaker
from sqlalchemy import text

DATABASE_URL = os.getenv("DATABASE_URL", "sqlite+aiosqlite:///./local.db")

FAILURE_RATE = float(os.getenv("FAILURE_RATE", "0.0"))
LATENCY_CEIL = float(os.getenv("LATENCY_CEIL", "0.2"))
DB_POOL_SIZE = int(os.getenv("DB_POOL_SIZE", "5"))
DB_QUERY_DELAY = float(os.getenv("DB_QUERY_DELAY", "0.0"))

engine_kwargs = {}
if DATABASE_URL.startswith("postgresql"):
    engine_kwargs = {"pool_size": DB_POOL_SIZE, "max_overflow": 0, "pool_timeout": 5}

engine = create_async_engine(DATABASE_URL, **engine_kwargs)
SessionLocal = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)

app = FastAPI(title="checkout-svc")

REQUESTS = Counter("checkout_requests_total", "Total checkout requests", ["status"])
LATENCY = Histogram(
    "checkout_request_duration_seconds", "Checkout request latency",
    buckets=(0.05, 0.1, 0.25, 0.5, 0.75, 1.0, 2.5),
)
DB_ERRORS = Counter("checkout_db_errors_total", "DB errors (incl. pool timeouts)")
DB_INFLIGHT = Gauge("checkout_db_inflight", "In-flight DB operations")


@app.on_event("startup")
async def init_db():
    async with engine.begin() as conn:
        if DATABASE_URL.startswith("sqlite"):
            await conn.execute(text(
                "CREATE TABLE IF NOT EXISTS orders ("
                "id INTEGER PRIMARY KEY AUTOINCREMENT, created_at REAL)"))
        else:
            await conn.execute(text(
                "CREATE TABLE IF NOT EXISTS orders ("
                "id SERIAL PRIMARY KEY, created_at DOUBLE PRECISION)"))


@contextlib.asynccontextmanager
async def get_session():
    DB_INFLIGHT.inc()
    try:
        async with SessionLocal() as session:
            yield session
    finally:
        DB_INFLIGHT.dec()


@app.get("/")
async def root():
    return {"ok": True}


@app.get("/healthz")
async def healthz():
    try:
        async with engine.connect() as conn:
            await conn.execute(text("SELECT 1"))
        return {"db": "up"}
    except Exception:
        raise HTTPException(503, "db down")


@app.get("/checkout")
async def checkout():
    start = time.perf_counter()
    await asyncio.sleep(random.uniform(0.02, LATENCY_CEIL))

    if random.random() < FAILURE_RATE:
        REQUESTS.labels(status="error").inc()
        LATENCY.observe(time.perf_counter() - start)
        raise HTTPException(500, "downstream timeout")

    try:
        async with get_session() as session:
            if DB_QUERY_DELAY > 0:
                await asyncio.sleep(DB_QUERY_DELAY)
            await session.execute(
                text("INSERT INTO orders (created_at) VALUES (:t)"),
                {"t": time.time()},
            )
            await session.commit()
    except Exception as e:
        DB_ERRORS.inc()
        REQUESTS.labels(status="error").inc()
        LATENCY.observe(time.perf_counter() - start)
        raise HTTPException(503, f"db error: {type(e).__name__}")

    REQUESTS.labels(status="ok").inc()
    LATENCY.observe(time.perf_counter() - start)
    return {"order": "confirmed"}


@app.get("/metrics")
async def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)