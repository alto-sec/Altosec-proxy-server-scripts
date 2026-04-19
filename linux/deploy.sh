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

# When running under sudo, share the invoking user's Docker credentials so that
# GHCR login performed by the runner user is visible to root.
if [[ -n "${SUDO_USER:-}" ]]; then
    INVOKER_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    export DOCKER_CONFIG="${INVOKER_HOME}/.docker"
fi

# Remove Docker Desktop credential helper if present — it's not available inside
# WSL2 without Docker Desktop and causes "docker-credential-desktop.exe not found".
# Use Python so the JSON stays valid after the edit.
DOCKER_CFG="${DOCKER_CONFIG:-${HOME}/.docker}/config.json"
if [[ -f "$DOCKER_CFG" ]]; then
    python3 - "$DOCKER_CFG" <<'PYEOF' 2>/dev/null || true
import json, sys
path = sys.argv[1]
with open(path) as f:
    cfg = json.load(f)
changed = False
for key in ('credsStore', 'credHelpers'):
    if key in cfg:
        val = cfg[key]
        if isinstance(val, str) and 'desktop' in val.lower():
            del cfg[key]; changed = True
        elif isinstance(val, dict):
            cfg[key] = {k: v for k, v in val.items() if 'desktop' not in v.lower()}
            if cfg[key] != val: changed = True
if changed:
    with open(path, 'w') as f:
        json.dump(cfg, f, indent=2)
    print("[deploy] Removed Docker Desktop credential helper from Docker config.")
PYEOF
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
