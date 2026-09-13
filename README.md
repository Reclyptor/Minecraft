# Minecraft

A self-contained Minecraft dedicated server image — vanilla or Paper — with scheduled, quiesced
backups, in-place auto-updates that warn players first, Discord notifications, player join/leave
events, `server.properties` rendered from the environment, and operators and whitelist kept
applied. Built on the [GameOps](https://github.com/Reclyptor/GameOps) toolkit.

```sh
mkdir -p data backups && sudo chown -R 1000:1000 data backups
docker run -d --name minecraft -p 25565:25565 \
  -e EULA=TRUE -e MEMORY=4G -e ADMINS=you -e WHITELIST=you,friend \
  -e RCON_PASSWORD=secret -e DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/… \
  -v "$PWD/data:/data" -v "$PWD/backups:/backups" \
  ghcr.io/reclyptor/minecraft:latest
```

Or use [`compose.yaml`](compose.yaml). The first start downloads the server jar and generates the
world; an existing `/data` with a world in it is picked up as is.

## What it does for you

| | |
|---|---|
| **Server** | `SERVER_TYPE=vanilla`, `paper` or `fabric`, `VERSION=latest` or a version id. The jar is resolved from the official version sources and downloaded into `/data/server`. Vanilla and Paper jars are checksum-verified; Fabric publishes no checksum for its server launcher, so that one is fetched over HTTPS from the official host and structure-checked. |
| **Backups** | Nightly by default: `save-off` + `save-all flush`, then the world folders, `server.properties` and the access lists into `/backups/minecraft-<timestamp>.tar.gz`, then `save-on`. Pruned after `BACKUP_RETAIN_DAYS`. `docker exec minecraft gameops backup` any time. |
| **Updates** | Hourly check while `VERSION=latest`. When a new release (or Paper build, or Fabric loader) lands: players are warned in-game at 15/10/5/2/1 min, a backup is taken, the world is saved, the new jar is verified and installed, and the server relaunches **inside the same container**. |
| **Notifications** | Discord: online, offline, crashed, updating/updated, backup, join, leave. Plain text, every message overridable. |
| **Access control** | `WHITELIST` turns the whitelist on and adds the names; `ADMINS` grants operator. Applied over RCON on every start, so the lists follow the configuration. On an online-mode server the names must be real accounts — the server resolves them. |
| **Lifecycle** | Graceful stop on `SIGTERM` (`stop` over RCON saves all dimensions). Crashes exit the container with the server's code. |

## Configuration

### Minecraft

| Variable | Default | Meaning |
|---|---|---|
| `SERVER_NAME` | `Minecraft` | Used by notifications only — Minecraft has no server-name field; `MOTD` is what players see in the list. |
| `MAX_PLAYERS` | server default | → `max-players`. |
| `ADMINS` | — | Comma-separated player names granted operator. |
| `WHITELIST` | — | Comma-separated player names; non-empty turns the whitelist on, empty turns it off (an open server) — set explicitly on every start. |
| `MOTD` | server default | → `motd`, the listing text. |
| `WORLD_NAME` | server default | → `level-name`. |
| `WORLD_SEED` | server default | → `level-seed`. |
| `DIFFICULTY` | server default | → `difficulty`. |
| `EULA` | — | Must be `TRUE`: you accept the Minecraft EULA. |
| `SERVER_TYPE` | `vanilla` | `vanilla`, `paper` or `fabric`. Fabric runs the official server launcher, which fetches the matching game jar into `/data` on first start. |
| `VERSION` | `latest` | `latest` (follows releases, enables auto-update) or a version id such as `26.2`. For Fabric the newest stable loader for that game version is always used. |
| `MEMORY` | `2G` | JVM heap (`-Xms`/`-Xmx`). |
| `JVM_OPTS` | — | Extra JVM flags. |
| `PROP_<NAME>` | — | Any `server.properties` key: `PROP_VIEW_DISTANCE=12` → `view-distance=12`; a double underscore is a dot (`PROP_QUERY__PORT` → `query.port`). Wins over the shared names above for the same key. |
| `PORT` | `25565` | Game port (TCP); also forced into `server-port`. |
| `RCON_PORT` / `RCON_PASSWORD` | `25575` / **required** | RCON is how the toolkit saves, stops and counts players; it stays inside the container. |

`server.properties` is re-rendered on every start: the shared names are applied, `PROP_*` values win for the keys they name,
keys the server wrote itself are kept, and `enable-rcon`, `rcon.port`, `rcon.password` and
`server-port` are always set from the variables above.

### Backups, updates, notifications

These are the [GameOps](https://github.com/Reclyptor/GameOps#configuration) variables and are
identical across every Reclyptor game image: `BACKUP_CRON`, `BACKUP_RETAIN_DAYS`,
`BACKUP_ON_UPDATE`, `UPDATE_CRON`, `UPDATE_ON_BOOT`, `UPDATE_WARN_MINUTES`,
`UPDATE_SKIP_IF_PLAYERS`, `STOP_TIMEOUT`, `METRICS_PORT`, `DISCORD_WEBHOOK_URL`,
`DISCORD_<EVENT>_MESSAGE`, `TZ`, … Backups are verified as they are written; `gameops backup list`,
`gameops backup verify latest` and `gameops restore latest` work from `docker exec`.

## Volumes and ports

| | |
|---|---|
| `/data` | The server's working directory: `world*/`, `server.properties`, access lists, `logs/`, `server/` (the jar) — uid/gid **1000** |
| `/backups` | Archives. Mount a NAS share here for off-box copies. |
| `25565/tcp` | Game |
| `25575/tcp` | RCON — do not publish it; `docker exec minecraft gameops rcon list` |

## Development

```sh
tests/run.sh      # bats, inside the built image
tests/smoke.sh    # real server: download → world → RCON → quiesced backup → live update check → SIGTERM save
```

## License

MIT.
