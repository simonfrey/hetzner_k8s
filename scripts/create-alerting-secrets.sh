#!/usr/bin/env bash
# ============================================================================
# Create the alerting secrets (Telegram) for Alertmanager and kwatch
# ============================================================================
# The bot token and chat ID come from Telegram and must not be committed
# (public repo), so these two secrets are created by hand once per cluster:
#   monitoring/alertmanager-config  (key alertmanager.yaml)
#   kwatch/kwatch-telegram          (keys token, chat-id; read via ${file:...})
# plus monitoring/telegram-credentials, so re-runs need no env vars.
#
# Usage:
#   TELEGRAM_BOT_TOKEN=123:abc TELEGRAM_CHAT_ID=456 ./scripts/create-alerting-secrets.sh
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$ROOT_DIR/.kubeconfig}"

# Re-runs (e.g. after editing a template) reuse the stored credentials.
stored() { kubectl -n monitoring get secret telegram-credentials -o "jsonpath={.data.$1}" 2>/dev/null | base64 -d; }
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-$(stored bot-token)}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-$(stored chat-id)}"

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

kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: telegram-credentials
  namespace: monitoring
type: Opaque
data:
  bot-token: $(printf %s "$TELEGRAM_BOT_TOKEN" | base64 -w0)
  chat-id: $(printf %s "$TELEGRAM_CHAT_ID" | base64 -w0)
EOF
secret monitoring alertmanager-config alertmanager.yaml alertmanager.yaml.tmpl
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: kwatch-telegram
  namespace: kwatch
type: Opaque
data:
  token: $(printf %s "$TELEGRAM_BOT_TOKEN" | base64 -w0)
  chat-id: $(printf %s "$TELEGRAM_CHAT_ID" | base64 -w0)
EOF

# kwatch resolves ${file:...} only at startup
kubectl -n kwatch rollout restart deployment kwatch 2>/dev/null || true
