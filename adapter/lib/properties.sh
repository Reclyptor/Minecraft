#!/usr/bin/env bash
# server.properties from the environment, and the RCON-applied access lists.
# shellcheck shell=bash

# PROP_MAX_PLAYERS → max-players; PROP_QUERY__PORT → query.port
mc_prop_name() {
    local n=${1#PROP_}
    n=${n,,}
    n=${n//__/.}
    n=${n//_/-}
    printf '%s' "$n"
}

# The shared vocabulary (GameOps CONTRACT §7) rendered into the properties it
# names — only when set, so an unset variable leaves the property alone.
mc_generic_props() {
    local -A map=([MAX_PLAYERS]=max-players [MOTD]=motd [DIFFICULTY]=difficulty [WORLD_NAME]=level-name [WORLD_SEED]=level-seed)
    local var
    for var in MAX_PLAYERS MOTD DIFFICULTY WORLD_NAME WORLD_SEED; do
        [[ -n "${!var:-}" ]] && printf '%s=%s\n' "${map[$var]}" "${!var}"
    done
    return 0
}

# Render <file>: keep every key already in it (the server writes its own),
# apply the shared generics, overlay PROP_* from the environment (it wins for
# the keys it names), then force what the toolkit needs.
mc_render_properties() {
    local file=$1
    local -A props=()
    local line key value var
    if [[ -f "$file" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
            key=${line%%=*}; value=${line#*=}
            props["$key"]=$value
        done < "$file"
    fi
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        props["${line%%=*}"]=${line#*=}
    done < <(mc_generic_props)
    while IFS= read -r var; do
        [[ -n "$var" ]] || continue
        props["$(mc_prop_name "$var")"]=${!var}
    done < <(compgen -A variable | grep '^PROP_' || true)
    props["enable-rcon"]=true
    props["rcon.port"]=${RCON_PORT:-25575}
    props["rcon.password"]=${RCON_PASSWORD:-}
    props["server-port"]=${PORT:-25565}
    # An empty WHITELIST is an open server: the flags are set both ways so a
    # value left behind by an earlier configuration can never lock people out.
    if [[ -n "${WHITELIST:-}" ]]; then
        props["white-list"]=true
        props["enforce-whitelist"]=true
    else
        props["white-list"]=false
        props["enforce-whitelist"]=false
    fi
    {
        echo "#Minecraft server properties (rendered at start from the environment and the previous file)"
        for key in $(printf '%s\n' "${!props[@]}" | sort); do
            printf '%s=%s\n' "$key" "${props[$key]}"
        done
    } > "${file}.tmp"
    mv "${file}.tmp" "$file"
}

# Operators and whitelist over RCON: names, not UUIDs, so the server resolves
# them. Idempotent; run once per launch.
mc_apply_acl() {
    local name
    IFS=',' read -ra names <<< "${ADMINS:-}"
    for name in "${names[@]}"; do
        name=${name// /}
        [[ -n "$name" ]] && rcon "op ${name}" >/dev/null
    done
    IFS=',' read -ra names <<< "${WHITELIST:-}"
    for name in "${names[@]}"; do
        name=${name// /}
        [[ -n "$name" ]] && rcon "whitelist add ${name}" >/dev/null
    done
    return 0
}

# "There are 2 of a max of 20 players online: Alice, Bob" → 2
mc_parse_player_count() {
    local n
    n=$(printf '%s' "$1" | grep -oE 'There are [0-9]+' | grep -oE '[0-9]+' | head -1)
    printf '%s' "${n:-0}"
}

# latest.log lines:
#   [11:20:01] [Server thread/INFO]: Alice joined the game
#   [11:25:00] [Server thread/INFO]: Alice left the game
# Chat lines ("<Alice> Bob joined the game") never match: names cannot
# contain '<' and the pattern anchors on the log prefix.
mc_parse_events() {
    sed -un \
        -e 's/^\[[0-9:]*\] \[Server thread\/INFO\]: \([A-Za-z0-9_]\{1,16\}\) joined the game$/JOIN \1/p' \
        -e 's/^\[[0-9:]*\] \[Server thread\/INFO\]: \([A-Za-z0-9_]\{1,16\}\) left the game$/LEAVE \1/p'
}
