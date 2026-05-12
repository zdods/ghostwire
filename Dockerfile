FROM alpine:3.20

LABEL description="Transmission torrent client routed through Mullvad WireGuard VPN"

ENV PUID=1000
ENV PGID=1000
ENV DATA_DIR=/data

RUN apk add --no-cache \
    transmission-daemon \
    wireguard-tools \
    iptables \
    iptables-legacy \
    ip6tables \
    iproute2 \
    curl \
    bash \
    su-exec \
    && apk add --no-cache --repository=https://dl-cdn.alpinelinux.org/alpine/edge/community wireguard-go

# Force the legacy iptables backend. Synology and other older NAS kernels
# don't support nf_tables. The legacy backend works on both old and modern
# kernels, so we use it unconditionally.
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

# Use userspace WireGuard when the host kernel lacks the wireguard module (most NAS systems)
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

ENTRYPOINT ["/entrypoint.sh"]
