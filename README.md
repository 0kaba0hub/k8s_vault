# k8s_vault

HashiCorp Vault + External Secrets Operator for microk8s.

Secrets are stored in Vault and synced into Kubernetes via ESO `ExternalSecret` resources.
Auth between ESO and Vault uses the **Kubernetes auth method** (ESO ServiceAccount token).

## Directory layout

```
k8s_vault/
├── helm_values/
│   ├── values-micro.yaml        # Vault standalone values
│   └── values-eso-micro.yaml    # External Secrets Operator values
├── manifests/
│   ├── cluster-secret-store.yaml  # ClusterSecretStore -> Vault
│   └── external-secret-pdns.yaml  # ExternalSecret for pdns api-key
└── scripts/
    └── vault-init.sh            # One-time Vault initialization
```

## Vault secret layout

```
secret/k8s/
  pdns/
    api-key
```

## Installation order

### 1. Deploy Vault

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

helm upgrade --install vault hashicorp/vault \
  -f helm_values/values-micro.yaml \
  -n vault --create-namespace
```

### 2. Initialize Vault

```bash
# Optionally pass a pre-existing api-key to seed in Vault
export PDNS_API_KEY="your-api-key"

bash scripts/vault-init.sh
```

The script will:
- Initialize Vault (3 key shares, threshold 2)
- Unseal Vault
- Enable KV v2 at `secret/`
- Enable and configure Kubernetes auth
- Create `eso-policy` (read access to `secret/data/k8s/*`)
- Create `eso-role` bound to ESO ServiceAccount
- Write the pdns api-key to `secret/k8s/pdns`

> **Important:** `vault-keys.json` contains unseal keys and root token.
> Store it securely (password manager) and **do not commit it to git**.

### 3. Deploy External Secrets Operator

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

helm upgrade --install external-secrets external-secrets/external-secrets \
  -f helm_values/values-eso-micro.yaml \
  -n external-secrets --create-namespace
```

### 4. Apply ClusterSecretStore and ExternalSecret

```bash
kubectl apply -f manifests/cluster-secret-store.yaml
kubectl apply -f manifests/external-secret-pdns.yaml
```

Check sync status:

```bash
kubectl get clustersecretstore vault-backend
kubectl get externalsecret pdns -n dns
```

### 5. Deploy pdns

```bash
helm upgrade --install pdns ../k8s_pdns/helm \
  -f ../k8s_pdns/helm_values/values-micro.yaml \
  -n dns --create-namespace
```

## Unseal after pod restart

Vault does not auto-unseal by default. After a pod restart run:

```bash
kubectl exec -n vault vault-0 -- vault operator unseal $(jq -r '.unseal_keys_b64[0]' vault-keys.json)
kubectl exec -n vault vault-0 -- vault operator unseal $(jq -r '.unseal_keys_b64[1]' vault-keys.json)
```

## Operations

### Access Vault UI

```bash
kubectl port-forward svc/vault 8200:8200 -n vault
# Open http://localhost:8200
```

### Read a secret

```bash
kubectl exec -n vault vault-0 -- vault kv get secret/k8s/pdns
```

### Update pdns api-key

```bash
kubectl exec -n vault vault-0 -- vault kv put secret/k8s/pdns api-key="new-key"
# ESO will sync the new value within refreshInterval (default: 1h)
# Force immediate sync:
kubectl annotate externalsecret pdns -n dns force-sync=$(date +%s) --overwrite
```
