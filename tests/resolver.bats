#!/usr/bin/env bats
load test_helper

setup()    { setup_adapter; stub_http; }
teardown() { teardown_adapter; }

@test "vanilla: latest release and version metadata" {
    [ "$(mc_vanilla_latest_from_json "$(fixture version_manifest_v2.json)")" = 26.2 ]
    [ "$(mc_vanilla_url_from_json "$(fixture version_manifest_v2.json)" 26.2)" = "https://meta.example/26.2.json" ]
    ! mc_vanilla_url_from_json "$(fixture version_manifest_v2.json)" 9.9.9
    [[ "$(mc_vanilla_server_from_json "$(fixture version-26.2.json)")" == "https://dl.example/fake-server.jar "* ]]
}

@test "paper: newest release-shaped version and newest stable build" {
    [ "$(mc_paper_latest_from_json "$(fixture paper-versions.json)")" = 26.2 ]
    read -r id url sha < <(mc_paper_build_from_json "$(fixture paper-builds.json)")
    [ "$id" = 123 ]
    [ "$url" = "https://fill-data.example/123/paper-26.2-123.jar" ]
    [ ${#sha} -eq 64 ]
    read -r id _ < <(mc_paper_build_from_json "$(fixture paper-builds.json)" 122)
    [ "$id" = 122 ]
    ! mc_paper_build_from_json "$(fixture paper-builds.json)" 999
}

@test "fabric: newest stable game, loader and installer" {
    [ "$(mc_fabric_latest_game_from_json "$(fixture fabric-game.json)")" = 26.2 ]
    [ "$(mc_fabric_latest_loader_from_json "$(fixture fabric-loader.json)")" = 0.19.5 ]
    [ "$(mc_fabric_latest_installer_from_json "$(fixture fabric-installer.json)")" = 1.1.2 ]
    ! mc_fabric_latest_game_from_json '[{"version":"x","stable":false}]'
}

@test "resolve target: vanilla latest, vanilla pinned, paper latest, fabric latest and pinned" {
    export SERVER_TYPE=vanilla VERSION=latest
    [ "$(mc_resolve_target)" = 26.2 ]
    export VERSION=25.1
    [ "$(mc_resolve_target)" = 25.1 ]
    export SERVER_TYPE=paper VERSION=latest
    [ "$(mc_resolve_target)" = 26.2-123 ]
    export SERVER_TYPE=fabric VERSION=latest
    [ "$(mc_resolve_target)" = 26.2-0.19.5 ]
    export VERSION=26.2
    [ "$(mc_resolve_target)" = 26.2-0.19.5 ]
    export SERVER_TYPE=forge
    run mc_resolve_target
    [ "$status" -eq 1 ]
}

@test "install vanilla: downloads, verifies sha1, records, prunes old jars" {
    export SERVER_TYPE=vanilla
    mkdir -p "$DATA_DIR/server"; touch "$DATA_DIR/server/minecraft_server-25.1.jar"
    mc_install_target 26.2
    [ -f "$DATA_DIR/server/minecraft_server-26.2.jar" ]
    [ ! -e "$DATA_DIR/server/minecraft_server-25.1.jar" ]
    [ "$(cat "$DATA_DIR/server/version")" = "vanilla 26.2" ]
    [ "$(game_version)" = 26.2 ]
    [ "$(mc_installed_jar)" = "$DATA_DIR/server/minecraft_server-26.2.jar" ]
}

@test "install paper: records version and build" {
    export SERVER_TYPE=paper
    mc_install_target 26.2-123
    [ -f "$DATA_DIR/server/paper-26.2-123.jar" ]
    [ "$(game_version)" = 26.2-123 ]
}

@test "install fabric: launcher jar, four-field record, loader in the version" {
    export SERVER_TYPE=fabric
    mkdir -p "$DATA_DIR/server"; touch "$DATA_DIR/server/fabric-26.1.2-0.19.4.jar"
    mc_install_target 26.2-0.19.5
    [ -f "$DATA_DIR/server/fabric-26.2-0.19.5.jar" ]
    [ ! -e "$DATA_DIR/server/fabric-26.1.2-0.19.4.jar" ]
    [ "$(cat "$DATA_DIR/server/version")" = "fabric 26.2 0.19.5 1.1.2" ]
    [ "$(game_version)" = 26.2-0.19.5 ]
    [ "$(mc_installed_jar)" = "$DATA_DIR/server/fabric-26.2-0.19.5.jar" ]
    grep -q '/loader/26.2/0.19.5/1.1.2/server/jar' "$HTTP_LOG"
}

@test "a launcher that is not a jar installs nothing" {
    mkdir -p "$DATA_DIR/server"
    mc_download_launcher "https://example/server/jar" "$DATA_DIR/server/fabric-x.jar"   # the stub serves a launcher shape
    [ -f "$DATA_DIR/server/fabric-x.jar" ]
    # An error page: right signature missing, far under the size floor.
    # shellcheck disable=SC2317,SC2329  # invoked by the function under test
    http_get() { printf '<html>error</html>' > "$2"; }
    run mc_download_launcher "https://example/server/jar" "$DATA_DIR/server/fabric-y.jar"
    [ "$status" -eq 1 ]
    [ ! -e "$DATA_DIR/server/fabric-y.jar" ]
    [ ! -e "$DATA_DIR/server/fabric-y.jar.part" ]
}

@test "a checksum mismatch installs nothing" {
    export SERVER_TYPE=paper
    run mc_install_target 26.2-124
    [ "$status" -eq 1 ]
    [ ! -e "$DATA_DIR/server/paper-26.2-124.jar" ]
    [ ! -e "$DATA_DIR/server/version" ]
}

@test "update check: latest ahead, current, pinned, unreachable" {
    export SERVER_TYPE=vanilla VERSION=latest
    mkdir -p "$DATA_DIR/server"; echo "vanilla 26.1.2" > "$DATA_DIR/server/version"
    run game_update_available
    [ "$status" -eq 0 ]; [ "$output" = 26.2 ]
    echo "vanilla 26.2" > "$DATA_DIR/server/version"
    run game_update_available
    [ "$status" -eq 1 ]
    export VERSION=26.2
    run game_update_available
    [ "$status" -eq 2 ]
    export VERSION=latest HTTP_STUB_EXIT=1
    run game_update_available
    [ "$status" -eq 1 ]
    # Fabric: a newer loader alone is an update.
    export SERVER_TYPE=fabric HTTP_STUB_EXIT=0
    echo "fabric 26.2 0.19.4 1.1.2" > "$DATA_DIR/server/version"
    run game_update_available
    [ "$status" -eq 0 ]; [ "$output" = 26.2-0.19.5 ]
    echo "fabric 26.2 0.19.5 1.1.2" > "$DATA_DIR/server/version"
    run game_update_available
    [ "$status" -eq 1 ]
}

@test "game_install requires the EULA and an RCON password, then installs" {
    export SERVER_TYPE=vanilla
    EULA=false run game_install
    [ "$status" -eq 1 ]
    RCON_PASSWORD="" run game_install
    [ "$status" -eq 1 ]
    game_install
    [ "$(cat "$DATA_DIR/eula.txt")" = "eula=true" ]
    [ -f "$DATA_DIR/server/minecraft_server-26.2.jar" ]
    grep -q '^enable-rcon=true$' "$DATA_DIR/server.properties"
}

@test "start command" {
    export SERVER_TYPE=vanilla MEMORY=3G JVM_OPTS="-XX:+UseG1GC -XX:+ParallelRefProcEnabled"
    mkdir -p "$DATA_DIR/server"; echo "vanilla 26.2" > "$DATA_DIR/server/version"; touch "$DATA_DIR/server/minecraft_server-26.2.jar"
    game_start_cmd
    [ "${GAME_CMD[*]}" = "java -Xms3G -Xmx3G -XX:+UseG1GC -XX:+ParallelRefProcEnabled -jar $DATA_DIR/server/minecraft_server-26.2.jar --nogui" ]
}
