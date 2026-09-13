#!/usr/bin/env bash
# GameOps adapter for Minecraft (vanilla, Paper or Fabric).
# Contract: https://github.com/Reclyptor/GameOps/blob/master/docs/CONTRACT.md
# shellcheck shell=bash
# shellcheck disable=SC2034  # GAME_* and GAME_CMD are consumed by the toolkit

GAME_NAME=minecraft
GAME_DIR=${DATA_DIR}
GAME_PORT=${PORT:-25565}
GAME_PORT_PROTO=tcp
: "${RCON_PORT:=25575}"
: "${SERVER_TYPE:=vanilla}"
: "${VERSION:=latest}"
: "${MEMORY:=2G}"

ADAPTER_DIR=$(dirname "${BASH_SOURCE[0]}")
# shellcheck source=adapter/lib/resolver.sh
source "${ADAPTER_DIR}/lib/resolver.sh"
# shellcheck source=adapter/lib/properties.sh
source "${ADAPTER_DIR}/lib/properties.sh"

SERVER_LOG="${DATA_DIR}/logs/latest.log"

# ── install / version / update ──────────────────────────────────────────────

game_install() {
    is_true "${EULA:-false}" || die "EULA=TRUE is required (https://www.minecraft.net/eula)"
    require_var RCON_PASSWORD "the toolkit saves, stops and counts players over RCON"
    mkdir -p "${DATA_DIR}/server" "${DATA_DIR}/logs"
    echo "eula=true" > "${DATA_DIR}/eula.txt"
    mc_render_properties "${DATA_DIR}/server.properties"
    if ! mc_installed_jar >/dev/null; then
        local target
        target=$(mc_resolve_target) || die "could not resolve ${SERVER_TYPE} ${VERSION}"
        log_action "installing ${SERVER_TYPE} ${target}"
        mc_install_target "$target" || return 1
    fi
}

game_version() { mc_record_version; }

# Only a floating VERSION=latest can have updates; a pinned version has
# nothing to check (2).
game_update_available() {
    [[ "${VERSION,,}" == latest ]] || return 2
    local target current
    target=$(mc_resolve_target) || { log_warn "version source unreachable"; return 1; }
    [[ -n "$target" ]] || { log_warn "version source returned nothing"; return 1; }
    current=$(game_version) || return 1
    [[ "$target" != "$current" ]] || return 1
    printf '%s' "$target"
}

game_update_apply() { mc_install_target "$1"; }

# ── process ─────────────────────────────────────────────────────────────────

game_start_cmd() {
    local jar
    jar=$(mc_installed_jar) || { log_error "no server jar installed"; return 1; }
    local -a jvm=()
    read -ra jvm <<< "${JVM_OPTS:-}"
    GAME_CMD=(java "-Xms${MEMORY}" "-Xmx${MEMORY}" "${jvm[@]}" -jar "$jar" --nogui)
    flag_clear mc.acl.applied
}

# RCON is up only once the world is loaded, and `list` proves the server
# answers rather than merely listens. Operators and whitelist are applied
# the first time the server is ready after each launch.
game_ready() {
    tcp_port_open 127.0.0.1 "$RCON_PORT" && rcon list >/dev/null 2>&1 || return 1
    if ! flag_is_set mc.acl.applied; then
        flag_set mc.acl.applied
        mc_apply_acl
    fi
    return 0
}

game_shutdown() { rcon stop >/dev/null; }

# ── control ─────────────────────────────────────────────────────────────────

game_save()      { rcon "save-all flush" >/dev/null; }
game_broadcast() { rcon "say $*" >/dev/null; }

game_players() {
    local out
    out=$(rcon list 2>/dev/null) || return 1
    mc_parse_player_count "$out"
}

# ── events ──────────────────────────────────────────────────────────────────

game_events() { follow_log "$SERVER_LOG" | mc_parse_events; }

# ── backups ─────────────────────────────────────────────────────────────────

game_backup_begin() { rcon save-off >/dev/null && rcon "save-all flush" >/dev/null; }
game_backup_end()   { rcon save-on >/dev/null; }

# World folders, the properties file and the access lists; never the jar,
# the cache or the logs.
game_backup_paths() {
    local p
    for p in "${DATA_DIR}"/world* "${DATA_DIR}"/server.properties "${DATA_DIR}"/ops.json \
             "${DATA_DIR}"/whitelist.json "${DATA_DIR}"/banned-*.json "${DATA_DIR}"/usercache.json; do
        [[ -e "$p" ]] && printf '%s\n' "${p#"${DATA_DIR}"/}"
    done
    return 0
}
