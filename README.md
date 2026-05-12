# ghostwire

[![Build and publish image](https://github.com/zdods/ghostwire/actions/workflows/docker.yml/badge.svg?branch=main)](https://github.com/zdods/ghostwire/actions/workflows/docker.yml)

Transmission torrent client running inside a Mullvad WireGuard tunnel, packaged as a Docker image. All traffic from Transmission is routed through the VPN. An iptables kill switch drops all non-tunnel traffic so nothing leaks if the VPN goes down.

## Quickstart

```bash
# 1. Make a directory and drop your Mullvad WireGuard .conf into config/
mkdir -p /your/host/path/config
cp ~/Downloads/mullvad-*.conf /your/host/path/config/

# 2. Pull and run
docker run -d --name ghostwire --restart unless-stopped \
    --privileged \
    -p 9091:9091 -p 51413:51413 -p 51413:51413/udp \
    -v /your/host/path:/data \
    ghcr.io/zdods/ghostwire:stable

# 3. Visit the web UI
open http://localhost:9091
```

See the [Running](#running) section for a `docker compose` equivalent and the full set of options.

## Requirements

- Docker Engine 20.10+ (with Compose v2 if you use `docker compose`)
- A [Mullvad](https://mullvad.net) subscription
- **Privileged mode** on the container — required to set up the WireGuard tunnel and iptables kill switch on older NAS kernels (Synology, etc.). On modern Linux kernels you can instead grant `NET_ADMIN` + `SYS_MODULE` and bind-mount `/dev/net/tun` (see commented block in `docker-compose.yml`).

The image uses [wireguard-go](https://git.zx2c4.com/wireguard-go/) (the userspace implementation) so it works on hosts whose kernel lacks the `wireguard` module — typical for off-the-shelf NAS units. On hosts that *do* have the kernel module, wg-quick will still prefer it; userspace is only the fallback.

## Getting a Mullvad WireGuard config

1. Log in at [mullvad.net](https://mullvad.net/en/account)
2. Go to **WireGuard configuration** under your account
3. Select **Linux** as the platform and **WireGuard** as the tunnel type
4. Pick a server and click **Download**
5. Place the downloaded `.conf` file in `<your-data-dir>/config/`

The container picks up the first `.conf` file it finds in that directory.

## Directory layout

Mount a single directory to `/data` inside the container. On first run, missing subdirectories are created automatically.

```
/your/host/path/
├── config/
│   └── mullvad.conf      ← your Mullvad WireGuard config (required)
├── downloads/            ← completed downloads
├── incomplete/           ← in-progress downloads
├── watch/                ← drop .torrent files here to auto-add
└── transmission/         ← Transmission state and settings
```

## Running

The image is published to the [GitHub Container Registry](https://github.com/zdods/ghostwire/pkgs/container/ghostwire) on every push to `main`, with multi-architecture support (`linux/amd64` and `linux/arm64`).

Available tags:

| Tag | Meaning |
|---|---|
| `stable` | Alias for the most recent `main` build — recommended default |
| `main` | Same image as `stable`, named for the branch |
| `vX.Y.Z` / `vX.Y` | Released versions (when tagged). **Pin to one of these for production.** |
| `sha-<short>` | A specific commit |

Create a `docker-compose.yml` (or use the one in this repo as a base):

```yaml
services:
  ghostwire:
    image: ghcr.io/zdods/ghostwire:stable
    container_name: ghostwire
    restart: unless-stopped
    privileged: true
    environment:
      - PUID=1000
      - PGID=1000
      - PEER_PORT=51413
    volumes:
      - /your/host/path:/data
    ports:
      - "9091:9091"
      - "51413:51413/tcp"
      - "51413:51413/udp"
```

Then:

```bash
docker compose up -d                          # start
docker compose pull && docker compose up -d   # update
docker compose logs -f ghostwire              # follow logs
```

The Transmission web UI is available at `http://<host-ip>:9091`.

> **Security note:** the web UI is unauthenticated by default (`rpc-authentication-required: false`). On a trusted home network this is fine. If your network is shared or the host is reachable from anywhere else, restrict access with `WEBUI_ALLOW` (below) and/or enable authentication in `<data>/transmission/settings.json`.

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `PUID` | `1000` | UID to run Transmission as |
| `PGID` | `1000` | GID to run Transmission as |
| `PEER_PORT` | `51413` | BitTorrent peer port |
| `WEBUI_ALLOW` | _(unset)_ | CIDR to restrict web UI access (e.g. `192.168.1.0/24`). Unset allows all inbound on port 9091. |
| `VPN_HEALTHCHECK_INTERVAL` | `0` | When set to a positive integer, re-probes Mullvad every N seconds in the background. Three consecutive failures terminate the container so Docker's restart policy re-establishes the tunnel. `0` disables the watcher. |

## Verifying the VPN is active

Check the container logs — the public IP is printed on startup:

```bash
docker compose logs ghostwire
```

Look for a line like:

```
Connected — public IP: 185.213.154.x
```

You can also confirm via the Mullvad API from inside the container:

```bash
docker exec ghostwire curl -s https://am.i.mullvad.net/json
```

The response will show `"mullvad_exit_ip": true` if traffic is correctly routed through Mullvad.

### Container healthcheck

The image declares a Docker `HEALTHCHECK` that probes Mullvad every 60 seconds. If the tunnel drops, the container is reported as `unhealthy` — visible in `docker ps`, Portainer, Synology Container Manager, and most NAS dashboards.

```bash
docker inspect --format '{{.State.Health.Status}}' ghostwire
```

For automatic restart on a degraded VPN (rather than just a status flag), set `VPN_HEALTHCHECK_INTERVAL` — the in-container watcher exits non-zero after three consecutive failures so the Docker restart policy re-establishes the tunnel from scratch.

## Verifying the kill switch

The kill switch should drop every packet that doesn't go through `wg0`. To prove it works, bring down the tunnel from inside the container and confirm Transmission loses connectivity:

```bash
# 1. Confirm baseline: traffic flows through Mullvad
docker exec ghostwire curl -sf --max-time 5 https://am.i.mullvad.net/ip

# 2. Tear the tunnel down (path is the sanitized config inside the container)
docker exec ghostwire wg-quick down /tmp/wg0.conf

# 3. The same probe should now fail (timeout, not a leaked IP)
docker exec ghostwire curl -sf --max-time 5 https://am.i.mullvad.net/ip && echo "LEAK" || echo "blocked ✓"

# 4. Restart the container to restore the tunnel — `docker compose restart ghostwire`,
#    `docker restart ghostwire`, or your NAS UI all work.
```

If step 3 prints `LEAK` (or any IP address), the kill switch is not active — do not torrent until you've fixed it.

## Customizing Transmission settings

Transmission writes its settings to `<data>/transmission/settings.json` on first run. Edit that file and restart the container to apply changes. The file is not overwritten on subsequent starts.

Common adjustments: enabling RPC authentication, raising `cache-size-mb`, narrowing `rpc-whitelist`, or tweaking peer/queue limits. The full list of keys is documented in the [Transmission wiki](https://github.com/transmission/transmission/blob/main/docs/Editing-Configuration-Files.md).

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| Logs end with `iptables is not functional` | Privileged mode is off, or the container is missing `NET_ADMIN`. Re-check `privileged: true` in your compose file. |
| `/dev/net/tun could not be created` | Same as above — need `NET_ADMIN` or bind-mount `/dev/net/tun`. |
| `Could not resolve endpoint <host>` | The container can't reach DNS at startup. Verify the host has working internet and that the WireGuard `.conf` `Endpoint` line is intact. |
| Container is `unhealthy` but VPN looked fine in logs | Transient probe failure (Mullvad rate-limited, network blip). Watch a few cycles; consider `VPN_HEALTHCHECK_INTERVAL` for automatic recovery. |
| Web UI not reachable from LAN | Check port `9091` is mapped, `WEBUI_ALLOW` isn't excluding your subnet, and the host firewall isn't blocking. |
| Transmission shows "no connection" | The kill switch is doing its job — VPN is down. Check logs and the Mullvad account status. |
| Want to reset all Transmission state | Stop the container, delete `<data>/transmission/`, start again. The `.conf` and downloads are untouched. |

## Ports

| Port | Protocol | Purpose |
|---|---|---|
| `9091` | TCP | Transmission web UI |
| `51413` | TCP + UDP | BitTorrent peer connections |

## Disclaimer

This image is a tool. Use it only for content you have the right to download. The author isn't liable for how it's used.

## License

[MIT](LICENSE)
