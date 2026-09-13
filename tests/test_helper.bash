#!/usr/bin/env bash
# Shared bats setup: source the toolkit shim and the adapter against a
# throwaway DATA_DIR. Tests that touch the network override http_get.
# shellcheck shell=bash
# shellcheck disable=SC2034

setup_adapter() {
    TEST_TMP=$(mktemp -d)
    export GAMEOPS_HOME=/opt/gameops
    export GAMEOPS_STATE="$TEST_TMP/state"
    export DATA_DIR="$TEST_TMP/data"
    export BACKUP_DIR="$TEST_TMP/backups"
    export GAME_ADAPTER=/opt/game/adapter.sh
    export LOG_LEVEL=warn
    export RCON_PASSWORD=test-rcon
    export EULA=TRUE
    mkdir -p "$GAMEOPS_STATE" "$DATA_DIR" "$BACKUP_DIR"

    export HTTP_LOG="$TEST_TMP/http.log"
    : > "$HTTP_LOG"

    # shellcheck source=/dev/null
    source "${GAMEOPS_HOME}/shim/adapter.sh"
    adapter_load
}

teardown_adapter() { rm -rf "$TEST_TMP"; }

fixture() { cat "/tests/fixtures/$1"; }

# http_get stub that serves fixtures by URL: manifest, version metadata, the
# Paper versions and builds lists, the Fabric game/loader/installer lists, a
# "jar" download and a launcher-shaped download.
stub_http() {
    # shellcheck disable=SC2317,SC2329  # invoked by the adapter under test
    http_get() {
        printf '%s\n' "$*" >> "$HTTP_LOG"
        local out="" url=""
        while (( $# )); do
            case "$1" in -o) out=$2; shift ;; *) url=$1 ;; esac
            shift
        done
        [[ "${HTTP_STUB_EXIT:-0}" == 0 ]] || return "${HTTP_STUB_EXIT}"
        local file
        case "$url" in
            *version_manifest_v2.json) file=/tests/fixtures/version_manifest_v2.json ;;
            *26.2.json)                file=/tests/fixtures/version-26.2.json ;;
            */versions/26.2/builds)    file=/tests/fixtures/paper-builds.json ;;
            */paper/versions)          file=/tests/fixtures/paper-versions.json ;;
            *fake-server.jar|*fill-data*) file=/tests/fixtures/fake-server.jar ;;
            */versions/game)           file=/tests/fixtures/fabric-game.json ;;
            */versions/loader/26.2)    file=/tests/fixtures/fabric-loader.json ;;
            */versions/installer)      file=/tests/fixtures/fabric-installer.json ;;
            */server/jar)
                # A launcher-shaped body: zip signature, well over the size floor.
                { printf 'PK\003\004'; head -c 120000 /dev/zero; } > "${out:-/dev/stdout}"
                return 0 ;;
            *) return 1 ;;
        esac
        if [[ -n "$out" ]]; then cat "$file" > "$out"; else cat "$file"; fi
    }
}
