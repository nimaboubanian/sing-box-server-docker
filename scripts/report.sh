#!/usr/bin/env bash
set -euo pipefail

ACME_DIR="${ACME_DIR:-/var/lib/sing-box/acme}"
TLS_DOMAIN="${TLS_DOMAIN:-}"
TLS_USERS="${TLS_USERS:-}"

echo "== Processes =="
if pidof sing-box >/dev/null 2>&1 || pgrep -f sing-box >/dev/null 2>&1; then
    echo "sing-box: UP"
else
    echo "sing-box: DOWN"
fi

if pidof nginx >/dev/null 2>&1 || pgrep -f nginx >/dev/null 2>&1; then
    echo "nginx: UP"
else
    echo "nginx: DOWN"
fi

echo ""
echo "== Sockets & Active Connections =="
if command -v ss >/dev/null 2>&1; then
    ss -tln 2>/dev/null || true
    echo "-- Active Connections (:443, :1065) --"
    ss -tn 'sport = :443 or sport = :1065' 2>/dev/null || true
fi

echo ""
echo "== TLS Certificates =="
if [ -d "$ACME_DIR" ]; then
    found=0
    while IFS= read -r -d '' cert_file; do
        # Skip private keys
        case "$(basename "$cert_file")" in
            *key*|*Key*) continue ;;
        esac
        # Verify it actually looks like an X.509 certificate
        if grep -q -- "BEGIN CERTIFICATE" "$cert_file" 2>/dev/null; then
            found=1
            echo "Certificate: $cert_file"
            openssl x509 -in "$cert_file" -noout -subject -issuer -dates -ext subjectAltName 2>/dev/null || true
            echo ""
        fi
    done < <(find "$ACME_DIR" -type f \( -name "*.crt" -o -name "*.pem" \) -print0 2>/dev/null)
    if [ "$found" -eq 0 ]; then
        echo "No certificates found in $ACME_DIR"
    fi
else
    echo "ACME directory $ACME_DIR does not exist"
fi

echo ""
echo "== Client Profiles =="
if [ -n "$TLS_USERS" ]; then
    IFS=',' read -ra user_entries <<< "$TLS_USERS"
    for entry in "${user_entries[@]}"; do
        [ -n "$entry" ] || continue
        uname="${entry%%:*}"
        [ -n "$uname" ] || continue
        echo "- User '$uname':"
        echo "  URI:  docker exec vpndogs-tls-inbound entrypoint.sh client-conf $uname"
        echo "  JSON: docker exec vpndogs-tls-inbound entrypoint.sh client-conf $uname --json"
    done
else
    echo "No TLS_USERS configured"
fi

echo ""
echo "== Environment (redacted) =="
echo "TLS_DOMAIN=${TLS_DOMAIN:-<unset>}"
if [ -n "$TLS_USERS" ]; then
    redacted_users=()
    IFS=',' read -ra user_entries <<< "$TLS_USERS"
    for entry in "${user_entries[@]}"; do
        uname="${entry%%:*}"
        [ -n "$uname" ] && redacted_users+=("$uname:***")
    done
    ( IFS=,; echo "TLS_USERS=${redacted_users[*]}" )
else
    echo "TLS_USERS=<unset>"
fi
echo "CHAIN_SOCKS_HOST=${CHAIN_SOCKS_HOST:-vpndogs-router}"
echo "CHAIN_SOCKS_PORT=${CHAIN_SOCKS_PORT:-1070}"
echo "SOCKS_PORT=${SOCKS_PORT:-1065}"
echo "HTTPS_PORT=${HTTPS_PORT:-443}"
echo "HTTP_PORT=${HTTP_PORT:-80}"
echo "FALLBACK_PORT=${FALLBACK_PORT:-8080}"
echo "ACME_HTTP_PORT=${ACME_HTTP_PORT:-8081}"
echo "ACME_DIR=$ACME_DIR"
