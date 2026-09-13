#!/usr/bin/env bash
# Resolve, download and record the server jar for vanilla, Paper and Fabric.
# shellcheck shell=bash

MANIFEST_URL=${MANIFEST_URL:-https://launchermeta.mojang.com/mc/game/version_manifest_v2.json}
PAPER_API=${PAPER_API:-https://fill.papermc.io/v3/projects/paper}
FABRIC_API=${FABRIC_API:-https://meta.fabricmc.net/v2/versions}

# ── parsers (pure; unit-tested against fixtures) ────────────────────────────

mc_vanilla_latest_from_json() { printf '%s' "$1" | json_get - .latest.release; }

# Metadata URL of one version id from the manifest.
mc_vanilla_url_from_json() {
    local json=$1 id=$2 i v
    for (( i = 0; ; i++ )); do
        v=$(printf '%s' "$json" | json_get - ".versions[$i].id") || return 1
        [[ "$v" == "$id" ]] && { printf '%s' "$json" | json_get - ".versions[$i].url"; return 0; }
    done
}

# "url sha1" of the server jar from a version's metadata JSON.
mc_vanilla_server_from_json() {
    local json=$1 url sha
    url=$(printf '%s' "$json" | json_get - .downloads.server.url) || return 1
    sha=$(printf '%s' "$json" | json_get - .downloads.server.sha1) || return 1
    printf '%s %s\n' "$url" "$sha"
}

# Newest release-shaped Paper version id (the API lists newest first).
mc_paper_latest_from_json() {
    local json=$1 i v
    for (( i = 0; ; i++ )); do
        v=$(printf '%s' "$json" | json_get - ".versions[$i].version.id") || return 1
        [[ "$v" =~ ^[0-9]+(\.[0-9]+)*$ ]] && { printf '%s' "$v"; return 0; }
    done
}

# "id url sha256" of the newest STABLE build (newest first), or of a given build.
#   mc_paper_build_from_json <json> [build-id]
mc_paper_build_from_json() {
    local json=$1 want=${2:-} i id ch
    for (( i = 0; ; i++ )); do
        id=$(printf '%s' "$json" | json_get - "[$i].id") || return 1
        ch=$(printf '%s' "$json" | json_get - "[$i].channel")
        if [[ -n "$want" ]]; then [[ "$id" == "$want" ]] || continue
        else [[ "$ch" == STABLE ]] || continue; fi
        printf '%s %s %s\n' "$id" \
            "$(printf '%s' "$json" | json_get - "[$i].downloads[\"server:default\"].url")" \
            "$(printf '%s' "$json" | json_get - "[$i].downloads[\"server:default\"].checksums.sha256")"
        return 0
    done
}

# Fabric meta lists newest first; the first entry flagged stable wins.
#   /versions/game            → [{version, stable}]
#   /versions/loader/<game>   → [{loader: {version, stable}, …}]
#   /versions/installer       → [{version, stable, url}]
mc_fabric_latest_game_from_json() {
    local json=$1 i v
    for (( i = 0; ; i++ )); do
        v=$(printf '%s' "$json" | json_get - "[$i].version") || return 1
        [[ "$(printf '%s' "$json" | json_get - "[$i].stable")" == true ]] && { printf '%s' "$v"; return 0; }
    done
}
mc_fabric_latest_loader_from_json() {
    local json=$1 i v
    for (( i = 0; ; i++ )); do
        v=$(printf '%s' "$json" | json_get - "[$i].loader.version") || return 1
        [[ "$(printf '%s' "$json" | json_get - "[$i].loader.stable")" == true ]] && { printf '%s' "$v"; return 0; }
    done
}
mc_fabric_latest_installer_from_json() { mc_fabric_latest_game_from_json "$1"; }

# ── the installed record: /data/server/version ──────────────────────────────
#   vanilla <version>                     → game_version prints <version>
#   paper <version> <build>               → game_version prints <version>-<build>
#   fabric <version> <loader> <installer> → game_version prints <version>-<loader>

mc_record_file() { printf '%s/server/version' "$DATA_DIR"; }

mc_record_version() {
    local type v b
    [[ -r "$(mc_record_file)" ]] || return 1
    read -r type v b _ < "$(mc_record_file)" || return 1
    case "$type" in
        vanilla)      printf '%s' "$v" ;;
        paper|fabric) printf '%s-%s' "$v" "$b" ;;
        *)            return 1 ;;
    esac
}

mc_installed_jar() {
    local type v b jar
    [[ -r "$(mc_record_file)" ]] || return 1
    read -r type v b _ < "$(mc_record_file)" || return 1
    case "$type" in
        vanilla) jar="${DATA_DIR}/server/minecraft_server-${v}.jar" ;;
        paper)   jar="${DATA_DIR}/server/paper-${v}-${b}.jar" ;;
        fabric)  jar="${DATA_DIR}/server/fabric-${v}-${b}.jar" ;;
        *) return 1 ;;
    esac
    [[ -f "$jar" ]] || return 1
    printf '%s' "$jar"
}

# ── resolve and install ─────────────────────────────────────────────────────

# The target the configuration points at right now: "<ver>" for vanilla,
# "<ver>-<build>" for Paper, "<ver>-<loader>" for Fabric (a loader release is
# an update, the way a Paper build is).
mc_resolve_target() {
    local json v build loader
    case "${SERVER_TYPE,,}" in
        vanilla)
            if [[ "${VERSION,,}" == latest ]]; then
                json=$(http_get "$MANIFEST_URL") || return 1
                mc_vanilla_latest_from_json "$json"
            else
                printf '%s' "$VERSION"
            fi
            ;;
        paper)
            if [[ "${VERSION,,}" == latest ]]; then
                json=$(http_get "${PAPER_API}/versions") || return 1
                v=$(mc_paper_latest_from_json "$json") || return 1
            else
                v=$VERSION
            fi
            json=$(http_get "${PAPER_API}/versions/${v}/builds") || return 1
            read -r build _ < <(mc_paper_build_from_json "$json") || return 1
            [[ -n "$build" ]] || return 1
            printf '%s-%s' "$v" "$build"
            ;;
        fabric)
            if [[ "${VERSION,,}" == latest ]]; then
                json=$(http_get "${FABRIC_API}/game") || return 1
                v=$(mc_fabric_latest_game_from_json "$json") || return 1
            else
                v=$VERSION
            fi
            json=$(http_get "${FABRIC_API}/loader/${v}") || return 1
            loader=$(mc_fabric_latest_loader_from_json "$json") || return 1
            printf '%s-%s' "$v" "$loader"
            ;;
        *) die "SERVER_TYPE must be vanilla, paper or fabric, got '${SERVER_TYPE}'" ;;
    esac
}

# Download a verified jar to <dest>.  mc_download_jar <url> <sha> <algo> <dest>
mc_download_jar() {
    local url=$1 sha=$2 algo=$3 dest=$4
    http_get -o "${dest}.part" "$url" || { rm -f "${dest}.part"; log_error "download failed: ${url}"; return 1; }
    if ! echo "${sha}  ${dest}.part" | "${algo}sum" -c --quiet - >/dev/null 2>&1; then
        rm -f "${dest}.part"; log_error "checksum mismatch for $(basename "$dest")"; return 1
    fi
    mv "${dest}.part" "$dest"
}

# Fabric publishes no checksum for its server launcher, so the most that can
# be checked is that what arrived is a jar and not an error page: the zip
# signature and a size no launcher build has ever been under.
#   mc_download_launcher <url> <dest>
mc_download_launcher() {
    local url=$1 dest=$2
    http_get -o "${dest}.part" "$url" || { rm -f "${dest}.part"; log_error "download failed: ${url}"; return 1; }
    if [[ "$(head -c 2 "${dest}.part")" != PK ]] || (( $(stat -c %s "${dest}.part") < 102400 )); then
        rm -f "${dest}.part"; log_error "$(basename "$dest") is not a server jar"; return 1
    fi
    mv "${dest}.part" "$dest"
}

# Install <target> (the form mc_resolve_target prints) and update the record.
mc_install_target() {
    local target=$1 dir="${DATA_DIR}/server" json url sha id v build loader installer
    mkdir -p "$dir"
    case "${SERVER_TYPE,,}" in
        vanilla)
            json=$(http_get "$MANIFEST_URL") || return 1
            url=$(mc_vanilla_url_from_json "$json" "$target") || { log_error "version ${target} not in the manifest"; return 1; }
            json=$(http_get "$url") || return 1
            read -r url sha < <(mc_vanilla_server_from_json "$json") || return 1
            log_info "downloading vanilla ${target}"
            mc_download_jar "$url" "$sha" sha1 "${dir}/minecraft_server-${target}.jar" || return 1
            find "$dir" -maxdepth 1 -name '*.jar' ! -name "minecraft_server-${target}.jar" -delete
            printf 'vanilla %s\n' "$target" > "$(mc_record_file)"
            ;;
        paper)
            v=${target%-*}; build=${target##*-}
            json=$(http_get "${PAPER_API}/versions/${v}/builds") || return 1
            read -r id url sha < <(mc_paper_build_from_json "$json" "$build") || return 1
            [[ "$id" == "$build" ]] || { log_error "build ${build} not found for ${v}"; return 1; }
            log_info "downloading paper ${v} build ${build}"
            mc_download_jar "$url" "$sha" sha256 "${dir}/paper-${v}-${build}.jar" || return 1
            find "$dir" -maxdepth 1 -name '*.jar' ! -name "paper-${v}-${build}.jar" -delete
            printf 'paper %s %s\n' "$v" "$build" > "$(mc_record_file)"
            ;;
        fabric)
            v=${target%-*}; loader=${target##*-}
            json=$(http_get "${FABRIC_API}/installer") || return 1
            installer=$(mc_fabric_latest_installer_from_json "$json") || return 1
            log_info "downloading fabric ${v} loader ${loader} (installer ${installer})"
            mc_download_launcher "${FABRIC_API}/loader/${v}/${loader}/${installer}/server/jar" "${dir}/fabric-${v}-${loader}.jar" || return 1
            find "$dir" -maxdepth 1 -name '*.jar' ! -name "fabric-${v}-${loader}.jar" -delete
            printf 'fabric %s %s %s\n' "$v" "$loader" "$installer" > "$(mc_record_file)"
            ;;
        *) return 1 ;;
    esac
}
