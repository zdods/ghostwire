FROM alpine:3.20

LABEL description="Transmission torrent client routed through Mullvad WireGuard VPN"

ENV PUID=1000
ENV PGID=1000
ENV DATA_DIR=/data

RUN apk add --no-cache \
    transmission-daemon \
    wireguard-tools \
    wireguard-go \
    iptables \
    ip6tables \
    iproute2 \
    curl \
    bash \
    su-exec

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
