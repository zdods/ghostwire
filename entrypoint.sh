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

die() { echo "ERROR: $*" >&2; exit 1; }

# ── Ensure /dev/net/tun exists ────────────────────────────────────────────────

if [[ ! -c /dev/net/tun ]]; then
    echo "TUN device not found — creating /dev/net/tun..."
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200 || die "/dev/net/tun does not exist and could not be created. Enable privileged mode on the container."
    chmod 600 /dev/net/tun
fi

# ── Locate WireGuard config ───────────────────────────────────────────────────

[[ -d "$CONFIG_DIR" ]] || die "Config directory not found: $CONFIG_DIR"
WG_CONF=$(find "$CONFIG_DIR" -maxdepth 1 -name '*.conf' | head -1)
[[ -n "$WG_CONF" ]] || die "No .conf file found in $CONFIG_DIR — place your Mullvad WireGuard config there."

ENDPOINT_HOST=$(grep -E '^\s*Endpoint\s*=' "$WG_CONF" | head -1 | sed 's/.*=\s*//' | cut -d':' -f1 | tr -d ' ')
ENDPOINT_PORT=$(grep -E '^\s*Endpoint\s*=' "$WG_CONF" | head -1 | sed 's/.*=\s*//' | rev | cut -d':' -f1 | rev | tr -d ' ')

# ── Ensure data subdirs exist ─────────────────────────────────────────────────

mkdir -p "$DOWNLOADS_DIR" "$INCOMPLETE_DIR" "$WATCH_DIR" "$TRANSMISSION_HOME"

# ── Bring up WireGuard ────────────────────────────────────────────────────────

chmod 600 "$WG_CONF"

echo "Starting WireGuard tunnel ($WG_CONF)..."
wg-quick up "$WG_CONF" || die "wg-quick failed"

# ── Kill switch ───────────────────────────────────────────────────────────────
# Block all traffic not going through the tunnel.
# Exceptions: loopback, established connections, and the WireGuard UDP handshake.

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

# Allow the WireGuard UDP handshake to the Mullvad endpoint
if [[ -n "$ENDPOINT_HOST" && -n "$ENDPOINT_PORT" ]]; then
    iptables -A OUTPUT -d "$ENDPOINT_HOST" -p udp --dport "$ENDPOINT_PORT" -j ACCEPT
    iptables -A INPUT  -s "$ENDPOINT_HOST" -p udp --sport "$ENDPOINT_PORT" -j ACCEPT
fi

# Allow Transmission web UI inbound (restrict to LAN via WEBUI_ALLOW env if desired)
WEBUI_ALLOW="${WEBUI_ALLOW:-}"
if [[ -n "$WEBUI_ALLOW" ]]; then
    iptables -A INPUT  -s "$WEBUI_ALLOW" -p tcp --dport 9091 -j ACCEPT
    iptables -A OUTPUT -d "$WEBUI_ALLOW" -p tcp --sport 9091 -j ACCEPT
else
    iptables -A INPUT  -p tcp --dport 9091 -j ACCEPT
    iptables -A OUTPUT -p tcp --sport 9091 -j ACCEPT
fi

# IPv6 — lock down entirely
ip6tables -F 2>/dev/null || true
ip6tables -P INPUT   DROP 2>/dev/null || true
ip6tables -P OUTPUT  DROP 2>/dev/null || true
ip6tables -A INPUT  -i lo      -j ACCEPT 2>/dev/null || true
ip6tables -A OUTPUT -o lo      -j ACCEPT 2>/dev/null || true
ip6tables -A INPUT  -i "$WG_IF" -j ACCEPT 2>/dev/null || true
ip6tables -A OUTPUT -o "$WG_IF" -j ACCEPT 2>/dev/null || true

echo "Kill switch active."

# ── Verify VPN connectivity ───────────────────────────────────────────────────

echo "Verifying VPN connectivity..."
for i in {1..10}; do
    PUBLIC_IP=$(curl -sf --max-time 5 https://am.i.mullvad.net/ip 2>/dev/null || true)
    [[ -n "$PUBLIC_IP" ]] && { echo "Connected — public IP: $PUBLIC_IP"; break; }
    echo "  Waiting for tunnel... ($i/10)"
    sleep 2
done
[[ -n "${PUBLIC_IP:-}" ]] || echo "WARNING: Could not verify VPN — proceeding anyway."

# ── Transmission user/group ───────────────────────────────────────────────────

if ! getent group transmission &>/dev/null; then
    addgroup -g "$PGID" transmission
fi
if ! getent passwd transmission &>/dev/null; then
    adduser -D -u "$PUID" -G transmission -h "$TRANSMISSION_HOME" transmission
fi

chown -R transmission:transmission "$DOWNLOADS_DIR" "$INCOMPLETE_DIR" "$WATCH_DIR" "$TRANSMISSION_HOME"

# ── Default Transmission settings (written once) ──────────────────────────────

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

# ── Start Transmission ────────────────────────────────────────────────────────

echo "Starting transmission-daemon..."
exec su-exec transmission transmission-daemon \
    --foreground \
    --config-dir "$TRANSMISSION_HOME" \
    --log-level=info
