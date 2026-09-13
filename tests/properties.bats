#!/usr/bin/env bats
load test_helper

setup()    { setup_adapter; }
teardown() { teardown_adapter; }

@test "property names map from PROP_*" {
    [ "$(mc_prop_name PROP_MAX_PLAYERS)" = max-players ]
    [ "$(mc_prop_name PROP_MOTD)" = motd ]
    [ "$(mc_prop_name PROP_QUERY__PORT)" = query.port ]
    [ "$(mc_prop_name PROP_LEVEL_SEED)" = level-seed ]
}

@test "renders, merges over the existing file, and forces the toolkit's keys" {
    local f="$DATA_DIR/server.properties"
    printf '#comment\nmotd=old motd\ndifficulty=hard\nview-distance=12\n' > "$f"
    export PROP_MOTD="A Minecraft Server" PROP_MAX_PLAYERS=20 PROP_QUERY__PORT=25565 PORT=25566 RCON_PORT=25580
    mc_render_properties "$f"
    grep -q '^motd=A Minecraft Server$' "$f"
    grep -q '^max-players=20$' "$f"
    grep -q '^query.port=25565$' "$f"
    grep -q '^difficulty=hard$' "$f"
    grep -q '^view-distance=12$' "$f"
    grep -q '^enable-rcon=true$' "$f"
    grep -q '^rcon.port=25580$' "$f"
    grep -q '^rcon.password=test-rcon$' "$f"
    grep -q '^server-port=25566$' "$f"
    grep -q '^white-list=false$' "$f"
    grep -q '^enforce-whitelist=false$' "$f"
    export WHITELIST="alice,bob"
    mc_render_properties "$f"
    grep -q '^white-list=true$' "$f"
    grep -q '^enforce-whitelist=true$' "$f"
    # and back off again: a stale true never survives an empty WHITELIST
    export WHITELIST=""
    mc_render_properties "$f"
    grep -q '^white-list=false$' "$f"
}

@test "shared generics render into their properties; PROP_* still wins" {
    local f="$DATA_DIR/server.properties"
    export MAX_PLAYERS=8 MOTD="Hello" DIFFICULTY=hard WORLD_NAME=cave WORLD_SEED=42
    mc_render_properties "$f"
    grep -q '^max-players=8$' "$f"
    grep -q '^motd=Hello$' "$f"
    grep -q '^difficulty=hard$' "$f"
    grep -q '^level-name=cave$' "$f"
    grep -q '^level-seed=42$' "$f"
    export PROP_MAX_PLAYERS=30 MOTD=""
    mc_render_properties "$f"
    grep -q '^max-players=30$' "$f"
    grep -q '^motd=Hello$' "$f"    # unset/empty generic leaves the existing value alone
}

@test "a missing file is created" {
    mc_render_properties "$DATA_DIR/server.properties"
    grep -q '^enable-rcon=true$' "$DATA_DIR/server.properties"
}

@test "player count parsing" {
    [ "$(mc_parse_player_count 'There are 2 of a max of 20 players online: Alice, Bob')" = 2 ]
    [ "$(mc_parse_player_count 'There are 0 of a max of 20 players online:')" = 0 ]
    [ "$(mc_parse_player_count '')" = 0 ]
}

@test "log lines become JOIN/LEAVE events; chat never does" {
    run mc_parse_events < /tests/fixtures/latest.log
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "JOIN Alice" ]
    [ "${lines[1]}" = "JOIN Bob_Builder" ]
    [ "${lines[2]}" = "LEAVE Alice" ]
    [ "${lines[3]}" = "LEAVE Bob_Builder" ]
    [ "${#lines[@]}" -eq 4 ]
}

@test "access lists go over RCON once per launch" {
    local calls="$TEST_TMP/rcon.log"; : > "$calls"
    rcon() { printf '%s\n' "$*" >> "$calls"; }
    tcp_port_open() { return 0; }
    export ADMINS="alice, bob" WHITELIST="carol"
    mkdir -p "$DATA_DIR/server"; echo "vanilla 26.2" > "$DATA_DIR/server/version"; touch "$DATA_DIR/server/minecraft_server-26.2.jar"
    game_start_cmd
    game_ready; game_ready
    [ "$(grep -c '^op alice$' "$calls")" -eq 1 ]
    [ "$(grep -c '^op bob$' "$calls")" -eq 1 ]
    [ "$(grep -c '^whitelist add carol$' "$calls")" -eq 1 ]
}

@test "backup paths list what exists and never the jar" {
    mkdir -p "$DATA_DIR/world" "$DATA_DIR/world_nether" "$DATA_DIR/server" "$DATA_DIR/logs"
    touch "$DATA_DIR/server.properties" "$DATA_DIR/ops.json" "$DATA_DIR/banned-ips.json" "$DATA_DIR/server/x.jar"
    [ "$(game_backup_paths | tr '\n' ' ')" = "world world_nether server.properties ops.json banned-ips.json " ]
}
