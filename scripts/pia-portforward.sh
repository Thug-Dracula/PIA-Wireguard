#!/bin/sh
set -e

CA_CERT="${CA_CERT:-/scripts/pia-ca.crt}"
QBIT_URL="${QBIT_URL:-http://localhost:8585}"
PF_HOSTNAME="${PIA_SERVER_CN}"
PF_GATEWAY="${PIA_SERVER_VIP}"

# Install curl + CA certs if missing (alpine base image)
which curl > /dev/null 2>&1 || apk add --no-cache curl ca-certificates

# Wait for VPN tunnel gateway to be reachable
echo "Waiting for VPN tunnel..."
until curl -sk --connect-timeout 3 "https://${PF_HOSTNAME}:1337" > /dev/null 2>&1 || \
      ping -c1 -W3 "${PF_GATEWAY}" > /dev/null 2>&1; do
  sleep 5
done
echo "VPN is up, starting port forwarding"

# Get a fresh PIA auth token (wget is available in Alpine base, curl may have SSL issues)
get_token() {
  wget -qO- --auth-no-challenge \
    --user="${PIA_USER}" --password="${PIA_PASS}" \
    "https://www.privateinternetaccess.com/gtoken/generateToken" \
    | grep -o '"token":"[^"]*"' | cut -d'"' -f4
}

echo "Getting PIA token..."
TOKEN=$(get_token)
if [ -z "$TOKEN" ]; then
  echo "wget failed, trying curl..."
  TOKEN=$(curl -s --user "${PIA_USER}:${PIA_PASS}" \
    "https://www.privateinternetaccess.com/gtoken/generateToken" \
    | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
fi
if [ -z "$TOKEN" ]; then echo "Failed to get PIA token"; exit 1; fi
echo "PIA token acquired (${#TOKEN} chars)"

# Get port forwarding payload + signature from PIA
PF_DATA=$(curl -sf -m 10 \
  --connect-to "${PF_HOSTNAME}::${PF_GATEWAY}:" \
  --cacert "$CA_CERT" \
  -G --data-urlencode "token=${TOKEN}" \
  "https://${PF_HOSTNAME}:19999/getSignature")

echo "Signature response: $PF_DATA"

STATUS=$(echo "$PF_DATA" | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
if [ "$STATUS" != "OK" ]; then echo "Failed to get signature: $PF_DATA"; exit 1; fi

PAYLOAD=$(echo "$PF_DATA" | grep -o '"payload":"[^"]*"' | cut -d'"' -f4)
SIGNATURE=$(echo "$PF_DATA" | grep -o '"signature":"[^"]*"' | cut -d'"' -f4)

# Decode port from payload
PORT=$(echo "$PAYLOAD" | base64 -d 2>/dev/null | grep -o '"port":[0-9]*' | cut -d: -f2)
echo "Forwarded port: $PORT"

# Push port to qBittorrent
curl -sf -X POST "$QBIT_URL/api/v2/app/setPreferences" \
  --data-urlencode "json={\"listen_port\":${PORT}}" > /dev/null && \
  echo "qBittorrent listen port set to $PORT"

# Bind and keep alive every 15 minutes
while true; do
  BIND=$(curl -sf -m 10 \
    --connect-to "${PF_HOSTNAME}::${PF_GATEWAY}:" \
    --cacert "$CA_CERT" \
    -G --data-urlencode "payload=${PAYLOAD}" \
       --data-urlencode "signature=${SIGNATURE}" \
    "https://${PF_HOSTNAME}:19999/bindPort")

  echo "$(date): bindPort: $BIND"

  STATUS=$(echo "$BIND" | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
  if [ "$STATUS" != "OK" ]; then
    echo "Bind failed, refreshing token and signature..."
    TOKEN=$(get_token)
    PF_DATA=$(curl -sf -m 10 \
      --connect-to "${PF_HOSTNAME}::${PF_GATEWAY}:" \
      --cacert "$CA_CERT" \
      -G --data-urlencode "token=${TOKEN}" \
      "https://${PF_HOSTNAME}:19999/getSignature")
    PAYLOAD=$(echo "$PF_DATA" | grep -o '"payload":"[^"]*"' | cut -d'"' -f4)
    SIGNATURE=$(echo "$PF_DATA" | grep -o '"signature":"[^"]*"' | cut -d'"' -f4)
    PORT=$(echo "$PAYLOAD" | base64 -d 2>/dev/null | grep -o '"port":[0-9]*' | cut -d: -f2)
    curl -sf -X POST "$QBIT_URL/api/v2/app/setPreferences" \
      --data-urlencode "json={\"listen_port\":${PORT}}" > /dev/null
    echo "Port refreshed to $PORT"
  fi

  sleep 900
done
