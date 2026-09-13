#!/usr/bin/env bash
# Unit tests, run inside the built image (plus bats) so they see the real
# toolkit, adapter and game binary. Nothing but docker is needed on the host.
#
#   tests/run.sh                    build minecraft:test and run every .bats file
#   SKIP_BUILD=1 tests/run.sh       reuse an existing minecraft:test
set -euo pipefail
cd "$(dirname "$0")/.."

: "${GAME_IMAGE:=minecraft:test}"
if [[ -z "${SKIP_BUILD:-}" ]]; then
    docker build -q -t "$GAME_IMAGE" . >/dev/null
fi
docker build -q -t "${GAME_IMAGE}-runner" --build-arg "GAME_IMAGE=${GAME_IMAGE}" -f tests/runner.Dockerfile tests >/dev/null

docker run --rm \
    -v "$PWD/tests:/tests:ro" \
    -e HOME=/tmp -e TMPDIR=/tmp \
    --entrypoint bats \
    "${GAME_IMAGE}-runner" --print-output-on-failure "${@:-/tests/}"
