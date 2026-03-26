#!/bin/bash
# Vault initialization script for microk8s
# Run once after the first Vault deployment
set -euo pipefail

VAULT_NAMESPACE="vault"
VAULT_POD="vault-0"
VAULT_ADDR="http://127.0.0.1:8200"
KEYS_FILE="./vault-keys.json"   # keep this file SECRET and out of git

export VAULT_ADDR

# ── Helpers ────────────────────────────────────────────────────────────────────

vault_exec() {
  kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- vault "$@"
}

wait_for_vault() {
  echo "Waiting for Vault pod to be ready..."
  kubectl wait pod/"$VAULT_POD" \
    -n "$VAULT_NAMESPACE" \
    --for=condition=Ready \
    --timeout=120s
}

# ── 1. Init ────────────────────────────────────────────────────────────────────

init_vault() {
  if vault_exec status -format=json 2>/dev/null | grep -q '"initialized": true'; then
    echo "Vault already initialized, skipping."
    return
  fi

  echo "Initializing Vault..."
  vault_exec operator init \
    -key-shares=3 \
    -key-threshold=2 \
    -format=json > "$KEYS_FILE"

  echo "Unseal keys and root token saved to: $KEYS_FILE"
  echo "!! Store this file securely and remove it from this machine !!"
}

# ── 2. Unseal ──────────────────────────────────────────────────────────────────

unseal_vault() {
  if vault_exec status -format=json 2>/dev/null | grep -q '"sealed": false'; then
    echo "Vault already unsealed, skipping."
    return
  fi

  echo "Unsealing Vault..."
  local keys
  keys=$(jq -r '.unseal_keys_b64[:2][]' "$KEYS_FILE")

  for key in $keys; do
    vault_exec operator unseal "$key"
  done
}

# ── 3. Login ───────────────────────────────────────────────────────────────────

login_vault() {
  local root_token
  root_token=$(jq -r '.root_token' "$KEYS_FILE")
  vault_exec login "$root_token" > /dev/null
  echo "Logged in with root token."
}

# ── 4. KV secrets engine ───────────────────────────────────────────────────────

enable_kv() {
  if vault_exec secrets list -format=json | grep -q '"secret/"'; then
    echo "KV v2 already enabled at secret/, skipping."
    return
  fi

  echo "Enabling KV v2 secrets engine at secret/..."
  vault_exec secrets enable -path=secret kv-v2
}

# ── 5. Kubernetes auth ─────────────────────────────────────────────────────────

enable_k8s_auth() {
  if vault_exec auth list -format=json | grep -q '"kubernetes/"'; then
    echo "Kubernetes auth already enabled, skipping."
    return
  fi

  echo "Enabling Kubernetes auth method..."
  vault_exec auth enable kubernetes

  echo "Configuring Kubernetes auth..."
  vault_exec write auth/kubernetes/config \
    kubernetes_host="https://kubernetes.default.svc"
}

# ── 6. Policy ──────────────────────────────────────────────────────────────────

create_policy() {
  echo "Creating ESO policy..."
  local policy='path "secret/data/k8s/*" { capabilities = ["read"] } path "secret/metadata/k8s/*" { capabilities = ["read", "list"] } path "secret/data/k8s/dns-web" { capabilities = ["read"] }'
  kubectl exec -i -n "$VAULT_NAMESPACE" "$VAULT_POD" -- \
    vault policy write eso-policy - <<< "$policy"
}

# ── 7. Role ────────────────────────────────────────────────────────────────────

create_role() {
  echo "Creating Kubernetes auth role for ESO..."
  vault_exec write auth/kubernetes/role/eso-role \
    bound_service_account_names="external-secrets" \
    bound_service_account_namespaces="external-secrets" \
    policies="eso-policy" \
    ttl="1h"
}

# ── 8. Seed pdns secret ────────────────────────────────────────────────────────

seed_pdns_secret() {
  echo "Writing pdns api-key to Vault..."
  local api_key="${PDNS_API_KEY:-}"

  if [ -z "$api_key" ]; then
    echo "PDNS_API_KEY env var not set — generating a random key..."
    api_key=$(openssl rand -base64 32)
    echo "Generated api-key: $api_key"
    echo "Update helm_values/values-micro.yaml if needed."
  fi

  vault_exec kv put secret/k8s/pdns api-key="$api_key"
  echo "pdns api-key written to secret/k8s/pdns"
}

# ── 9. Seed dns-web secret ─────────────────────────────────────────────────────

seed_web_secret() {
  echo "Writing dns-web nextauth-secret to Vault..."
  local secret
  secret=$(openssl rand -base64 48)
  vault_exec kv put secret/k8s/dns-web nextauth-secret="$secret"
  echo "dns-web nextauth-secret written to secret/k8s/dns-web"
}

# ── Main ───────────────────────────────────────────────────────────────────────

main() {
  wait_for_vault
  init_vault
  unseal_vault
  login_vault
  enable_kv
  enable_k8s_auth
  create_policy
  create_role
  seed_pdns_secret
  seed_web_secret

  echo ""
  echo "Vault initialization complete."
  echo "Next steps:"
  echo "  1. Store $KEYS_FILE securely (e.g. password manager) and delete it here"
  echo "  2. Apply ClusterSecretStore:  kubectl apply -f manifests/cluster-secret-store.yaml"
  echo "  3. Apply ExternalSecret:      kubectl apply -f manifests/external-secret-pdns.yaml"
  echo "                                kubectl apply -f manifests/external-secret-web.yaml"
  echo "  4. Deploy pdns with ESO:      helm upgrade --install pdns ../k8s_pdns/helm -f ../k8s_pdns/helm_values/values-micro.yaml -n dns --create-namespace"
}

main
