#!/usr/bin/env bash
# ============================================================================
# Create the alerting secrets (Telegram) for Alertmanager and kwatch
# ============================================================================
# The bot token and chat ID come from Telegram and must not be committed
# (public repo), so these two secrets are created by hand once per cluster:
#   monitoring/alertmanager-config  (key alertmanager.yaml)
#   kwatch/kwatch-config            (key config.yaml)
# Both are rendered from the templates in scripts/alerting/.
#
# Usage:
#   TELEGRAM_BOT_TOKEN=123:abc TELEGRAM_CHAT_ID=456 ./scripts/create-alerting-secrets.sh
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$ROOT_DIR/.kubeconfig}"

: "${TELEGRAM_BOT_TOKEN:?set TELEGRAM_BOT_TOKEN (from @BotFather)}"
: "${TELEGRAM_CHAT_ID:?set TELEGRAM_CHAT_ID (numeric, from getUpdates)}"
[[ "$TELEGRAM_CHAT_ID" =~ ^-?[0-9]+$ ]] || { echo "TELEGRAM_CHAT_ID must be numeric" >&2; exit 1; }
export TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID

render() { envsubst '${TELEGRAM_BOT_TOKEN} ${TELEGRAM_CHAT_ID}' < "$SCRIPT_DIR/alerting/$1" | base64 -w0; }

secret() { # namespace name key template
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: $2
  namespace: $1
type: Opaque
data:
  $3: $(render "$4")
EOF
}

secret monitoring alertmanager-config alertmanager.yaml alertmanager.yaml.tmpl
secret kwatch kwatch-config config.yaml kwatch-config.yaml.tmpl

# kwatch reads its config only at startup
kubectl -n kwatch rollout restart deployment kwatch 2>/dev/null || true
