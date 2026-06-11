# A read-only MCP server exposing Prometheus queries as agent tools.
# Read-only is deliberate: the agent can observe everything, mutate nothing.

import os
import httpx
from mcp.server.fastmcp import FastMCP

# FastMCP is the high-level SDK: declare tools with @mcp.tool() and it handles
# all the JSON-RPC protocol plumbing, schema generation, and transport.
mcp = FastMCP("prom-mcp")

# Where Prometheus lives. Locally we point at a port-forward (localhost:9090).
# In-cluster later this becomes the in-cluster service DNS. Env-var override
# keeps the same code working in both places — same pattern as DATABASE_URL.
PROM_URL = os.environ.get("PROM_URL", "http://localhost:9090")


async def _query(promql: str) -> dict:
    """Run an instant PromQL query against Prometheus and return the raw
    result. Helper used by the tools below."""
    async with httpx.AsyncClient(timeout=10) as client:
        r = await client.get(
            f"{PROM_URL}/api/v1/query",
            params={"query": promql},
        )
        r.raise_for_status()
        return r.json()


def _scalar(result: dict) -> float | None:
    """Extract a single float from a Prometheus vector result, or None if the
    query returned nothing (e.g. no traffic in the window)."""
    data = result.get("data", {}).get("result", [])
    if not data:
        return None
    # result[0]["value"] is [timestamp, "value_as_string"]
    return float(data[0]["value"][1])


@mcp.tool()
async def get_checkout_error_ratio(window: str = "5m") -> str:
    """Get the fraction of /checkout requests that are failing (5xx) over a
    time window. Returns a number 0.0-1.0. High = the app is erroring.
    Use this FIRST to confirm an incident is real and gauge severity.

    Args:
        window: Prometheus duration like '5m', '30m', '1h'. Default '5m'.
    """
    promql = (
        f'sum(rate(http_requests_total{{path="/checkout",status=~"5.."}}[{window}]))'
        f' / '
        f'sum(rate(http_requests_total{{path="/checkout"}}[{window}]))'
    )
    val = _scalar(await _query(promql))
    if val is None:
        return f"No checkout traffic in the last {window} (no data)."
    return f"Checkout error ratio over {window}: {val:.4f} ({val*100:.2f}% of requests failing)."


@mcp.tool()
async def get_db_inflight() -> str:
    """Get the current number of in-flight database queries. If this is
    ELEVATED while errors are high, the DB is likely the bottleneck (pool
    exhaustion or slow queries). If this is LOW/ZERO while errors are high,
    the problem is in the APP layer, not the DB. This is the key signal for
    distinguishing app faults from DB faults.
    """
    val = _scalar(await _query("db_inflight_queries"))
    if val is None:
        return "db_inflight_queries: no data."
    return f"DB in-flight queries: {val:.1f}"


@mcp.tool()
async def get_db_errors(window: str = "5m") -> str:
    """Get the rate of database errors over a window. Non-zero db_errors
    (especially pool-timeout kind) points at DB saturation rather than an
    app-logic fault.

    Args:
        window: Prometheus duration like '5m'. Default '5m'.
    """
    promql = f'sum(rate(db_errors_total[{window}]))'
    val = _scalar(await _query(promql))
    if val is None or val == 0:
        return f"DB error rate over {window}: 0 (no DB errors)."
    return f"DB error rate over {window}: {val:.4f}/s"


if __name__ == "__main__":
    # Run the server over stdio (the standard MCP transport for local tools).
    mcp.run()