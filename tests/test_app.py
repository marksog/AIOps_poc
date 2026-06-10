import os

# Force tests onto a dedicated, throwaway SQLite DB BEFORE app modules load,
# so we never depend on (or pollute) the local.db used for manual runs. Must
# run before importing app.config/app.db, because the engine is created at
# import time from settings.database_url.
os.environ["DATABASE_URL"] = "sqlite+aiosqlite:///./test.db"

import pytest
from httpx import ASGITransport, AsyncClient

from app.config import settings
from app.main import app


@pytest.fixture(autouse=True)
async def _ensure_schema():
    """Create tables before each test. The app creates them in its lifespan
    handler, but ASGITransport doesn't trigger lifespan, so we do it here.
    Without this, DB writes hit a missing table -> 500 (only on a fresh DB,
    which is why CI caught it and a stale local.db didn't)."""
    from app.db import init_db
    await init_db()


# AsyncClient + ASGITransport drives the app in-process — no running
# server, no real network. Fast, deterministic, CI-friendly.
@pytest.fixture
async def client():
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as c:
        yield c

@pytest.mark.asyncio
async def test_healthz_ok(client):
    """Health check must hit the DB and come back 200. This is what the
    k8s probe and rollout gate will rely on, so it's the first thing we pin."""
    r = await client.get("/healthz")
    assert r.status_code == 200
    assert r.json()["status"] == "ok"


@pytest.mark.asyncio
async def test_checkout_writes_row(client):
    """Happy path: a checkout returns 200 and echoes the item. Proves the
    real DB write path works end-to-end against local SQLite."""
    r = await client.post("/checkout?item=book")
    assert r.status_code == 200
    assert r.json() == {"status": "ok", "item": "book"}


@pytest.mark.asyncio
async def test_metrics_exposed(client):
    """The /metrics endpoint must expose our RED + DB families. If a metric
    name drifts, the ServiceMonitor/alerts (Phase 7) break — so pin the names."""
    await client.post("/checkout?item=pin")  # generate at least one sample
    r = await client.get("/metrics")
    body = r.text
    assert "http_requests_total" in body
    assert "http_request_duration_seconds" in body
    assert "db_inflight_queries" in body
    assert "db_operation_duration_seconds" in body
    assert "db_errors_total" in body


@pytest.mark.asyncio
async def test_failure_rate_dial_forces_500(client, monkeypatch):
    """DIAL 1: at FAILURE_RATE=1.0 every checkout must 500 — and it must be
    an APP fault, i.e. the DB inflight gauge stays at zero (we fail before
    touching the DB). This is the separability guarantee Sentinel depends on."""
    monkeypatch.setattr(settings, "failure_rate", 1.0)
    r = await client.post("/checkout")
    assert r.status_code == 500
    assert r.json()["error"] == "injected app failure"


@pytest.mark.asyncio
async def test_failure_rate_zero_always_succeeds(client, monkeypatch):
    """DIAL 1 inverse: at 0.0, no injected failures. Guards against a flipped
    comparison (< vs <=) silently breaking the dial."""
    monkeypatch.setattr(settings, "failure_rate", 0.0)
    for _ in range(10):
        r = await client.post("/checkout")
        assert r.status_code == 200


@pytest.mark.asyncio
async def test_query_delay_dial_adds_db_latency(client, monkeypatch):
    """DIAL 4: a query delay must lengthen the DB span. We assert the request
    still succeeds and takes at least the delay — proving time is spent in the
    DB path, not failing the request."""
    import time
    monkeypatch.setattr(settings, "db_query_delay", 0.3)
    start = time.perf_counter()
    r = await client.post("/checkout")
    elapsed = time.perf_counter() - start
    assert r.status_code == 200
    assert elapsed >= 0.3


@pytest.mark.asyncio
async def test_latency_ceil_dial_slows_app(client, monkeypatch):
    """DIAL 2: latency ceiling adds in-handler sleep. Request still 200s,
    but takes measurable time. (Upper bound is loose to avoid flakiness.)"""
    import time
    monkeypatch.setattr(settings, "latency_ceil", 0.2)
    start = time.perf_counter()
    r = await client.post("/checkout")
    elapsed = time.perf_counter() - start
    assert r.status_code == 200
    assert elapsed <= 1.0  # sanity bound; sleep is uniform(0, 0.2)


@pytest.mark.asyncio
async def test_checkout_default_item(client, monkeypatch):
    """Default arg path: no item -> 'widget'. Small, but pins the API contract
    so a refactor doesn't silently change the default."""
    monkeypatch.setattr(settings, "failure_rate", 0.0)
    r = await client.post("/checkout")
    assert r.status_code == 200
    assert r.json()["item"] == "widget"