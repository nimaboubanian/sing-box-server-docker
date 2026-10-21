# sing-box-server — vpndogs TLS (Trojan) Inbound Node

A public TLS (Trojan) inbound node for the [vpndogs](https://github.com/nimaboubanian) routing stack (`vpndogs-tls-inbound`, image `nimaboubanian/sing-box-server`).

Clients connect over **TCP+TLS on port 443** using the **Trojan** protocol under a user-defined domain. If DPI, active probes, or standard browsers visit the domain over HTTPS, the traffic cleanly falls back to an internal web server hosting a self-contained Persian "Under Maintenance" landing page.

In addition, an unauthenticated local SOCKS5 proxy is exposed on **`127.0.0.1:1065`** for local processes. All authenticated proxy traffic exits via the stack's router (`vpndogs-router:1070`).

Enable with `COMPOSE_PROFILES=tls-inbound` in the root stack's `.env`.

---

## Architecture

```
                    ┌─────────────────────────┐
                    │    Internet / Clients   │
                    └────────────┬────────────┘
                                 │
           ┌─────────────────────┴─────────────────────┐
           │                                           │
    HTTP 80/tcp                                HTTPS 443/tcp
           │                                           │
           v                                           v
 ┌───────────────────┐                      ┌─────────────────────┐
 │   nginx (:80)     │                      │ sing-box Trojan:443 │
 └─────────┬─────────┘                      └──────────┬──────────┘
           │                                           │
     ┌─────┴─────────────┐                 ┌───────────┴───────────┐
     │                   │                 │ (Trojan Auth)         │ (Fallback Probe)
     v                   v                 v                       v
 /.well-known/      301 Redirect   socks://router:1070     http://127.0.0.1:8080
 acme-challenge/    to https://            │                       │
     │                                     v                       v
     v                              [VPN egress]            ┌─────────────┐
sing-box ACME (:8081)                                       │ nginx:8080  │
                                                            │ Persian Web │
                                                            └─────────────┘
```

### Highlights
- **No TUN or Kernel Privileges Required:** Unlike L3 packet tunnels (`ipsec`, `wireguard`, `amneziawg`, `openvpn`), `sing-box` is an L4 stream proxy. The container requires **no `NET_ADMIN`**, **no `/dev/net/tun`**, and **no kernel `sysctl` modifications**.
- **Automated Let's Encrypt TLS:** Built-in ACME certificate issuance and auto-renewal for both the apex domain (`<domain>`) and `www.<domain>`.
- **Anti-Censorship & DPI Camouflage:** Browser handshakes and active probes negotiate standard TLS (`http/1.1`) and receive an authentic RTL Persian maintenance website (`www/index.html`) without leaking proxy signatures.
- **Port 80 Cooperation:** `nginx` handles public HTTP on port 80, routing ACME HTTP-01 challenges internally to `sing-box` on port 8081 and redirecting all other HTTP traffic to HTTPS (`301 Moved Permanently`).
- **Loopback SOCKS5:** Exposes `127.0.0.1:1065` locally, forwarding plain SOCKS5 traffic directly into the router.

---

## Configuration (`.env`)

Copy `.env.example` to `.env` and fill in:

| Variable | Required | Default | Description |
|---|---|---|---|
| `TLS_DOMAIN` | **Yes** | — | Domain name pointing to your server's public IP. Automatically stripped of leading `www.` and certificates issued for both `<domain>` and `www.<domain>`. |
| `TLS_USERS` | **Yes** | — | Comma-separated `username:password` pairs (e.g. `alice:secret1,bob:secret2`). Colons inside passwords are supported. |
| `TLS_EMAIL` | No | `""` | Optional email for Let's Encrypt certificate expiration alerts. |
| `CHAIN_SOCKS_HOST` | No | `vpndogs-router` | Upstream socks router service name. |
| `CHAIN_SOCKS_PORT` | No | `1070` | Upstream socks router port. |
| `HTTPS_PORT` | No | `443` | Public HTTPS / Trojan listen port. |
| `HTTP_PORT` | No | `80` | Public HTTP challenge / redirect port. |
| `SOCKS_PORT` | No | `1065` | Local SOCKS5 listen port (`127.0.0.1:1065`). |
| `LOG_LEVEL` | No | `warn` | sing-box log verbosity (`trace`, `debug`, `info`, `warn`, `error`). |

---

## Client Profiles

To generate client configs for an authorized user:

### Standard `trojan://` URI (v2rayN, v2rayNG, Streisand, Shadowrocket, Sing-Box)
```bash
docker exec vpndogs-tls-inbound entrypoint.sh client-conf <username>
```

Example output:
```
trojan://s3cret@domain.example:443?security=tls&sni=domain.example&alpn=http%2F1.1&type=tcp#alice
```

### sing-box Client JSON Config
```bash
docker exec vpndogs-tls-inbound entrypoint.sh client-conf <username> --json
```

---

## Diagnostics & Status

Run `report.sh` inside the running container to inspect daemon states, listening sockets, active connections, and TLS certificate expiration:

```bash
docker exec vpndogs-tls-inbound report.sh
```

---

## Development & Testing

Run unit validation and template rendering tests locally without Docker:

```bash
./scripts/test-render.sh --local
```

Build and test full Docker container boot and HTTPS fallback:

```bash
./build.sh
./scripts/test-render.sh
```
