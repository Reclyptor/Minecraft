# syntax=docker/dockerfile:1
#
# ghcr.io/reclyptor/minecraft — Minecraft dedicated server on the GameOps toolkit.
# Adapter contract: https://github.com/Reclyptor/GameOps/blob/master/docs/CONTRACT.md

ARG GAMEOPS_VERSION=1.0.0
FROM ghcr.io/reclyptor/gameops:${GAMEOPS_VERSION} AS gameops

FROM debian:trixie-slim

ARG PUID=1000
ARG PGID=1000

SHELL ["/bin/bash", "-eo", "pipefail", "-c"]

# The server jar is resolved and downloaded at first start into the data
# volume (SERVER_TYPE / VERSION), so the image holds only a JRE. Current
# releases need Java 25.
RUN apt-get update \
 && apt-get install -y --no-install-recommends openjdk-25-jre-headless ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --system --gid "${PGID}" minecraft \
 && useradd --system --uid "${PUID}" --gid "${PGID}" --no-create-home --shell /usr/sbin/nologin minecraft \
 && install -d -o "${PUID}" -g "${PGID}" /data /backups

COPY --from=gameops /opt/gameops /opt/gameops
COPY adapter/ /opt/game/

RUN chmod 0644 /opt/game/adapter.sh /opt/game/lib/*.sh \
 && bash -n /opt/game/adapter.sh /opt/game/lib/*.sh \
 && java -version 2>&1 | head -1

ENV PATH="/opt/gameops/bin:${PATH}" \
    DATA_DIR=/data \
    BACKUP_DIR=/backups \
    SERVER_NAME=Minecraft \
    PORT=25565 \
    RCON_PORT=25575 \
    SERVER_TYPE=vanilla \
    VERSION=latest \
    MEMORY=2G

USER ${PUID}:${PGID}
VOLUME ["/data", "/backups"]
EXPOSE 25565/tcp 9110/tcp
HEALTHCHECK --interval=60s --timeout=10s --start-period=15m --retries=3 CMD ["gameops", "health"]
ENTRYPOINT ["gameops", "run"]

LABEL org.opencontainers.image.title="minecraft" \
      org.opencontainers.image.description="Minecraft dedicated server (vanilla, Paper or Fabric) with backups, in-place auto-updates, Discord notifications and player events, on the GameOps toolkit" \
      org.opencontainers.image.source="https://github.com/Reclyptor/Minecraft" \
      org.opencontainers.image.licenses="MIT"
