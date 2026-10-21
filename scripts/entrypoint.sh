#!/usr/bin/env bash
set -euo pipefail
umask 077

log() {
    printf '[entrypoint] %s\n' "$*" >&2
}

fatal() {
    printf 'FATAL: %s\n' "$*" >&2
    exit 2
}

is_valid_port() {
    local val="$1"
    if [[ "$val" =~ ^[0-9]+$ ]] && [ "$val" -ge 1 ] && [ "$val" -le 65535 ]; then
        return 0
    fi
    return 1
}

is_ipv4_addr() {
    local ip="$1"
    if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 1
    fi
    local IFS='.' octets=($ip)
    for octet in "${octets[@]}"; do
        if [ "$octet" -gt 255 ]; then
            return 1
        fi
    done
    return 0
}

# Normalize domain: strip www. prefix, lowercase, validate FQDN
normalize_domain() {
    local raw="$1"
    if [ -z "$raw" ]; then
        fatal "TLS_DOMAIN is required"
    fi
    raw="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
    if is_ipv4_addr "$raw"; then
        fatal "TLS_DOMAIN must be a domain name, not an IPv4 address: $raw"
    fi
    if [[ "$raw" == www.* ]]; then
        raw="${raw#www.}"
    fi
    # Must be valid domain with at least 1 dot and no invalid chars
    if [[ ! "$raw" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
        fatal "TLS_DOMAIN must be a valid fully-qualified domain name (FQDN): $raw"
    fi
    APEX_DOMAIN="$raw"
    WWW_DOMAIN="www.${APEX_DOMAIN}"
}

# Parse users list: user:pass,user2:pass2
parse_users() {
    local raw="${TLS_USERS:-}"
    if [ -z "$raw" ]; then
        fatal "TLS_USERS is required (format: user:pass,user2:pass2)"
    fi
    if [[ "$raw" =~ [$'\r\n'] ]]; then
        fatal "TLS_USERS must not contain newline characters"
    fi

    USERS=()
    local -A seen_users=()
    local IFS=','
    local -a entries
    read -ra entries <<< "$raw"

    for entry in "${entries[@]}"; do
        if [[ "$entry" != *:* ]]; then
            fatal "TLS_USERS entry is missing colon delimiter (format: user:pass)"
        fi
        local uname="${entry%%:*}"
        local upass="${entry#*:}"
        if [ -z "$uname" ]; then
            fatal "TLS_USERS contains an empty username"
        fi
        if [ -z "$upass" ]; then
            fatal "TLS_USERS contains an empty password for user '$uname'"
        fi
        if [[ ! "$uname" =~ ^[A-Za-z0-9_@+-]+$ ]]; then
            fatal "TLS_USERS username '$uname' contains invalid characters (allowed: [A-Za-z0-9_@+-])"
        fi
        if [ -n "${seen_users[$uname]:-}" ]; then
            fatal "TLS_USERS contains duplicate username: '$uname'"
        fi
        seen_users["$uname"]=1
        USERS+=("$uname"$'\t'"$upass")
    done
}

validate_env() {
    normalize_domain "${TLS_DOMAIN:-}"
    parse_users

    CHAIN_SOCKS_HOST="${CHAIN_SOCKS_HOST:-vpndogs-router}"
    CHAIN_SOCKS_PORT="${CHAIN_SOCKS_PORT:-1070}"
    SOCKS_PORT="${SOCKS_PORT:-1065}"
    HTTPS_PORT="${HTTPS_PORT:-443}"
    HTTP_PORT="${HTTP_PORT:-80}"
    FALLBACK_PORT="${FALLBACK_PORT:-8080}"
    ACME_HTTP_PORT="${ACME_HTTP_PORT:-8081}"
    ACME_DIR="${ACME_DIR:-/var/lib/sing-box/acme}"
    LOG_LEVEL="${LOG_LEVEL:-warn}"
    TLS_EMAIL="${TLS_EMAIL:-}"

    if [ -n "$TLS_EMAIL" ]; then
        if [[ ! "$TLS_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
            fatal "TLS_EMAIL is invalid: $TLS_EMAIL"
        fi
    fi

    if [[ ! "$CHAIN_SOCKS_HOST" =~ ^[A-Za-z0-9.-]+$ ]]; then
        fatal "CHAIN_SOCKS_HOST contains invalid characters: $CHAIN_SOCKS_HOST"
    fi

    for p in CHAIN_SOCKS_PORT SOCKS_PORT HTTPS_PORT HTTP_PORT FALLBACK_PORT ACME_HTTP_PORT; do
        if ! is_valid_port "${!p}"; then
            fatal "$p must be a valid port (1-65535): ${!p}"
        fi
    done
}

cmd_render() {
    validate_env
    # Stub for Task 1; implemented in Task 2
}

cmd_client_conf() {
    validate_env
    # Stub for Task 1; implemented in Task 2
}

main() {
    validate_env
    # Stub for Task 1; implemented in Task 4
}

case "${1:-main}" in
    render)
        cmd_render
        ;;
    client-conf)
        shift
        cmd_client_conf "$@"
        ;;
    main)
        main
        ;;
    *)
        exec "$@"
        ;;
esac
