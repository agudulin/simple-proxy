#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

HTTP_PORT=8420
SOCKS_PORT=8421

for p in "$HTTP_PORT" "$SOCKS_PORT"; do
  # Only kill processes that look like mitmdump, so we don't accidentally
  # nuke an unrelated dev server bound to the same port. lsof's -c filter
  # matches the comm name (which is "Python" for our script), so we check
  # the full argv via ps instead.
  STALE=""
  for pid in $(lsof -ti:"$p" 2>/dev/null || true); do
    if ps -p "$pid" -o command= 2>/dev/null | grep -q mitmdump; then
      STALE="$STALE $pid"
    fi
  done
  if [[ -n "$STALE" ]]; then
    echo "killing stale mitmdump on :$p →$STALE" >&2
    kill -9 $STALE 2>/dev/null || true
  fi
done
sleep 1

# Don't add --set proxyauth: macOS Ventura+ writes the keychain entry but
# never flips "Authenticated Proxy Enabled", so native apps hit the proxy
# without credentials and get 407. Loopback-only is our trust boundary.

network_services() {
  networksetup -listallnetworkservices | tail -n +2 | while IFS= read -r svc; do
    [[ -z "$svc" || "$svc" == *"asterisk"* ]] && continue
    printf '%s\n' "$svc"
  done
}

enable_system_proxy() {
  # macOS will fall back to SOCKS4 for some clients when a system-wide SOCKS
  # pointer is set, and mitmproxy only speaks v5 - so leave SOCKS off at the
  # system level. Apps that need it can target :$SOCKS_PORT explicitly.
  local failures=0
  while IFS= read -r svc; do
    networksetup -setsocksfirewallproxystate "$svc" off                    || failures=$((failures+1))
    networksetup -setwebproxy                "$svc" 127.0.0.1 "$HTTP_PORT" || failures=$((failures+1))
    networksetup -setsecurewebproxy          "$svc" 127.0.0.1 "$HTTP_PORT" || failures=$((failures+1))
  done < <(network_services)
  if (( failures > 0 )); then
    echo "WARN: $failures networksetup call(s) failed - interception may be incomplete" >&2
  else
    echo "system HTTP/HTTPS → :$HTTP_PORT (SOCKS5 listener on :$SOCKS_PORT, opt-in)" >&2
  fi
}

disable_system_proxy() {
  local failures=0
  while IFS= read -r svc; do
    networksetup -setwebproxystate           "$svc" off || failures=$((failures+1))
    networksetup -setsecurewebproxystate     "$svc" off || failures=$((failures+1))
    networksetup -setsocksfirewallproxystate "$svc" off || failures=$((failures+1))
  done < <(network_services)
  if (( failures > 0 )); then
    echo "WARN: $failures cleanup call(s) failed - verify with 'networksetup -getwebproxy <svc>'" >&2
  else
    echo "system proxy disabled" >&2
  fi
}
trap disable_system_proxy EXIT INT TERM HUP

# Defensive cleanup: a previous run that died via SIGKILL / panic / power loss
# could have left the system proxy pointed at our (now-dead) port. Clear it
# before re-enabling so we always start from a known state.
disable_system_proxy >/dev/null 2>&1 || true

enable_system_proxy

# Defense-in-depth on the CA private key directory. Idempotent.
chmod 700 ~/.mitmproxy 2>/dev/null || true

# Hosts that pin certificates and refuse the mitmproxy CA. We tunnel them
# without TLS interception - they still show up as TCP connections in the
# log, but the body is opaque. Extend via PROXY_IGNORE_HOSTS (whitespace-
# separated regexes matching host:port).
IGNORE=(
  '(.+\.)?icloud\.com:443$'
  '(.+\.)?push\.apple\.com:443$'
  'gateway\.icloud\.com:443$'
  '(.+\.)?gc\.apple\.com:443$'
  '(.+\.)?smoot\.apple\.com:443$'
  '(.+\.)?itunes\.apple\.com:443$'
  '(.+\.)?1password\.com:443$'
  '(.+\.)?1password\.ca:443$'
  '(.+\.)?1password\.eu:443$'
)
IGNORE_ARGS=()
ALL_IGNORE=("${IGNORE[@]}")
for pat in "${IGNORE[@]}"; do IGNORE_ARGS+=(--ignore-hosts "$pat"); done
if [[ -n "${PROXY_IGNORE_HOSTS:-}" ]]; then
  for pat in $PROXY_IGNORE_HOSTS; do
    IGNORE_ARGS+=(--ignore-hosts "$pat")
    ALL_IGNORE+=("$pat")
  done
fi

cat >&2 <<BANNER
─── simple-proxy ready ──────────────────────────────────────────────────
  HTTP proxy:  127.0.0.1:$HTTP_PORT
  SOCKS5:      127.0.0.1:$SOCKS_PORT  (opt-in, not in system settings)
  CA cert:     ~/.mitmproxy/mitmproxy-ca-cert.pem

  Prefix any command with sp to route it through this proxy. Add to your rc:

    sp() {
      HTTPS_PROXY=http://127.0.0.1:$HTTP_PORT \\
      HTTP_PROXY=http://127.0.0.1:$HTTP_PORT \\
      NO_PROXY=localhost,127.0.0.1 \\
      NODE_EXTRA_CA_CERTS=~/.mitmproxy/mitmproxy-ca-cert.pem \\
      "\$@"
    }

  Then: sp claude, sp node script.js, sp npm install, sp gh pr list, ...

  Tunneled (no TLS interception):
$(printf '    %s\n' "${ALL_IGNORE[@]}")
─────────────────────────────────────────────────────────────────────────
BANNER

# Non-HTTP TCP flows that come in via SOCKS get logged through the
# tcp_start hook in addon.py.
.venv/bin/mitmdump \
  --mode "regular@127.0.0.1:$HTTP_PORT" \
  --mode "socks5@127.0.0.1:$SOCKS_PORT" \
  --set connection_strategy=lazy \
  --set upstream_cert=false \
  --set flow_detail=0 \
  "${IGNORE_ARGS[@]}" \
  -s addon.py
