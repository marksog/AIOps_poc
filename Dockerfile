# syntax=docker/dockerfile:1

# ---- Stage 1: builder ----------------------------------------------------
# Installs deps into a venv. The build stage can carry compilers etc;
# none of that ships to the final image.
FROM python:3.13-slim AS builder

# Don't write .pyc, don't buffer stdout (logs show up immediately — matters
# for observability: you want container logs in real time, not buffered).
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /build

# Some wheels (asyncpg, greenlet) may need build tooling on slim images.
RUN apt-get update && apt-get install -y --no-install-recommends gcc \
    && rm -rf /var/lib/apt/lists/*

# Create a venv we can copy wholesale into the runtime stage.
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Copy ONLY requirements first so this layer caches unless deps change.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# ---- Stage 2: runtime ----------------------------------------------------
FROM python:3.13-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH"

# Non-root user. Running as root inside a container is an unnecessary
# blast-radius. CKS-flavored hardening, done from day one.
RUN useradd --create-home --uid 10001 appuser

WORKDIR /app

# Writable location for ephemeral local state (the SQLite file). Kept
# OUT of the code directory on purpose: code dirs should be read-only,
# state lives somewhere explicit and writable. In-cluster this is moot —
# DATABASE_URL points at RDS — but it keeps the image runnable standalone.
RUN mkdir /data && chown appuser:appuser /data

# Bring over just the built venv from the builder — no gcc, no apt caches.
COPY --from=builder /opt/venv /opt/venv

# Copy app code last (changes most often -> keep its layer near the top of
# the cache invalidation order).
COPY app ./app

USER appuser

# Default the local SQLite file into the writable dir (four slashes = an
# ABSOLUTE path in a SQLite URL). In-cluster, DATABASE_URL is overridden
# with the RDS URL — same override mechanism as the incident dials.
ENV DATABASE_URL="sqlite+aiosqlite:////data/local.db"

EXPOSE 8000

# No --reload in production. One worker is fine for this demo; in prod you'd
# tune workers or run behind a process manager / multiple replicas.
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]