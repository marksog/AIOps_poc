# Minimal in-cluster proof: fetch the Anthropic key from Vault using the
# pod's identity and confirm we got it. Prints only a prefix, never the key.
from vault_client import get_anthropic_key

key = get_anthropic_key()
print(f"Fetched key from Vault via pod identity: {key[:12]}... (len={len(key)})")