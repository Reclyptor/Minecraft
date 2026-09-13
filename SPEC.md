# SPEC: Minecraft — a self-contained dedicated server image

**Status:** IMPLEMENTED.
**Deliverable:** `ghcr.io/reclyptor/minecraft`, built on [GameOps](https://github.com/Reclyptor/GameOps).

---

## 1. Purpose

Run a Minecraft dedicated server — vanilla, Paper or Fabric — as a single container that looks after
itself: it resolves and downloads the server jar for the configured type and version, renders
`server.properties` from the environment, keeps operators and the whitelist applied, takes
scheduled backups with retention (with the world quiesced, so the archive is consistent), follows
new releases and relaunches in place after warning the people playing, posts lifecycle and
join/leave events to Discord, and stops gracefully. Everything operational comes from the GameOps
toolkit; this repo contributes only what is Minecraft-specific.

### Non-goals
- **Not a modpack installer.** Three server types: vanilla, Paper and Fabric. Mods, plugins and
  other server types are out of scope; a plugin dropped into `/data/plugins` on a Paper server, or a
  mod into `/data/mods` on Fabric, works because the server loads it, not because this image knows
  about it.
- **Not a Java version manager.** The image carries one JRE, the one current releases require.
  Older releases that need an older JRE are not supported.
- **Not arm64.** `linux/amd64` only.

---

## 2. Hard constraints

| # | Constraint |
|---|---|
| M1 | **Never start as root.** uid/gid `1000:1000` (`minecraft`). |
| M2 | **The jar lives in the data volume**, under `/data/server`, next to a one-line record of what it is. The image never changes when the server updates; the volume does. |
| M3 | **Every download is verified as far as its source allows**: against the published checksum for vanilla (SHA-1) and Paper (SHA-256); Fabric publishes none for its server launcher, so that jar is fetched over HTTPS from the official host and structure-checked (zip signature, size floor) before it is installed. |
| M4 | **`server.properties` is merged, not overwritten.** The shared vocabulary (`MAX_PLAYERS`, `MOTD`, `DIFFICULTY`, `WORLD_NAME`, `WORLD_SEED`) is rendered first, `PROP_*` wins for the keys it names; keys the server wrote itself survive; the RCON and port keys are always forced to what the toolkit uses. |
| M5 | **Backups quiesce the world** (`save-off`, `save-all flush` … `save-on`) so the archive is never torn, and `save-on` is restored even when the archive fails. |
| M6 | **The EULA is accepted explicitly.** `EULA=TRUE` is required and written to `eula.txt`; the container refuses to start without it. |

---

## 3. The image

`debian:trixie-slim` + `openjdk-25-jre-headless`, nothing else. The server is downloaded at first
start.

| Path | Contents |
|---|---|
| `/data` | The server's working directory (`GAME_DIR` = `DATA_DIR`): world folders, `server.properties`, access lists, `logs/` |
| `/data/server` | The jar and the `version` record (`vanilla <ver>`, `paper <ver> <build>` or `fabric <ver> <loader> <installer>`) |
| `/backups` | Archives of the world folders, `server.properties` and the access lists |
| `/opt/gameops` | The toolkit |
| `/opt/game` | This adapter |

## 4. The adapter

| Contract function | Minecraft implementation |
|---|---|
| `game_install` | Require `EULA=TRUE` and `RCON_PASSWORD`; write `eula.txt`; render `server.properties`; resolve and download the jar when none is installed. |
| `game_version` | From the record: `26.2` (vanilla), `26.2-123` (Paper version-build) or `26.2-0.19.5` (Fabric version-loader). |
| `game_update_available` | `VERSION=latest` only: the newest release (vanilla: the version manifest's `latest.release`; Paper: the newest release-shaped version's newest `STABLE` build; Fabric: the newest stable game version's newest stable loader) compared with the record. A pinned version returns 2. |
| `game_update_apply` | Download and verify the new jar, remove the old one, update the record. |
| `game_start_cmd` | `java -Xms$MEMORY -Xmx$MEMORY $JVM_OPTS -jar <jar> --nogui` in `/data`. |
| `game_ready` | RCON port open **and** `list` answers; on the first success after each launch, `op` and `whitelist add` for `ADMINS` / `WHITELIST` over RCON. |
| `game_save` / `game_broadcast` / `game_players` | `save-all flush`, `say …`, `list` → `There are N of a max`. |
| `game_shutdown` | RCON `stop`. |
| `game_backup_begin` / `game_backup_end` | `save-off` + `save-all flush` / `save-on`. |
| `game_backup_paths` | Existing `world*`, `server.properties`, `ops.json`, `whitelist.json`, `banned-*.json`, `usercache.json`. |
| `game_events` | `logs/latest.log`: `<name> joined the game` / `<name> left the game`, anchored on the log prefix so chat never matches. |

## 5. Verification

- `tests/*.bats` run inside the built image: property-name mapping, rendering and merging,
  version-record parsing, the manifest, build-list and Fabric meta parsers against fixtures,
  resolution and installation with a stubbed HTTP layer (including a checksum mismatch and a
  launcher that is not a jar, both of which must install nothing),
  the update check in every state, the start command, the join/leave parser, the RCON access-list
  application, and the backup path list.
- `tests/smoke.sh`: a real vanilla run — jar download, world generation, `rcon list`, the rendered
  properties and whitelist, a quiesced backup whose archive holds `world/level.dat` and no jar with
  `save-on` restored afterwards, the live update check, and a `SIGTERM` that saves all dimensions
  and exits 0; then a Fabric run — launcher download, the launcher fetching the game, ready,
  `rcon list`, `SIGTERM` exits 0.
