#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE=headlamp
SERVICE_ACCOUNT=headlamp
SECRET_NAME=headlamp-admin-token
KUBE_CONFIG=${KUBECONFIG:-$HOME/.kube/config}

usage() {
  cat <<'EOF'
Usage: ./scripts/show-headlamp-token.sh [--namespace <namespace>] [--secret <name>] [--kubeconfig <path>]

Show the Headlamp bearer token stored by the Headlamp Helm deployment.
This token can be used for token-based login to http://headlamp.homeserver.

Options:
  --namespace   Kubernetes namespace where Headlamp is installed (default: headlamp)
  --secret      Secret name containing the token (default: headlamp-admin-token)
  --kubeconfig  Path to kubeconfig file (default: $HOME/.kube/config or $KUBECONFIG)
  -h, --help    Show this help message.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --namespace)
      shift
      NAMESPACE=${1:-}
      ;;
    --secret)
      shift
      SECRET_NAME=${1:-}
      ;;
    --kubeconfig)
      shift
      KUBE_CONFIG=${1:-}
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
  echo "Error: kubectl is required." >&2
  exit 1
fi

if [[ ! -f "$KUBE_CONFIG" ]]; then
  echo "Error: kubeconfig not found at $KUBE_CONFIG" >&2
  exit 1
fi

kubectl_cmd=(kubectl --kubeconfig "$KUBE_CONFIG")

if ! "${kubectl_cmd[@]}" version --short >/dev/null 2>&1; then
  echo "Error: kubectl cannot reach the cluster with kubeconfig $KUBE_CONFIG." >&2
  echo "Check your kubeconfig or your cluster connection." >&2
  exit 1
fi

if ! "${kubectl_cmd[@]}" -n "$NAMESPACE" get namespace >/dev/null 2>&1; then
  echo "Error: namespace '$NAMESPACE' does not exist or is not accessible." >&2
  exit 1
fi

if ! "${kubectl_cmd[@]}" -n "$NAMESPACE" get secret "$SECRET_NAME" >/dev/null 2>&1; then
  echo "Warning: secret '$SECRET_NAME' not found in namespace '$NAMESPACE'."
  echo "Searching for a ServiceAccount token for serviceaccount '$SERVICE_ACCOUNT'..."
  SECRET_NAME=$(
    "${kubectl_cmd[@]}" -n "$NAMESPACE" get secret \
      --field-selector type=kubernetes.io/service-account-token \
      -o jsonpath='{range .items[*]}{.metadata.name}||{.metadata.annotations.kubernetes.io/service-account.name}\n{end}' \
      | awk -F '||' '$2 == "'$SERVICE_ACCOUNT'" { print $1; exit }'
  )
  if [[ -z "$SECRET_NAME" ]]; then
    echo "Error: no token secret found for serviceaccount '$SERVICE_ACCOUNT'." >&2
    exit 1
  fi
  echo "Found secret: $SECRET_NAME"
fi

TOKEN=$("${kubectl_cmd[@]}" -n "$NAMESPACE" get secret "$SECRET_NAME" -o jsonpath='{.data.token}' 2>/dev/null || true)

if [[ -z "$TOKEN" ]]; then
  echo "Error: Secret '$SECRET_NAME' does not contain a token or is not of type kubernetes.io/service-account-token." >&2
  exit 1
fi

TOKEN=$(printf '%s' "$TOKEN" | base64 --decode)

echo "Headlamp URL: http://headlamp.homeserver"
echo "Bearer token for login:"
echo
printf '%s\n' "$TOKEN"
echo
cat <<EOF
Use this token on the Headlamp login screen.
If you want to avoid kubeconfig issues, export KUBECONFIG before running the script.
EOF
