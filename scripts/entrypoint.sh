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

render_nginx_conf() {
    cat <<EOF
worker_processes auto;
error_log stderr warn;
pid /run/nginx/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type text/html;
    access_log off;
    server_tokens off;
    sendfile on;
    keepalive_timeout 65;
    charset utf-8;

    # Public HTTP: ACME HTTP-01 challenge proxy + HTTPS redirect
    server {
        listen 0.0.0.0:${HTTP_PORT} default_server;
        server_name ${APEX_DOMAIN} ${WWW_DOMAIN} _;

        location ^~ /.well-known/acme-challenge/ {
            proxy_pass http://127.0.0.1:${ACME_HTTP_PORT};
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
        }

        location / {
            return 301 https://\$host\$request_uri;
        }
    }

    # Internal Loopback: Persian fake static website fallback
    server {
        listen 127.0.0.1:${FALLBACK_PORT} default_server;
        server_name ${APEX_DOMAIN} ${WWW_DOMAIN} _;

        root /var/www/html;
        index index.html;

        location / {
            try_files \$uri \$uri/ =404;
        }

        error_page 404 /404.html;
        location = /404.html {
            internal;
        }
    }
}
EOF
}

render_singbox_conf() {
    local has_static_cert=0
    if [ -f "$ACME_DIR/cert.pem" ] && [ -f "$ACME_DIR/key.pem" ]; then
        has_static_cert=1
    fi

    local users_json
    users_json="$(
        for u in "${USERS[@]}"; do
            printf '%s\n' "$u"
        done | jq -R -s '
            split("\n") | map(select(length > 0) | split("\t")) |
            map({name: .[0], password: .[1]})
        '
    )"

    jq -n \
        --arg log_level "$LOG_LEVEL" \
        --argjson https_port "$HTTPS_PORT" \
        --argjson fallback_port "$FALLBACK_PORT" \
        --argjson socks_port "$SOCKS_PORT" \
        --arg apex_domain "$APEX_DOMAIN" \
        --arg www_domain "$WWW_DOMAIN" \
        --arg chain_host "$CHAIN_SOCKS_HOST" \
        --argjson chain_port "$CHAIN_SOCKS_PORT" \
        --arg acme_dir "$ACME_DIR" \
        --argjson acme_alt_port "$ACME_HTTP_PORT" \
        --arg email "$TLS_EMAIL" \
        --argjson has_static "$has_static_cert" \
        --argjson users "$users_json" '
    {
      "log": {
        "level": $log_level,
        "timestamp": true
      },
      "dns": {},
      "inbounds": [
        {
          "type": "trojan",
          "tag": "trojan-in",
          "listen": "0.0.0.0",
          "listen_port": $https_port,
          "tcp_fast_open": false,
          "users": $users,
          "tls": (
            {
              "enabled": true,
              "server_name": $apex_domain,
              "alpn": ["http/1.1"]
            } + (
              if $has_static == 1 then
                {
                  "certificate_path": ($acme_dir + "/cert.pem"),
                  "key_path": ($acme_dir + "/key.pem")
                }
              else
                {
                  "certificate_provider": "letsencrypt"
                }
              end
            )
          ),
          "fallback": {
            "server": "127.0.0.1",
            "server_port": $fallback_port
          },
          "fallback_for_alpn": {
            "http/1.1": {
              "server": "127.0.0.1",
              "server_port": $fallback_port
            }
          }
        },
        {
          "type": "socks",
          "tag": "socks-in",
          "listen": "0.0.0.0",
          "listen_port": $socks_port
        }
      ],
      "outbounds": [
        {
          "type": "socks",
          "tag": "chain-out",
          "server": $chain_host,
          "server_port": $chain_port,
          "version": "5"
        },
        {
          "type": "direct",
          "tag": "direct"
        }
      ],
      "route": {
        "auto_detect_interface": false,
        "final": "chain-out",
        "rules": [
          {
            "ip_cidr": ["127.0.0.1/32"],
            "port": [$fallback_port],
            "outbound": "direct"
          }
        ]
      }
    } + (
      if $has_static == 1 then
        {}
      else
        {
          "certificate_providers": [
            (
              {
                "type": "acme",
                "tag": "letsencrypt",
                "domain": [$apex_domain, $www_domain],
                "data_directory": $acme_dir,
                "alternative_http_port": $acme_alt_port
              } + (
                if ($email | length) > 0 then
                  {"email": $email}
                else
                  {}
                end
              )
            )
          ]
        }
      end
    )'
}

urlencode() {
    printf '%s' "$1" | jq -sRr @uri
}

cmd_render() {
    validate_env
    echo "# === nginx.conf ==="
    render_nginx_conf
    echo "# === sing-box/config.json ==="
    render_singbox_conf
}

cmd_client_conf() {
    validate_env
    local target_user="${1:-}"
    if [ -z "$target_user" ]; then
        fatal "client-conf requires a username: entrypoint.sh client-conf <user> [--json]"
    fi

    local found_pass=""
    for u in "${USERS[@]}"; do
        local un="${u%%$'\t'*}"
        local up="${u#*$'\t'}"
        if [ "$un" = "$target_user" ]; then
            found_pass="$up"
            break
        fi
    done

    if [ -z "$found_pass" ]; then
        fatal "user '$target_user' not found in TLS_USERS"
    fi

    local format="${2:-}"
    if [ "$format" = "--json" ]; then
        jq -n \
            --arg apex_domain "$APEX_DOMAIN" \
            --argjson https_port "$HTTPS_PORT" \
            --arg password "$found_pass" '
        {
          "log": {
            "level": "warn",
            "timestamp": true
          },
          "inbounds": [
            {
              "type": "socks",
              "tag": "socks-in",
              "listen": "127.0.0.1",
              "listen_port": 1080
            },
            {
              "type": "mixed",
              "tag": "mixed-in",
              "listen": "127.0.0.1",
              "listen_port": 1081
            }
          ],
          "outbounds": [
            {
              "type": "trojan",
              "tag": "proxy",
              "server": $apex_domain,
              "server_port": $https_port,
              "password": $password,
              "tls": {
                "enabled": true,
                "server_name": $apex_domain,
                "alpn": ["http/1.1"]
              }
            },
            {
              "type": "direct",
              "tag": "direct"
            }
          ],
          "route": {
            "auto_detect_interface": true,
            "final": "proxy",
            "rules": []
          }
        }'
    else
        local enc_pass
        local enc_tag
        enc_pass="$(urlencode "$found_pass")"
        enc_tag="$(urlencode "$target_user")"
        printf 'trojan://%s@%s:%s?security=tls&sni=%s&alpn=http%%2F1.1&type=tcp#%s\n' \
            "$enc_pass" "$APEX_DOMAIN" "$HTTPS_PORT" "$APEX_DOMAIN" "$enc_tag"
    fi
}

ensure_test_cert() {
    if [ "${BOOT_STAGE:-}" = "up-only" ] && [ ! -f "$ACME_DIR/cert.pem" ]; then
        log "BOOT_STAGE=up-only: generating self-signed certificate for $APEX_DOMAIN and $WWW_DOMAIN"
        mkdir -p "$ACME_DIR"
        chmod 700 "$ACME_DIR"
        openssl req -x509 -newkey rsa:2048 -nodes -days 1 -sha256 \
            -keyout "$ACME_DIR/key.pem" \
            -out "$ACME_DIR/cert.pem" \
            -subj "/CN=$APEX_DOMAIN" \
            -addext "subjectAltName=DNS:$APEX_DOMAIN,DNS:$WWW_DOMAIN" >/dev/null 2>&1
        chmod 600 "$ACME_DIR/key.pem" "$ACME_DIR/cert.pem"
    fi
}

render_configs() {
    mkdir -p /etc/nginx /run/nginx /etc/sing-box "$ACME_DIR"
    render_nginx_conf > /etc/nginx/nginx.conf
    chmod 644 /etc/nginx/nginx.conf
    render_singbox_conf > /etc/sing-box/config.json
    chmod 600 /etc/sing-box/config.json
    if command -v sing-box >/dev/null 2>&1; then
        sing-box check -c /etc/sing-box/config.json || fatal "sing-box config validation failed"
    fi
    if command -v nginx >/dev/null 2>&1; then
        nginx -t -c /etc/nginx/nginx.conf >/dev/null 2>&1 || fatal "nginx config validation failed"
    fi
}

declare -A CHILD_PIDS=()

child_dead() {
    local pid="${CHILD_PIDS[$1]:-}"
    [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null
}

wait_for_port() {
    local host="$1" port="$2" max_secs="$3" i
    for i in $(seq 1 "$((max_secs * 2))"); do
        if (exec 3<>/dev/tcp/"$host"/"$port") 2>/dev/null; then
            exec 3<&- 3>&-
            return 0
        fi
        sleep 0.5
    done
    return 1
}

start_nginx() {
    log "starting nginx"
    nginx -g "daemon off;" &
    CHILD_PIDS[nginx]=$!
    wait_for_port 127.0.0.1 "$HTTP_PORT" 10 || { log "FATAL: nginx never bound port $HTTP_PORT"; exit 1; }
    wait_for_port 127.0.0.1 "$FALLBACK_PORT" 5 || { log "FATAL: nginx never bound fallback port $FALLBACK_PORT"; exit 1; }
    log "nginx up (ports $HTTP_PORT, $FALLBACK_PORT ready)"
}

start_singbox() {
    log "starting sing-box"
    sing-box run -c /etc/sing-box/config.json &
    CHILD_PIDS[sing-box]=$!
    wait_for_port 127.0.0.1 "$SOCKS_PORT" 15 || { log "FATAL: sing-box never bound socks port $SOCKS_PORT"; exit 1; }
    if [ -f "$ACME_DIR/cert.pem" ]; then
        wait_for_port 127.0.0.1 "$HTTPS_PORT" 10 || { log "FATAL: sing-box never bound https port $HTTPS_PORT"; exit 1; }
    fi
    log "sing-box up (socks port $SOCKS_PORT ready)"
}

restart_child() {
    case "$1" in
        nginx)    start_nginx ;;
        sing-box) start_singbox ;;
    esac
}

supervise() {
    local deaths=0 name
    trap 'shutdown' TERM INT
    while true; do
        wait -n 2>/dev/null || true
        for name in "${!CHILD_PIDS[@]}"; do
            child_dead "$name" || continue
            deaths=$((deaths + 1))
            log "child '$name' died (deaths since boot: $deaths) — restarting"
            restart_child "$name" || exit 1
            if [ "$deaths" -ge 3 ]; then
                log "FATAL: $deaths child deaths since boot — giving up"
                exit 1
            fi
        done
    done
}

shutdown() {
    log "shutting down"
    local pid
    for pid in "${CHILD_PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    exit 0
}

main() {
    validate_env
    ensure_test_cert
    render_configs
    start_nginx
    start_singbox
    supervise
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
