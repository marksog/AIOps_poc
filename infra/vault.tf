# infra/vault.tf
# AWS resources Vault needs for KMS auto-unseal.
#
# The seal architecture: Vault encrypts all stored data with an encryption
# key. That encryption key is itself encrypted by a MASTER key. Auto-unseal
# means the master key is encrypted by THIS KMS key and stored as ciphertext;
# on startup Vault calls kms:Decrypt to recover it. No human unseal ceremony.

# --- The unseal key -------------------------------------------------------
resource "aws_kms_key" "vault_unseal" {
  description = "Vault auto-unseal key for ${var.project}"

  # SYMMETRIC_DEFAULT + ENCRYPT_DECRYPT is what Vault's awskms seal expects.
  key_usage = "ENCRYPT_DECRYPT"

  # Rotation: AWS rotates the backing key material annually. Vault is
  # unaffected — it always calls Decrypt against the key ID, and KMS
  # transparently uses whatever material encrypted the ciphertext. Free.
  enable_key_rotation = true

  # COST/SAFETY: KMS keys CANNOT be deleted immediately. `terraform destroy`
  # SCHEDULES deletion, and the key bills (~$1/mo) for the entire window.
  # 7 days is the minimum AWS permits. During the window the key is
  # "PendingDeletion" and Vault CANNOT unseal with it — cancel the deletion
  # if you need it back.
  deletion_window_in_days = 7

  tags = { Name = "${var.project}-vault-unseal" }
}

# An alias gives the key a human-readable name. The key ID is a UUID; the
# alias is what you'll recognise in the console and in logs.
resource "aws_kms_alias" "vault_unseal" {
  name          = "alias/${var.project}-vault-unseal"
  target_key_id = aws_kms_key.vault_unseal.key_id
}

# --- Vault's identity (IRSA) ---------------------------------------------
# Same keyless pattern as the EBS CSI role and the GitHub deployer: the
# service account's projected token is presented to AWS STS, the trust
# policy checks the `sub` claim, and STS returns temporary credentials.
# No AWS access keys anywhere in the cluster.
resource "aws_iam_role" "vault" {
  name = "${var.project}-vault-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_provider_bare}:aud" = "sts.amazonaws.com"
          # Scoped to EXACTLY the vault service account in the vault
          # namespace. Nothing else in the cluster can assume this role.
          "${local.oidc_provider_bare}:sub" = "system:serviceaccount:vault:vault"
        }
      }
    }]
  })
}

# LEAST PRIVILEGE: three actions, ONE key. Not kms:* , not Resource "*".
# Encrypt+Decrypt are the seal/unseal operations; DescribeKey lets Vault
# verify the key exists and is usable at startup.
resource "aws_iam_role_policy" "vault_kms" {
  name = "${var.project}-vault-kms-policy"
  role = aws_iam_role.vault.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:DescribeKey",
      ]
      Resource = aws_kms_key.vault_unseal.arn
    }]
  })
}

output "vault_kms_key_id" {
  value       = aws_kms_key.vault_unseal.key_id
  description = "Feed this into the Vault Helm values (seal stanza)."
}

output "vault_role_arn" {
  value       = aws_iam_role.vault.arn
  description = "Annotate the vault ServiceAccount with this for IRSA."
}