#!/usr/bin/env bash
set -euo pipefail

DATA_DIR="${DATA_DIR:-/data}"
WG_IF="wg0"
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

CONFIG_DIR="$DATA_DIR/config"
DOWNLOADS_DIR="$DATA_DIR/downloads"
INCOMPLETE_DIR="$DATA_DIR/incomplete"
WATCH_DIR="$DATA_DIR/watch"
TRANSMISSION_HOME="$DATA_DIR/transmission"

# Opt-in periodic VPN probe. When >0, a background watcher curls Mullvad every
# N seconds; three consecutive failures terminate the container so the Docker
# restart policy re-establishes the tunnel from scratch.
VPN_HEALTHCHECK_INTERVAL="${VPN_HEALTHCHECK_INTERVAL:-0}"

WG_CONF_CLEAN=/tmp/wg0.conf
TRANSMISSION_PID=""
HEALTH_PID=""

die() { echo "ERROR: $*" >&2; exit 1; }

cleanup() {
    trap - TERM INT
    echo "Shutting down..."
    if [[ -n "$HEALTH_PID" ]] && kill -0 "$HEALTH_PID" 2>/dev/null; then
        kill "$HEALTH_PID" 2>/dev/null || true
        wait "$HEALTH_PID" 2>/dev/null || true
    fi
    if [[ -n "$TRANSMISSION_PID" ]] && kill -0 "$TRANSMISSION_PID" 2>/dev/null; then
        kill -TERM "$TRANSMISSION_PID" 2>/dev/null || true
        wait "$TRANSMISSION_PID" 2>/dev/null || true
    fi
    if [[ -f "$WG_CONF_CLEAN" ]] && ip link show "$WG_IF" &>/dev/null; then
        wg-quick down "$WG_CONF_CLEAN" 2>/dev/null || true
    fi
    exit "${1:-0}"
}

trap 'cleanup 0' TERM INT

# ── Verify iptables works ─────────────────────────────────────────────────
# Build forces the legacy backend so this should work on any kernel.

iptables -L &>/dev/null || die "iptables is not functional in this environment. \
Check that the container has NET_ADMIN capability (privileged mode)."

# ── Ensure /dev/net/tun exists ────────────────────────────────────────────

if [[ ! -c /dev/net/tun ]]; then
    echo "TUN device not found — creating /dev/net/tun..."
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200 || die "/dev/net/tun could not be created. Enable privileged mode."
    chmod 600 /dev/net/tun
fi

# ── Locate WireGuard config ───────────────────────────────────────────────

[[ -d "$CONFIG_DIR" ]] || die "Config directory not found: $CONFIG_DIR"
WG_CONF=$(find "$CONFIG_DIR" -maxdepth 1 -name '*.conf' | head -1)
[[ -n "$WG_CONF" ]] || die "No .conf file found in $CONFIG_DIR"

# Pull endpoint host:port (used for kill-switch exception + manual route)
ENDPOINT_LINE=$(grep -E '^\s*Endpoint\s*=' "$WG_CONF" | head -1 | sed 's/.*=\s*//' | tr -d ' ')
ENDPOINT_HOST="${ENDPOINT_LINE%:*}"
ENDPOINT_PORT="${ENDPOINT_LINE##*:}"
[[ -n "$ENDPOINT_HOST" && -n "$ENDPOINT_PORT" ]] || die "Could not parse Endpoint from $WG_CONF"

# Resolve to IPv4 if it's a hostname
if [[ "$ENDPOINT_HOST" =~ ^[0-9.]+$ ]]; then
    ENDPOINT_IP="$ENDPOINT_HOST"
else
    ENDPOINT_IP=$(getent ahostsv4 "$ENDPOINT_HOST" | awk '/STREAM|RAW|DGRAM/ {print $1; exit}')
    [[ -z "$ENDPOINT_IP" ]] && ENDPOINT_IP=$(getent ahostsv4 "$ENDPOINT_HOST" | awk '{print $1; exit}')
    [[ -n "$ENDPOINT_IP" ]] || die "Could not resolve endpoint $ENDPOINT_HOST"
fi

# Capture original default gateway BEFORE we touch routing
ORIG_GW=$(ip -4 route show default | awk '/default/ {print $3; exit}')
ORIG_DEV=$(ip -4 route show default | awk '/default/ {print $5; exit}')
[[ -n "$ORIG_GW" && -n "$ORIG_DEV" ]] || die "Could not determine default gateway / device"

echo "Endpoint: $ENDPOINT_IP:$ENDPOINT_PORT  (via host gateway $ORIG_GW dev $ORIG_DEV)"

# ── Ensure data subdirs exist ─────────────────────────────────────────────

mkdir -p "$DOWNLOADS_DIR" "$INCOMPLETE_DIR" "$WATCH_DIR" "$TRANSMISSION_HOME"

# ── Preprocess WG config: strip IPv6 + force Table=off ────────────────────
# Table=off tells wg-quick not to set up routing or call iptables-restore.
# This avoids needing the addrtype/comment iptables extensions which aren't
# available in all NAS kernels.

chmod 600 "$WG_CONF"

awk '
BEGIN { in_interface = 0; table_done = 0 }

/^\[Interface\][[:space:]]*$/ {
    in_interface = 1
    table_done = 0
    print
    next
}

/^\[/ {
    if (in_interface && !table_done) { print "Table = off"; table_done = 1 }
    in_interface = 0
    print
    next
}

/^[[:space:]]*Table[[:space:]]*=/ {
    if (in_interface) { print "Table = off"; table_done = 1; next }
}

/^[[:space:]]*(Address|AllowedIPs|DNS)[[:space:]]*=/ {
    n = index($0, "=")
    key = substr($0, 1, n - 1)
    gsub(/[[:space:]]/, "", key)
    val = substr($0, n + 1)
    nv = split(val, parts, ",")
    out = ""
    for (i = 1; i <= nv; i++) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", parts[i])
        if (parts[i] != "" && parts[i] !~ /:/) {
            out = (out == "") ? parts[i] : out ", " parts[i]
        }
    }
    if (out != "") print key " = " out
    next
}

{ print }

END {
    if (in_interface && !table_done) print "Table = off"
}
' "$WG_CONF" > "$WG_CONF_CLEAN"

chmod 600 "$WG_CONF_CLEAN"

echo "── Sanitized config (keys redacted) ──"
grep -v -E '(PrivateKey|PublicKey|PresharedKey)\s*=' "$WG_CONF_CLEAN" || true
echo "──────────────────────────────────────"

# ── Bring up WireGuard ────────────────────────────────────────────────────
# With Table=off, wg-quick brings up the interface and assigns the address
# but does NOT touch routing or iptables. We handle that ourselves.

echo "Starting WireGuard tunnel..."
wg-quick up "$WG_CONF_CLEAN" || die "wg-quick failed"

# ── Manual routing ────────────────────────────────────────────────────────

echo "Configuring routes..."
# Endpoint must reach via the original gateway (otherwise the encrypted
# packets would loop back through wg0).
ip -4 route replace "$ENDPOINT_IP/32" via "$ORIG_GW" dev "$ORIG_DEV"
# Everything else goes through the tunnel.
ip -4 route replace default dev "$WG_IF"
echo "  $ENDPOINT_IP/32 → $ORIG_GW dev $ORIG_DEV"
echo "  default → dev $WG_IF"

# ── Kill switch ───────────────────────────────────────────────────────────

echo "Configuring kill switch..."

iptables -F
iptables -P INPUT   DROP
iptables -P OUTPUT  DROP
iptables -P FORWARD DROP

iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

iptables -A INPUT  -i "$WG_IF" -j ACCEPT
iptables -A OUTPUT -o "$WG_IF" -j ACCEPT

iptables -A INPUT  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Allow WireGuard handshake to/from endpoint over the host interface
iptables -A OUTPUT -d "$ENDPOINT_IP" -p udp --dport "$ENDPOINT_PORT" -j ACCEPT
iptables -A INPUT  -s "$ENDPOINT_IP" -p udp --sport "$ENDPOINT_PORT" -j ACCEPT

# Allow LAN to reach Transmission web UI
WEBUI_ALLOW="${WEBUI_ALLOW:-}"
if [[ -n "$WEBUI_ALLOW" ]]; then
    iptables -A INPUT  -s "$WEBUI_ALLOW" -p tcp --dport 9091 -j ACCEPT
    iptables -A OUTPUT -d "$WEBUI_ALLOW" -p tcp --sport 9091 -j ACCEPT
else
    iptables -A INPUT  -p tcp --dport 9091 -j ACCEPT
    iptables -A OUTPUT -p tcp --sport 9091 -j ACCEPT
fi

# Lock down IPv6 entirely
ip6tables -F 2>/dev/null || true
ip6tables -P INPUT   DROP 2>/dev/null || true
ip6tables -P OUTPUT  DROP 2>/dev/null || true
ip6tables -A INPUT  -i lo      -j ACCEPT 2>/dev/null || true
ip6tables -A OUTPUT -o lo      -j ACCEPT 2>/dev/null || true
ip6tables -A INPUT  -i "$WG_IF" -j ACCEPT 2>/dev/null || true
ip6tables -A OUTPUT -o "$WG_IF" -j ACCEPT 2>/dev/null || true

echo "Kill switch active."

# ── Verify VPN connectivity ───────────────────────────────────────────────

echo "Verifying VPN connectivity..."
PUBLIC_IP=""
for i in $(seq 1 15); do
    PUBLIC_IP=$(curl -sf --max-time 5 https://am.i.mullvad.net/ip 2>/dev/null || true)
    [[ -n "$PUBLIC_IP" ]] && { echo "Connected — public IP: $PUBLIC_IP"; break; }
    echo "  Waiting for tunnel... ($i/15)"
    sleep 2
done
[[ -n "$PUBLIC_IP" ]] || echo "WARNING: Could not verify VPN — proceeding anyway."

# ── Transmission user/group ───────────────────────────────────────────────

if ! getent group transmission &>/dev/null; then
    addgroup -g "$PGID" transmission
fi
if ! getent passwd transmission &>/dev/null; then
    adduser -D -u "$PUID" -G transmission -h "$TRANSMISSION_HOME" transmission
fi

chown -R transmission:transmission "$DOWNLOADS_DIR" "$INCOMPLETE_DIR" "$WATCH_DIR" "$TRANSMISSION_HOME"

# ── Default Transmission settings (written once) ──────────────────────────

SETTINGS="$TRANSMISSION_HOME/settings.json"
if [[ ! -f "$SETTINGS" ]]; then
    cat > "$SETTINGS" <<EOF
{
    "download-dir": "$DOWNLOADS_DIR",
    "incomplete-dir": "$INCOMPLETE_DIR",
    "incomplete-dir-enabled": true,
    "watch-dir": "$WATCH_DIR",
    "watch-dir-enabled": true,
    "rpc-enabled": true,
    "rpc-port": 9091,
    "rpc-whitelist-enabled": false,
    "rpc-authentication-required": false,
    "bind-address-ipv4": "0.0.0.0",
    "peer-port": ${PEER_PORT:-51413},
    "peer-port-random-on-start": false,
    "port-forwarding-enabled": false,
    "utp-enabled": true,
    "lpd-enabled": false,
    "dht-enabled": true,
    "pex-enabled": true,
    "encryption": 1,
    "cache-size-mb": 4,
    "umask": 2
}
EOF
    chown transmission:transmission "$SETTINGS"
fi

# ── Optional background VPN watcher ───────────────────────────────────────

if [[ "$VPN_HEALTHCHECK_INTERVAL" =~ ^[0-9]+$ ]] && (( VPN_HEALTHCHECK_INTERVAL > 0 )); then
    echo "VPN watcher enabled (interval ${VPN_HEALTHCHECK_INTERVAL}s, 3 strikes)."
    (
        failures=0
        while sleep "$VPN_HEALTHCHECK_INTERVAL"; do
            if curl -sf --max-time 10 https://am.i.mullvad.net/ip >/dev/null 2>&1; then
                failures=0
            else
                failures=$((failures + 1))
                echo "VPN watcher: probe failed ($failures/3)" >&2
                if (( failures >= 3 )); then
                    echo "VPN watcher: 3 consecutive failures, signalling shutdown." >&2
                    kill -TERM 1
                    exit 0
                fi
            fi
        done
    ) &
    HEALTH_PID=$!
fi

# ── Start Transmission ────────────────────────────────────────────────────

echo "Starting transmission-daemon..."
su-exec transmission transmission-daemon \
    --foreground \
    --config-dir "$TRANSMISSION_HOME" \
    --log-level=info &
TRANSMISSION_PID=$!

# Forward exit status; cleanup runs via trap on signal-driven exits.
status=0
wait "$TRANSMISSION_PID" || status=$?
cleanup "$status"
