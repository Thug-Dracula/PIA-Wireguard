#!/bin/bash
# Registers your WireGuard public key with PIA and writes the assigned peer IP
# back to .env as WIREGUARD_ADDRESSES. Run this on the HOST before starting
# the stack for the first time, and again whenever your PIA server changes.
set -euo pipefail

STACK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$STACK_DIR/.env"
TOKEN_FILE="$STACK_DIR/scripts/pia-token.txt"
CA_CERT="$STACK_DIR/scripts/pia-ca.crt"
LOG_PREFIX="$(date '+%Y-%m-%d %H:%M:%S') [pia-keyreg]"

if [ ! -f "$ENV_FILE" ]; then
  echo "$LOG_PREFIX: ERROR: .env not found at $ENV_FILE — copy .env.example and fill it in" >&2
  exit 1
fi

# Load .env
set -a; source "$ENV_FILE"; set +a

if [ -z "${WIREGUARD_PRIVATE_KEY:-}" ]; then
  echo "$LOG_PREFIX: ERROR: WIREGUARD_PRIVATE_KEY not set in .env" >&2
  exit 1
fi

WG_PUBKEY=$(echo "$WIREGUARD_PRIVATE_KEY" | wg pubkey)

echo "$LOG_PREFIX: Generating PIA token for ${PIA_USER}..."
TOKEN=$(curl -sf --max-time 15 \
  -u "${PIA_USER}:${PIA_PASS}" \
  "https://www.privateinternetaccess.com/gtoken/generateToken" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['token'])")

if [ -z "$TOKEN" ]; then
  echo "$LOG_PREFIX: ERROR: Failed to get PIA token" >&2
  exit 1
fi
echo "$TOKEN" > "$TOKEN_FILE"
echo "$LOG_PREFIX: Token written to $TOKEN_FILE"

echo "$LOG_PREFIX: Registering WireGuard key with ${PIA_SERVER_CN} (${VPN_ENDPOINT_IP}:${VPN_ENDPOINT_PORT})..."
ADDKEY=$(curl -sf --max-time 15 \
  --cacert "$CA_CERT" \
  --connect-to "${PIA_SERVER_CN}::${VPN_ENDPOINT_IP}:" \
  -G \
  --data-urlencode "pt=${TOKEN}" \
  --data-urlencode "pubkey=${WG_PUBKEY}" \
  "https://${PIA_SERVER_CN}:${VPN_ENDPOINT_PORT}/addKey")

STATUS=$(echo "$ADDKEY" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status','ERROR'))" 2>/dev/null || echo "ERROR")
if [ "$STATUS" != "OK" ]; then
  echo "$LOG_PREFIX: ERROR: addKey failed: $ADDKEY" >&2
  exit 1
fi

PEER_IP=$(echo "$ADDKEY" | python3 -c "import json,sys; print(json.load(sys.stdin)['peer_ip'])")
if [ -z "$PEER_IP" ]; then
  echo "$LOG_PREFIX: ERROR: Could not extract peer_ip from addKey response" >&2
  exit 1
fi

echo "$LOG_PREFIX: peer_ip = ${PEER_IP}"
sed -i "s|^WIREGUARD_ADDRESSES=.*|WIREGUARD_ADDRESSES=${PEER_IP}/32|" "$ENV_FILE"
echo "$LOG_PREFIX: WIREGUARD_ADDRESSES updated to ${PEER_IP}/32 in .env"
