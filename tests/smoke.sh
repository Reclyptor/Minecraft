#!/usr/bin/env bash
# End-to-end against the real server: jar resolution and download → world
# generation → RCON → quiesced backup → live update check → SIGTERM saves,
# then a second, shorter run on Fabric (launcher download → ready → RCON →
# SIGTERM). Webhooks go to a receiver in a sidecar container on a private
# network.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${GAME_IMAGE:=minecraft:test}"
runner="${GAME_IMAGE}-runner"
name=minecraft-smoke-$$
net="${name}-net"
hooks_ctr="${name}-hooks"
hook_port=18089
work=$(mktemp -d)
hooks="$work/webhooks.log"

cleanup() {
    docker rm -f "$name" "${name}-fabric" "$hooks_ctr" >/dev/null 2>&1 || true
    docker network rm "$net" >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT

fail() {
    echo "SMOKE FAIL: $*" >&2
    echo "--- container log ---" >&2; docker logs "$name" 2>&1 | tail -80 >&2 || true
    echo "--- webhooks ---" >&2; sync_hooks; cat "$hooks" >&2
    exit 1
}
step() { echo "==> $*"; }
sync_hooks() { docker logs "$hooks_ctr" 2>/dev/null > "$hooks" || true; }
wait_for() {
    local what=$1 pattern=$2 timeout=${3:-60} i
    for (( i = 0; i < timeout; i++ )); do
        sync_hooks; grep -qE "$pattern" "$hooks" && return 0; sleep 1
    done
    fail "timed out waiting for ${what}: /${pattern}/"
}
in_game() { docker exec "$name" bash -c "source /opt/gameops/shim/adapter.sh; adapter_load; $*"; }

step "build images"
[[ -n "$(docker images -q "$GAME_IMAGE")" ]] || docker build -q -t "$GAME_IMAGE" . >/dev/null
docker build -q -t "$runner" --build-arg "GAME_IMAGE=${GAME_IMAGE}" -f tests/runner.Dockerfile tests >/dev/null

step "start webhook receiver"
docker network create "$net" >/dev/null
docker run -d --name "$hooks_ctr" --network "$net" --entrypoint python3 "$runner" -u -c "
import http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', 0))).decode()
        print(body, flush=True)
        self.send_response(204); self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(('0.0.0.0', ${hook_port}), H).serve_forever()
" >/dev/null
sleep 1

step "run minecraft (vanilla, latest: downloads the jar and generates a world)"
docker run -d --name "$name" --network "$net" \
    -e "DISCORD_WEBHOOK_URL=http://${hooks_ctr}:${hook_port}/hook" \
    -e SERVER_NAME=Smoke -e EULA=TRUE -e RCON_PASSWORD=smoke-rcon -e MEMORY=1G \
    -e MOTD="Smoke Test" -e WORLD_SEED=42 -e PROP_ONLINE_MODE=false -e ADMINS=alice -e WHITELIST=alice \
    -e UPDATE_ON_BOOT=false -e STOP_TIMEOUT=90 -e BACKUP_RETAIN_DAYS=0 -e LOG_LEVEL=debug \
    "$GAME_IMAGE" >/dev/null
wait_for "START notification" 'Smoke server is online' 900

step "health and RCON"
for i in $(seq 1 12); do
    [[ "$(docker inspect -f '{{.State.Health.Status}}' "$name")" == healthy ]] && break
    sleep 5
done
[[ "$(docker inspect -f '{{.State.Health.Status}}' "$name")" == healthy ]] || fail "container health is $(docker inspect -f '{{.State.Health.Status}}' "$name")"
listing=$(in_game 'rcon list')
[[ "$listing" == *"There are 0 of a max"* ]] || fail "rcon list returned '${listing}'"
echo "    rcon list: ${listing}"
version=$(in_game 'game_version')
[[ "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]] || fail "game_version returned '${version}'"
echo "    installed: ${version}"
[[ "$(in_game 'game_players')" == 0 ]] || fail "expected 0 players"
docker exec "$name" grep -c '^motd=Smoke Test$' /data/server.properties >/dev/null || fail "server.properties not rendered"
docker exec "$name" grep -c '^white-list=true$' /data/server.properties >/dev/null || fail "white-list not forced on"
docker exec "$name" grep -ci 'alice' /data/whitelist.json >/dev/null || fail "whitelist not applied over RCON"

step "backup (quiesced)"
docker exec "$name" gameops backup
wait_for "BACKUP_POST notification" 'Manual backup of the Smoke server complete: /backups/minecraft-' 120
archive=$(docker exec "$name" sh -c 'ls /backups/minecraft-*.tar.gz')
listing=$(docker exec "$name" tar -tzf "$archive")
grep -c '^world/level.dat$' <<<"$listing" >/dev/null || fail "archive lacks world/level.dat"
grep -c '^server.properties$' <<<"$listing" >/dev/null || fail "archive lacks server.properties"
! grep -c '\.jar$' <<<"$listing" >/dev/null || fail "archive must not contain the jar"
docker logs "$name" 2>&1 | grep -c 'Automatic saving is now enabled' >/dev/null || fail "save-on was not restored after the backup"

step "update check against the live version manifest"
out=$(in_game 'game_update_available; echo "rc=$?"')
echo "    installed ${version}, check → ${out##*$'\n'}"
[[ "$out" == *"rc=1"* ]] || fail "just installed, so the check must report current: ${out}"

step "graceful stop on SIGTERM saves the world"
docker stop -t 120 "$name" >/dev/null
code=$(docker inspect -f '{{.State.ExitCode}}' "$name")
[[ "$code" == 0 ]] || fail "expected exit 0 after SIGTERM, got ${code}"
wait_for "STOP notification" 'Smoke server has shut down' 10
docker logs "$name" 2>&1 | grep -cF "Saving chunks for level 'ServerLevel[world]'/minecraft:overworld" >/dev/null || fail "world was not saved on shutdown"

step "run minecraft (fabric, latest: launcher download, then the launcher fetches the game)"
name_vanilla=$name
name="${name}-fabric"
docker run -d --name "$name" --network "$net" \
    -e "DISCORD_WEBHOOK_URL=http://${hooks_ctr}:${hook_port}/hook" \
    -e SERVER_NAME=Fabric -e EULA=TRUE -e RCON_PASSWORD=smoke-rcon -e MEMORY=1G -e SERVER_TYPE=fabric \
    -e WORLD_SEED=42 -e PROP_ONLINE_MODE=false \
    -e UPDATE_ON_BOOT=false -e STOP_TIMEOUT=90 -e BACKUP_RETAIN_DAYS=0 -e LOG_LEVEL=debug \
    "$GAME_IMAGE" >/dev/null
wait_for "START notification" 'Fabric server is online' 900
version=$(in_game 'game_version')
[[ "$version" =~ ^[0-9]+(\.[0-9]+)*-[0-9]+(\.[0-9]+)*$ ]] || fail "fabric game_version returned '${version}'"
echo "    installed: ${version}"
[[ "$(docker exec "$name" cut -d' ' -f1 /data/server/version)" == fabric ]] || fail "record is not a fabric record"
docker exec "$name" sh -c 'ls /data/server/fabric-*.jar' >/dev/null || fail "fabric launcher jar missing"
docker logs "$name" 2>&1 | grep -c 'with Fabric Loader' >/dev/null || fail "server did not start through Fabric Loader"
listing=$(in_game 'rcon list')
[[ "$listing" == *"There are 0 of a max"* ]] || fail "rcon list returned '${listing}'"
docker stop -t 120 "$name" >/dev/null
[[ "$(docker inspect -f '{{.State.ExitCode}}' "$name")" == 0 ]] || fail "expected exit 0 after SIGTERM, got $(docker inspect -f '{{.State.ExitCode}}' "$name")"
wait_for "STOP notification" 'Fabric server has shut down' 10
name=$name_vanilla

echo "SMOKE OK"
