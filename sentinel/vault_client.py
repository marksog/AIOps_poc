# Fetches secrets from Vault using the pod's Kubernetes identity — no static
# Vault token, no API key baked into the image. This is the programmatic
# version of the `vault write auth/kubernetes/login` flow done by hand.

import os
import httpx

# In-cluster Vault address. Same service DNS the test pod used.
VAULT_ADDR = os.environ.get("VAULT_ADDR", "http://vault.vault.svc.cluster.local:8200")

# The role we created: binds SA `sentinel` in `default` to the `sentinel` policy.
VAULT_ROLE = os.environ.get("VAULT_ROLE", "sentinel")

# Where Kubernetes mounts the pod's projected service account token. Every pod
# gets this automatically; it's the pod's proof of identity.
SA_TOKEN_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token"


class VaultClient:
    """Minimal Vault client: login with the pod's SA token, then read secrets.
    Deliberately thin — no hvac library — so every HTTP call is visible and
    you can explain exactly what crosses the wire."""

    def __init__(self):
        self._token: str | None = None

    def _read_sa_token(self) -> str:
        """Read the projected Kubernetes service account token from disk.
        This is what the pod presents to Vault as proof of who it is."""
        with open(SA_TOKEN_PATH) as f:
            return f.read().strip()

    def login(self) -> str:
        """Exchange the Kubernetes SA token for a Vault token.

        This is the exact call you ran by hand:
            vault write auth/kubernetes/login role=sentinel jwt=$KUBE_TOKEN

        Vault takes the jwt, asks the Kubernetes TokenReview API 'is this real
        and whose is it?', matches the identity to the `sentinel` role, and
        returns a token carrying the `sentinel` policy with a 1h TTL."""
        jwt = self._read_sa_token()
        resp = httpx.post(
            f"{VAULT_ADDR}/v1/auth/kubernetes/login",
            json={"role": VAULT_ROLE, "jwt": jwt},
            timeout=10,
        )
        resp.raise_for_status()
        # The client token lives at auth.client_token in the response.
        self._token = resp.json()["auth"]["client_token"]
        return self._token

    def get_secret(self, path: str, key: str) -> str:
        """Read a single key from a KV v2 secret.

        NOTE the URL: KV v2 reads go through <mount>/data/<path>. That 'data'
        segment is the same one your policy needed (secret/data/sentinel/*).
        The actual values live under .data.data in the JSON response — KV v2
        nests the secret data one level deeper than KV v1."""
        if self._token is None:
            self.login()
        resp = httpx.get(
            f"{VAULT_ADDR}/v1/secret/data/{path}",
            headers={"X-Vault-Token": self._token},
            timeout=10,
        )
        resp.raise_for_status()
        return resp.json()["data"]["data"][key]


def get_anthropic_key() -> str:
    """Return the Anthropic API key.

    Resolution order:
      1. In-cluster: if the projected SA token exists, fetch from Vault using
         the pod's identity (the real path).
      2. Local dev: if there's no SA token (running on a laptop), fall back to
         the ANTHROPIC_API_KEY env var so the code is runnable outside k8s.

    This dual path is deliberate: production uses Vault, development doesn't
    need a running cluster to iterate. The fallback NEVER triggers in-cluster
    because the token file always exists there — so it can't accidentally
    weaken the production path."""
    if os.path.exists(SA_TOKEN_PATH):
        # Real path: we're in a pod with an identity. Use Vault.
        return VaultClient().get_secret("sentinel/anthropic", "api_key")

    # Fallback: local dev. No pod identity available.
    key = os.environ.get("ANTHROPIC_API_KEY")
    if not key:
        raise RuntimeError(
            "No SA token (not in-cluster) and ANTHROPIC_API_KEY not set. "
            "Set it in sentinel/.env for local dev, or run inside a pod."
        )
    return key