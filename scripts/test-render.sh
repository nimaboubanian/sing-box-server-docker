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

case_validate

if [ "$fail" -ne 0 ]; then
    echo "FAILED" >&2
    exit 1
fi
echo "ALL TESTS PASSED"
