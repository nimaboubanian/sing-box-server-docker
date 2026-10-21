#!/usr/bin/env bash
# test-render.sh — sing-box-server suite.
#   ./scripts/test-render.sh --local   render/validation cases only, no daemon
#   ./scripts/test-render.sh           everything, against $IMG
set -uo pipefail

IMG="${IMAGE:-nimaboubanian/sing-box-server:latest}"
MODE=docker
[ "${1:-}" = "--local" ] && MODE=local

HERE="$(cd "$(dirname "$0")" && pwd)"
ENTRY="$HERE/entrypoint.sh"
fail=0
LAST_OUT=""

PASS1='s3cret'
PASS2='hunter2'

FIX_ENV=(TLS_USERS="alice:$PASS1,bob:$PASS2" TLS_DOMAIN="domain.example")
FIX_DE=()
for kv in "${FIX_ENV[@]}"; do FIX_DE+=(-e "$kv"); done

run_env() {
    local host_env=("${FIX_ENV[@]}") docker_env=("${FIX_DE[@]}") kv args=()
    for kv in "$@"; do
        if [[ "$kv" == *=* ]]; then
            host_env+=("$kv")
            docker_env+=(-e "$kv")
        else
            args+=("$kv")
        fi
    done
    if [ "$MODE" = local ]; then
        env "${host_env[@]}" bash "$ENTRY" "${args[@]}" 2>&1
    else
        docker run --rm --network none "${docker_env[@]}" \
            --entrypoint /usr/local/bin/entrypoint.sh "$IMG" "${args[@]}" 2>&1
    fi
}

block() { printf '%s\n' "$2" | awk -v b="# === $1 ===" '$0==b{f=1;next} /^# === /{f=0} f'; }

assert_jq() {
    local name="$1" filter="$2" json="$3" res
    if res="$(printf '%s' "$json" | jq -e "$filter" 2>&1)"; then
        echo "$name: PASS"
    else
        echo "$name: FAIL"
        printf '%s\n' "$res" >&2
        fail=1
    fi
}

eq() { local name="$1" got="$2" want="$3"; [ "$got" = "$want" ] && echo "$name: PASS" || { echo "$name: FAIL"; printf 'want:\n%s\n\ngot:\n%s\n' "$want" "$got" >&2; fail=1; }; }
ok() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then echo "$name: PASS"; else echo "$name: FAIL"; fail=1; fi; }
has() { local name="$1" text="$2" pat="$3"; printf '%s\n' "$text" | grep -qF -- "$pat" && echo "$name: PASS" || { echo "$name: FAIL"; printf 'expected %q in:\n%s\n' "$pat" "$text" >&2; fail=1; }; }
lacks() { local name="$1" text="$2" pat="$3"; printf '%s\n' "$text" | grep -qF -- "$pat" && { echo "$name: FAIL"; printf 'found %q in:\n%s\n' "$pat" "$text" >&2; fail=1; } || echo "$name: PASS"; }

run_is() {
    local name="$1" want="$2" rc=0 _tmp
    shift 2
    _tmp="$(mktemp)"
    set +e; "$@" > "$_tmp" 2>&1; rc=$?
    LAST_OUT="$(cat "$_tmp")"; rm -f "$_tmp"
    if [ "$rc" = "$want" ]; then
        echo "$name: PASS (exit $rc)"
    else
        echo "$name: FAIL (exit $rc, want $want)"
        printf '%s\n' "$LAST_OUT" >&2
        fail=1
    fi
}

case_validate() {
    echo "=== VALIDATION CASES ==="
    run_is "missing TLS_DOMAIN"        2 run_env "TLS_DOMAIN="
    has    "names TLS_DOMAIN"          "$LAST_OUT" "TLS_DOMAIN"
    run_is "IP literal TLS_DOMAIN"     2 run_env "TLS_DOMAIN=1.2.3.4"
    run_is "single-label TLS_DOMAIN"   2 run_env "TLS_DOMAIN=localhost"
    run_is "bad domain chars"          2 run_env "TLS_DOMAIN=bad_domain.example"
    run_is "missing TLS_USERS"         2 run_env "TLS_USERS="
    has    "names TLS_USERS"           "$LAST_OUT" "TLS_USERS"
    run_is "entry without colon"       2 run_env "TLS_USERS=alice"
    run_is "empty username"            2 run_env "TLS_USERS=:secret"
    run_is "empty password"            2 run_env "TLS_USERS=alice:"
    run_is "bad username charset"      2 run_env "TLS_USERS=al ice:secret"
    run_is "duplicate username"        2 run_env "TLS_USERS=alice:x,alice:y"
    has    "duplicate names alice"     "$LAST_OUT" "alice"
    run_is "newline in password"       2 run_env "$(printf 'TLS_USERS=alice:secretpass\nvalue')"
    lacks  "newline error hides pass"  "$LAST_OUT" "secretpass"
    run_is "invalid TLS_EMAIL"         2 run_env "TLS_EMAIL=not-an-email"
    run_is "bad CHAIN_SOCKS_PORT=0"    2 run_env "CHAIN_SOCKS_PORT=0"
    run_is "bad HTTPS_PORT=70000"      2 run_env "HTTPS_PORT=70000"
    run_is "bad SOCKS_PORT=abc"        2 run_env "SOCKS_PORT=abc"
    run_is "bad CHAIN_SOCKS_HOST"      2 run_env "CHAIN_SOCKS_HOST=bad host"
    run_is "valid colon password"      0 run_env "TLS_USERS=alice:a:b:c" render
    run_is "valid www. domain"         0 run_env "TLS_DOMAIN=WWW.Example.COM" render
}

case_render() {
    echo "=== RENDER CASES ==="
    local out ng sb tmpcert
    out="$(run_env render)" || { echo "render: FAIL"; fail=1; return; }
    ng="$(block "nginx.conf" "$out")"
    sb="$(block "sing-box/config.json" "$out")"

    has "nginx listens on 0.0.0.0:80"     "$ng" "listen 0.0.0.0:80 default_server;"
    has "nginx listens on 127.0.0.1:8080" "$ng" "listen 127.0.0.1:8080 default_server;"
    has "nginx server_name apex+www"      "$ng" "server_name domain.example www.domain.example _;"
    has "nginx proxies acme challenge"    "$ng" "proxy_pass http://127.0.0.1:8081;"
    has "nginx redirects to https"        "$ng" 'return 301 https://$host$request_uri;'

    assert_jq "acme provider type"   '.certificate_providers[0].type == "acme"' "$sb"
    assert_jq "acme domains"         '.certificate_providers[0].domain == ["domain.example", "www.domain.example"]' "$sb"
    assert_jq "acme alt http port"   '.certificate_providers[0].alternative_http_port == 8081' "$sb"
    assert_jq "acme email omitted"   '(.certificate_providers[0] | has("email")) == false' "$sb"
    assert_jq "trojan listen_port"   '(.inbounds[] | select(.tag=="trojan-in") | .listen_port) == 443' "$sb"
    assert_jq "trojan alpn http/1.1" '(.inbounds[] | select(.tag=="trojan-in") | .tls.alpn) == ["http/1.1"]' "$sb"
    assert_jq "trojan cert provider" '(.inbounds[] | select(.tag=="trojan-in") | .tls.certificate_provider) == "letsencrypt"' "$sb"
    assert_jq "trojan fallback port" '(.inbounds[] | select(.tag=="trojan-in") | .fallback.server_port) == 8080' "$sb"
    assert_jq "trojan users count"   '(.inbounds[] | select(.tag=="trojan-in") | .users | length) == 2' "$sb"
    assert_jq "socks inbound 1065"   '(.inbounds[] | select(.tag=="socks-in") | .listen_port) == 1065' "$sb"
    assert_jq "chain-out server"     '(.outbounds[] | select(.tag=="chain-out") | .server) == "vpndogs-router"' "$sb"
    assert_jq "chain-out port"       '(.outbounds[] | select(.tag=="chain-out") | .server_port) == 1070' "$sb"

    # www. normalization + TLS_EMAIL
    out="$(run_env "TLS_DOMAIN=www.Sub.Example.com" "TLS_EMAIL=ops@example.com" render)"
    sb="$(block "sing-box/config.json" "$out")"
    assert_jq "www stripped to apex" '.certificate_providers[0].domain == ["sub.example.com", "www.sub.example.com"]' "$sb"
    assert_jq "acme email set"       '.certificate_providers[0].email == "ops@example.com"' "$sb"

    # Static cert mode when cert.pem + key.pem exist in ACME_DIR
    tmpcert="$(mktemp -d)"
    touch "$tmpcert/cert.pem" "$tmpcert/key.pem"
    out="$( env ACME_DIR="$tmpcert" "${FIX_ENV[@]}" bash "$ENTRY" render )"
    sb="$(block "sing-box/config.json" "$out")"
    assert_jq "static cert omits providers" 'has("certificate_providers") == false' "$sb"
    assert_jq "static cert sets certificate_path" '(.inbounds[] | select(.tag=="trojan-in") | .tls.certificate_path) == "'"$tmpcert"'/cert.pem"' "$sb"
    rm -rf "$tmpcert"
}

case_client() {
    echo "=== CLIENT-CONF CASES ==="
    local uri json
    uri="$(run_env client-conf alice)" || { echo "client-conf alice: FAIL"; fail=1; return; }
    eq "alice trojan URI" "$uri" "trojan://s3cret@domain.example:443?security=tls&sni=domain.example&alpn=http%2F1.1&type=tcp#alice"

    # Review Focus 1: password with colons and URL-special chars
    uri="$(run_env "TLS_USERS=bob:p@ss:w/rd?1#2" client-conf bob)"
    eq "bob special chars encoded" "$uri" "trojan://p%40ss%3Aw%2Frd%3F1%232@domain.example:443?security=tls&sni=domain.example&alpn=http%2F1.1&type=tcp#bob"

    json="$(run_env client-conf alice --json)" || { echo "client-conf --json: FAIL"; fail=1; return; }
    assert_jq "client json outbound trojan" '(.outbounds[] | select(.tag=="proxy") | .type) == "trojan"' "$json"
    assert_jq "client json server"          '(.outbounds[] | select(.tag=="proxy") | .server) == "domain.example"' "$json"
    assert_jq "client json password"        '(.outbounds[] | select(.tag=="proxy") | .password) == "s3cret"' "$json"
    assert_jq "client json tls sni"         '(.outbounds[] | select(.tag=="proxy") | .tls.server_name) == "domain.example"' "$json"

    run_is "unknown user exits 2" 2 run_env client-conf nobody
    has    "unknown user named"   "$LAST_OUT" "nobody"
}

case_www() {
    echo "=== STATIC WEBSITE CASES ==="
    local www_dir="$HERE/../www"
    ok    "index.html exists"       test -s "$www_dir/index.html"
    ok    "404.html exists"         test -s "$www_dir/404.html"
    has   "index.html is fa"        "$(cat "$www_dir/index.html" 2>/dev/null || true)" 'lang="fa"'
    has   "index.html is rtl"       "$(cat "$www_dir/index.html" 2>/dev/null || true)" 'dir="rtl"'
    lacks "index.html no http://"   "$(cat "$www_dir/index.html" 2>/dev/null || true)" 'http://'
    lacks "index.html no https://"  "$(cat "$www_dir/index.html" 2>/dev/null || true)" 'https://'
    has   "404.html is rtl"         "$(cat "$www_dir/404.html" 2>/dev/null || true)" 'dir="rtl"'
    lacks "404.html no https://"    "$(cat "$www_dir/404.html" 2>/dev/null || true)" 'https://'
}

case_validate
case_render
case_client
case_www

if [ "$fail" -ne 0 ]; then
    echo "FAILED" >&2
    exit 1
fi
echo "ALL TESTS PASSED"
