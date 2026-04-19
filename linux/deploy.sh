#!/usr/bin/env bash
# deploy.sh — pull and start the Altosec proxy stack (HTTP, no TLS)
#
# TLS is terminated by the upstream nginx reverse proxy.
# This server runs plain HTTP on port 80; nginx forwards requests here.
#
# Usage:
#   sudo bash deploy.sh [--use-ghcr] [--deploy-dir /path]
#
# Options:
#   --use-ghcr     Pull image from GHCR instead of local build (default: use GHCR)
#   --deploy-dir   Path containing docker-compose files (default: $ALTOSEC_DEPLOY_DIR or /opt/altosec-deploy)

set -euo pipefail

log() { echo "[deploy] $*"; }
err() { echo "[deploy] ERROR: $*" >&2; exit 1; }

USE_GHCR=true
DEPLOY_DIR="${ALTOSEC_DEPLOY_DIR:-/opt/altosec-deploy}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --use-ghcr)    USE_GHCR=true;    shift   ;;
        --no-ghcr)     USE_GHCR=false;   shift   ;;
        --deploy-dir)  DEPLOY_DIR="$2";  shift 2 ;;
        *) err "Unknown argument: $1" ;;
    esac
done

cd "$DEPLOY_DIR"

# Remove Docker Desktop credential helper if present — it's not available inside
# WSL2 without Docker Desktop and causes "docker-credential-desktop.exe not found".
DOCKER_CFG="${HOME}/.docker/config.json"
if [[ -f "$DOCKER_CFG" ]] && grep -q 'desktop' "$DOCKER_CFG"; then
    sed -i '/"credsStore"/d' "$DOCKER_CFG" || true
    log "Removed Docker Desktop credential helper from Docker config."
fi

if $USE_GHCR; then
    COMPOSE_BASE="docker-compose.ghcr.yml"
else
    COMPOSE_BASE="docker-compose.yml"
fi

# Stop any existing stack + remove stale container by fixed name (idempotent).
log "Stopping existing stack..."
docker compose -f "$COMPOSE_BASE" down 2>/dev/null || true
docker rm -f altosec_proxy 2>/dev/null || true

if $USE_GHCR; then
    log "Pulling image from GHCR..."
    docker compose -f "$COMPOSE_BASE" pull
    log "Starting stack (HTTP port 80)..."
    docker compose -f "$COMPOSE_BASE" up -d
else
    log "Building and starting stack (HTTP port 80)..."
    docker compose -f "$COMPOSE_BASE" up -d --build
fi

log "Done. Container is up on port 80 (nginx handles TLS on 443)."
