#!/usr/bin/env python3
import os, sys, time, json, ssl, base64, subprocess, socket
import urllib.request, urllib.parse

PIA_USER    = os.environ["PIA_USER"]
PIA_PASS    = os.environ["PIA_PASS"]
PF_HOSTNAME = os.environ["PIA_SERVER_CN"]
PF_GATEWAY  = os.environ["PIA_SERVER_VIP"]
CA_CERT     = os.environ.get("CA_CERT", "/scripts/pia-ca.crt")
QBIT_URL    = os.environ.get("QBIT_URL", "http://localhost:8585")

def pia_gateway_get(url, connect_to_ip, hostname_override):
    # Use curl for PIA gateway calls — Python's SSL rejects PIA's CA cert non-critical Basic Constraints
    parsed = urllib.parse.urlparse(url)
    qs = ("?" + parsed.query) if parsed.query else ""
    full_url = f"https://{hostname_override}:{parsed.port or 19999}{parsed.path}{qs}"
    result = subprocess.run(
        ["curl", "-s", "--connect-to", f"{hostname_override}::{connect_to_ip}:",
         "--cacert", CA_CERT, full_url],
        capture_output=True, text=True, timeout=15
    )
    if result.returncode != 0:
        raise RuntimeError(f"curl failed: {result.stderr}")
    return result.stdout

TOKEN_FILE = os.environ.get("PIA_TOKEN_FILE", "/scripts/pia-token.txt")

def get_token():
    # Token is generated on the host (outside VPN) and written to a shared file.
    # PIA blocks token generation from within the VPN tunnel.
    deadline = time.time() + 60
    while time.time() < deadline:
        try:
            with open(TOKEN_FILE) as f:
                token = f.read().strip()
            if token:
                return token
        except FileNotFoundError:
            pass
        print(f"Waiting for token file {TOKEN_FILE}...")
        time.sleep(5)
    raise RuntimeError(f"Token file not available after 60s: {TOKEN_FILE}")

def wait_for_vpn():
    print("Waiting for VPN gateway to be reachable...")
    while True:
        try:
            s = socket.create_connection((PF_GATEWAY, 19999), timeout=5)
            s.close()
            print("VPN gateway is reachable")
            return
        except Exception:
            time.sleep(5)

def check_tunnel():
    try:
        s = socket.create_connection((PF_GATEWAY, 19999), timeout=5)
        s.close()
    except Exception as e:
        raise RuntimeError(f"VPN tunnel down — cannot reach gateway {PF_GATEWAY}:19999: {e}")

def get_port_forwarding(token):
    params = urllib.parse.urlencode({"token": token})
    url = f"https://{PF_HOSTNAME}:19999/getSignature?{params}"
    raw = pia_gateway_get(url, connect_to_ip=PF_GATEWAY, hostname_override=PF_HOSTNAME)
    data = json.loads(raw)
    if data.get("status") != "OK":
        raise RuntimeError(f"getSignature failed: {raw}")
    payload   = data["payload"]
    signature = data["signature"]
    port_data = json.loads(base64.b64decode(payload + "==").decode())
    port = port_data["port"]
    return payload, signature, port

def bind_port(payload, signature):
    params = urllib.parse.urlencode({"payload": payload, "signature": signature})
    url = f"https://{PF_HOSTNAME}:19999/bindPort?{params}"
    raw = pia_gateway_get(url, connect_to_ip=PF_GATEWAY, hostname_override=PF_HOSTNAME)
    data = json.loads(raw)
    if data.get("status") != "OK":
        raise RuntimeError(f"bindPort failed: {raw}")
    return data

def set_qbit_port(port):
    req = urllib.request.Request(
        f"{QBIT_URL}/api/v2/app/setPreferences",
        data=urllib.parse.urlencode({"json": json.dumps({"listen_port": port})}).encode(),
        method="POST"
    )
    urllib.request.urlopen(req, timeout=10)
    print(f"qBittorrent listen port set to {port}")

subprocess.run(["apk", "add", "--no-cache", "curl"], check=True, capture_output=True)

wait_for_vpn()

while True:
    try:
        print("Getting PIA token...")
        token = get_token()
        print(f"Token acquired ({len(token)} chars)")

        print("Getting port forwarding signature...")
        payload, signature, port = get_port_forwarding(token)
        print(f"Forwarded port: {port}")

        set_qbit_port(port)

        # Keep-alive loop: bind every 15 minutes, refresh token/sig hourly
        refresh_at = time.time() + 3600
        while True:
            check_tunnel()
            result = bind_port(payload, signature)
            print(f"{time.strftime('%Y-%m-%d %H:%M:%S')}: bindPort OK - {result}")
            if time.time() >= refresh_at:
                break
            time.sleep(900)

    except Exception as e:
        print(f"Error: {e} — retrying in 30s")
        time.sleep(30)
