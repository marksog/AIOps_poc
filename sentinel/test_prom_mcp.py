# Exercises prom-mcp with NO LLM — just the MCP client talking to our server.
# Proves the tools work in isolation before we ever wire up an agent.
import asyncio
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


async def main():
    # Launch our server as a subprocess and speak MCP to it over stdio.
    server = StdioServerParameters(command="python", args=["prom_mcp.py"])

    async with stdio_client(server) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()

            # List what tools the server offers (the agent does this too).
            tools = await session.list_tools()
            print("Tools offered:")
            for t in tools.tools:
                print(f"  - {t.name}: {t.description.splitlines()[0]}")
            print()

            # Call each tool and print the result.
            for name, args in [
                ("get_checkout_error_ratio", {"window": "5m"}),
                ("get_db_inflight", {}),
                ("get_db_errors", {"window": "5m"}),
            ]:
                result = await session.call_tool(name, args)
                text = result.content[0].text
                print(f"{name}({args}) -> {text}")


if __name__ == "__main__":
    asyncio.run(main())