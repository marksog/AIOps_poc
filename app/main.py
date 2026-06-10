import asyncio
import random
import time
import json
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Response
from prometheus_client import (
    Counter,
    Gauge,
    Histogram,
    generate_latest,
    CONTENT_TYPE_LATEST,
)
from sqlalchemy import text
from app.config import settings
from app.db import Checkout, SessionLocal, init_db, db_sleep, engine


# --- Metrics --------------------------------------------------------------
# RED ( Request rate, Error rate, and Duration)for HTTP. Labels let me slice by route and outcome — that's how a
# graph separates "which endpoint" and "success vs error".

REQUESTS = Counter(
    "http_requests_total", "Total HTTP requests",
    ["method", "path", "status"],
)

LATENCY = Histogram(
    "http_request_duration_seconds", "HTTP request latency in seconds",
    ["method", "path"],
)

# DB layer — the second, independent dimension of evidence.
DB_INFLIGHT = Gauge(
    "db_inflight_queries", "DB queries currently in flight",
)
DB_ERRORS = Counter(
    "db_errors_total", "DB errors (incl. pool-timeout exhaustion)",
    ["kind"],
)
DB_LATENCY = Histogram(
    "db_operation_duration_seconds", "Time spent in the DB layer",
)

@asynccontextmanager
async def lifespan(app: FastAPI):
    """App startup/shutdown events. On startup, we init the DB (create tables).
    In a real app you'd do this with migrations, but this is fine for demo."""
    await init_db()
    yield

app = FastAPI(title="checkout-svc", lifespan=lifespan)

# --- /healthz -------------------------------------------------------------
# A REAL connectivity check: runs SELECT 1 against the DB. If the DB is
# unreachable, healthz fails. This is what makes the rollout gate (Phase 4)
# and the k8s probes meaningful — "healthy" must mean "can talk to its DB".
@app.get("/healthz")
async def healthz():
    start = time.perf_counter()
    try:
        async with SessionLocal() as session:
            await session.execute(text("SELECT 1"))
        status = "200"
        body = {"status": "ok"}
    except Exception as e:
        status = "503"
        body = {"status": "db_unreachable", "details": str(e)}
        DB_ERRORS.labels(kind="healthz").inc()
    finally:
        LATENCY.labels(method="GET", path="/healthz").observe(time.perf_counter() - start)
        REQUESTS.labels(method="GET", path="/healthz", status=status).inc()
    return Response(content=__import__("json").dumps(body), 
                            media_type="application/json", status_code=int(status))


# --- /checkout ----------------------------------------------------------
@app.post("/checkout")
async def checkout(item: str = "widget"):
    start = time.perf_counter()
    method, path = "POST", "/checkout"

    # DIAL 1 — FAILURE_RATE: pure app-layer fault, BEFORE touching the DB.
    # Note the ordering: we fail early so the DB stays clean. That's what
    # makes this distinguishable from a DB problem on the graphs.
    if random.random() < settings.failure_rate:
        REQUESTS.labels(method=method, path=path, status="500").inc()
        LATENCY.labels(method=method, path=path).observe(time.perf_counter() - start)
        return Response(
            content='{"error": "injected app failure"}', 
            media_type="application/json", 
            status_code=500
        )
    
    # DIAL 2 — LATENCY_CEIL: slow APP, healthy DB. Sleep in the handler,
    # NOT in the DB path, so duration rises but db_operation stays flat.
    if settings.latency_ceil > 0:
        await asyncio.sleep(random.uniform(0, settings.latency_ceil))

    # --- DB write (real round-trip) ---
    DB_INFLIGHT.inc()                    # gauge up while we hold/await a conn
    db_start = time.perf_counter()
    try:
        # DIAL 4 — DB_QUERY_DELAY: slow DB, healthy app. Time burned here
        # lands in DB_LATENCY, not app latency. Correct attribution.
        await db_sleep(settings.db_query_delay)

        async with SessionLocal() as session:
            session.add(Checkout(item=item))
            await session.commit()
        status = "200"
        result = {"status": "ok", "item": item}
    except Exception as e:
        # DIAL 3 lands HERE: when pool_size is tiny and concurrency is high,
        # acquiring a session times out (pool_timeout) and raises. We count
        # it as a DB error of kind "pool_timeout-ish" / generic db error.
        DB_ERRORS.labels(kind="checkout").inc()
        status = "500"
        result = {"status": "db_error", "details": str(e)}
    finally:
        DB_LATENCY.observe(time.perf_counter() - db_start)
        DB_INFLIGHT.dec()
        LATENCY.labels(method, path).observe(time.perf_counter() - start)
        REQUESTS.labels(method, path, status).inc()

    return Response(content=__import__("json").dumps(result), 
                    media_type="application/json", status_code=int(status))

# --- /metrics ----------------------------------------------------------
@app.get("/metrics")
async def metrics():
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)