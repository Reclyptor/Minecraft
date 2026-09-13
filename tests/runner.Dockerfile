# syntax=docker/dockerfile:1
# Test runner: bats over the built image, so the tests see the real toolkit,
# adapter and game; python3 serves the smoke test's webhook receiver.
ARG GAME_IMAGE=minecraft:test
FROM ${GAME_IMAGE}
USER root
SHELL ["/bin/bash", "-eo", "pipefail", "-c"]
RUN apt-get update \
 && apt-get install -y --no-install-recommends bats python3 \
 && rm -rf /var/lib/apt/lists/*
USER 1000:1000
