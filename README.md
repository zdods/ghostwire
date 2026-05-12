# ghostwire

Transmission torrent client running inside a Mullvad WireGuard tunnel, packaged as a Docker image. All traffic from Transmission is routed through the VPN. An iptables kill switch drops all non-tunnel traffic so nothing leaks if the VPN goes down.

## Requirements

- Docker with Compose
- A [Mullvad](https://mullvad.net) subscription
- `NET_ADMIN` capability available on the host (standard on most NAS systems)

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

## Getting a Mullvad WireGuard config

1. Log in at [mullvad.net](https://mullvad.net/en/account)
2. Go to **WireGuard configuration** under your account
3. Select **Linux** as the platform and **WireGuard** as the tunnel type
4. Pick a server and click **Download**
5. Place the downloaded `.conf` file in `<your-data-dir>/config/`

The container picks up the first `.conf` file it finds in that directory.

## Running

Edit `docker-compose.yml` and set the volume path:

```yaml
volumes:
  - /your/host/path:/data
```

Then start the container:

```bash
docker compose up -d
```

The Transmission web UI is available at `http://<host-ip>:9091`.

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `PUID` | `1000` | UID to run Transmission as |
| `PGID` | `1000` | GID to run Transmission as |
| `PEER_PORT` | `51413` | BitTorrent peer port |
| `WEBUI_ALLOW` | _(unset)_ | CIDR to restrict web UI access (e.g. `192.168.1.0/24`). Unset allows all inbound on port 9091. |

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

## Customizing Transmission settings

Transmission writes its settings to `<data>/transmission/settings.json` on first run. Edit that file and restart the container to apply changes. The file is not overwritten on subsequent starts.

## Ports

| Port | Protocol | Purpose |
|---|---|---|
| `9091` | TCP | Transmission web UI |
| `51413` | TCP + UDP | BitTorrent peer connections |
