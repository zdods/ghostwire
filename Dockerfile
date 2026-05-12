FROM alpine:3.20

LABEL org.opencontainers.image.title="ghostwire" \
      org.opencontainers.image.description="Transmission torrent client routed through Mullvad WireGuard VPN" \
      org.opencontainers.image.source="https://github.com/zdods/ghostwire" \
      org.opencontainers.image.licenses="MIT"

ENV PUID=1000 \
    PGID=1000 \
    DATA_DIR=/data

# wireguard-go isn't in Alpine 3.20's main community repo. We pin to a specific
# version from edge/community so builds remain reproducible — bump via the
# version arg when a new release is desired.
ARG WIREGUARD_GO_VERSION=0.0.20250522-r8

RUN apk add --no-cache \
        bash \
        curl \
        ip6tables \
        iproute2 \
        iptables \
        iptables-legacy \
        su-exec \
        transmission-daemon \
        wireguard-tools \
    && apk add --no-cache \
        --repository=https://dl-cdn.alpinelinux.org/alpine/edge/community \
        "wireguard-go=${WIREGUARD_GO_VERSION}"

# Force the legacy iptables backend. Older and embedded Linux kernels (e.g.
# Synology, QNAP) don't support nf_tables. The legacy backend works on both
# old and modern kernels, so we use it unconditionally.
RUN for prefix in iptables ip6tables; do \
        for suffix in "" "-restore" "-save"; do \
            tool="${prefix}${suffix}"; \
            legacy_name="${prefix}-legacy${suffix}"; \
            legacy_bin="$(command -v ${legacy_name})"; \
            target="$(command -v ${tool})"; \
            [ -n "$legacy_bin" ] && [ -n "$target" ] || { echo "Missing $tool ($legacy_name)"; exit 1; }; \
            ln -sf "$legacy_bin" "$target"; \
            echo "Linked: $target -> $legacy_bin"; \
        done; \
    done && iptables --version

# Use userspace WireGuard when the host kernel lacks the wireguard module (older and embedded Linux systems)
ENV WG_QUICK_USERSPACE_IMPLEMENTATION=wireguard-go

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Single mount: /data
# Expected layout on host:
#   <mount>/config/   — WireGuard .conf file(s)
#   <mount>/downloads/
#   <mount>/incomplete/
#   <mount>/watch/
VOLUME ["/data"]

EXPOSE 9091

# Marks the container unhealthy if external traffic stops flowing through the
# tunnel — e.g. WireGuard handshake lost, DNS broken, or kill switch is hot
# but VPN is down. Uses Mullvad's own probe endpoint so the check exercises
# the full path: tunnel up + routes correct + iptables permissive enough.
HEALTHCHECK --interval=60s --timeout=10s --start-period=30s --retries=3 \
    CMD curl -sf --max-time 8 https://am.i.mullvad.net/ip > /dev/null || exit 1

ENTRYPOINT ["/entrypoint.sh"]
