path "secret/data/sentinel/*" {
  capabilities = ["read"]
}
path "secret/metadata/sentinel/*" {
  capabilities = ["read", "list"]
}
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
path "auth/token/renew-self" {
  capabilities = ["update"]
}
