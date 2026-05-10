# PIA-Wireguard

A minimal Docker Compose setup that routes traffic through [Private Internet Access](https://www.privateinternetaccess.com/) via WireGuard, using [Gluetun](https://github.com/qdm12/gluetun) as the VPN container. Includes automatic PIA port forwarding so torrent clients (or any service sharing the VPN network) can receive inbound connections.

Other containers can join the VPN by setting `network_mode: "service:vpn"` — all their traffic will exit through the tunnel.

## Prerequisites

- Docker + Docker Compose
- `curl`, `python3`, and `wg` (wireguard-tools) on the host
- A PIA subscription on a [port-forwarding-capable server](https://www.privateinternetaccess.com/pages/network/)

## Setup

**1. Clone and configure**

```bash
git clone https://github.com/Thug-Dracula/PIA-Wireguard.git
cd PIA-Wireguard
cp .env.example .env
```

Edit `.env` with your PIA credentials and server details. Leave `WIREGUARD_ADDRESSES` blank for now — it gets filled in by the next step.

**2. Get the PIA CA certificate**

```bash
curl -so scripts/pia-ca.crt https://raw.githubusercontent.com/pia-foss/manual-connections/master/ca.rsa.4096.crt
```

**3. Generate a WireGuard keypair** (if you don't have one)

```bash
wg genkey | tee /tmp/wg.key | wg pubkey
```

Put the private key in `.env` as `WIREGUARD_PRIVATE_KEY` and the public key as `WIREGUARD_PUBLIC_KEY`.

**4. Register your key with PIA and get your assigned IP**

```bash
bash scripts/pia-keyreg.sh
```

This authenticates with PIA, registers your WireGuard public key with the server, and writes the assigned `WIREGUARD_ADDRESSES` value back into `.env`.

**5. Start the stack**

```bash
docker compose up -d
```

Gluetun will connect and the `pia-portforward` container will obtain a forwarded port and push it to qBittorrent at `QBIT_URL` (configurable in `.env`).

## Port forwarding

The `pia-portforward` service runs `scripts/pia-portforward.py` inside the VPN namespace. It:

1. Waits for a PIA auth token (written by `pia-keyreg.sh` or `pia-token-refresh.sh`)
2. Binds a forwarded port via PIA's API
3. Refreshes the port binding every 15 minutes (PIA leases expire after ~2 months but must be renewed regularly)
4. Updates qBittorrent's listening port automatically via the Web API

## Token refresh

PIA auth tokens are short-lived. Add a cron job on the host to keep it fresh:

```
0 */12 * * * /path/to/PIA-Wireguard/scripts/pia-token-refresh.sh >> /var/log/pia-token-refresh.log 2>&1
```

## Adding other services to the VPN

Any Docker service can share the VPN by using Gluetun's network namespace:

```yaml
services:
  my-service:
    image: my-image
    network_mode: "service:vpn"
    depends_on:
      - vpn
```

Expose its ports through the `vpn` service's `ports:` block, not the service itself.

---

**Disclosure:** hello I vibe coded this while watching my wife play Tomodachi Life. I have no idea if the code is secure, I have no idea if it's free of bugs. All I can tell you is that this is the process I followed to get Wireguard working with Private Internet Access despite not being officially supported. Any feedback or clean up is more than welcome.
