from pydantic_settings import BaseSettings, SettingsConfigDict

class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    #------Database--------
    # Local default = SQLite (no cloud needed). In-cluster we override
    # this with the RDS URL injected from a k8s Secret later
    database_url: str = "sqlite+aiosqlite:///./local.db"

    # 1) APP failure: fraction of /checkout calls that throw 500 outright.
    #    0.0 = healthy, 0.3 = 30% of requests error. Pure app-layer fault.
    failure_rate: float = 0.0

    # 2) APP latency: artificial sleep ceiling (seconds) added in-handler.
    #    Inflates duration without touching the DB. "Slow app, healthy DB."
    latency_ceil: float = 0.0

    # 3) DB saturation: connection pool size. Set this LOW (e.g. 1-2) and
    #    drive concurrency up -> requests queue waiting for a connection.
    #    This is "DB is the bottleneck" via exhaustion, not app bugs.
    db_pool_size: int = 5

    # 4) DB slowness: artificial delay (seconds) inside the DB query path.
    #    Simulates a slow query / locked table. "DB is slow, app is fine."
    db_query_delay: float = 0.0


settings = Settings()