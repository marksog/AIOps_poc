# sentinel/Dockerfile
FROM python:3.13-slim

WORKDIR /app

# Only httpx needed for the Vault client (mcp comes later for the agent).
COPY requirements.txt .
RUN pip install --no-cache-dir httpx

COPY vault_client.py vault_check.py ./

# Non-root, same hardening instinct as checkout-svc.
RUN useradd --uid 10001 sentinel
USER sentinel

CMD ["python", "vault_check.py"]