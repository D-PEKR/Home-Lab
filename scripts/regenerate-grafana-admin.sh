#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE=monitoring
SECRET_NAME="grafana-admin"
DEPLOYMENT_NAME="monitoring-grafana"

usage() {
  cat <<'EOF'
Usage: ./scripts/regenerate-grafana-admin.sh [--secret <name>]

Regenerate the Grafana admin password for the monitoring stack.
If the configured Grafana secret is missing, the script creates it.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --secret)
      shift
      if [[ $# -eq 0 ]]; then
        echo "Missing value for --secret" >&2
        exit 1
      fi
      SECRET_NAME="$1"
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
  shift
 done

if ! command -v kubectl >/dev/null 2>&1; then
  echo "Error: kubectl command not found." >&2
  exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "Error: openssl is required to generate a random password." >&2
  exit 1
fi

PASSWORD=$(openssl rand -base64 16)
ENC_PASSWORD=$(printf '%s' "$PASSWORD" | base64 | tr -d '\n')

cat <<EOF
Using secret: $SECRET_NAME
Namespace: $NAMESPACE
Generated password: $PASSWORD
EOF

kubectl -n "$NAMESPACE" create secret generic "$SECRET_NAME" \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

if kubectl -n "$NAMESPACE" get deployment "$DEPLOYMENT_NAME" >/dev/null 2>&1; then
  echo "Restarting Grafana deployment $DEPLOYMENT_NAME..."
  kubectl -n "$NAMESPACE" rollout restart deployment/"$DEPLOYMENT_NAME"
fi

echo
cat <<EOF
Grafana admin password regenerated.
Login: admin
Password: $PASSWORD
URL: http://grafana.homeserver
EOF
