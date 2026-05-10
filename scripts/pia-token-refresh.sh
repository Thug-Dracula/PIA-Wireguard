#!/bin/bash
# Refreshes the PIA auth token. Run on the HOST (outside VPN).
# Set up as a cron job to keep the token fresh (PIA tokens expire after ~24h).
set -euo pipefail

STACK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$STACK_DIR/.env"
TOKEN_FILE="$STACK_DIR/scripts/pia-token.txt"

if [ ! -f "$ENV_FILE" ]; then
  echo "$(date): ERROR: .env not found at $ENV_FILE" >&2
  exit 1
fi

set -a; source "$ENV_FILE"; set +a

TOKEN=$(curl -sf --max-time 15 \
  -u "${PIA_USER}:${PIA_PASS}" \
  "https://www.privateinternetaccess.com/gtoken/generateToken" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['token'])")

if [ -z "$TOKEN" ]; then
  echo "$(date): ERROR: Failed to get PIA token" >&2
  exit 1
fi

echo "$TOKEN" > "$TOKEN_FILE"
echo "$(date): PIA token refreshed (${#TOKEN} chars)"
