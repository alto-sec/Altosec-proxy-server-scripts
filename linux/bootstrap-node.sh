#!/usr/bin/env bash
# bootstrap-node.sh — provision a new Altosec proxy node
#
# Works on:
#   - Native Linux (Ubuntu 22.04 / 24.04 recommended)
#   - WSL2 Ubuntu (called from Windows via prepare-wsl2.ps1)
#
# What this script does (all automated, no prompts when args are supplied):
#   1. Install Docker Engine (official get.docker.com method)
#   2. Configure firewall (ufw) — TCP 22 and 80 inbound
#      (TLS/443 is terminated by the upstream nginx reverse proxy, not this server)
#   3. Download and register a GitHub Actions self-hosted runner
#   4. Install the runner as a systemd service (auto-start on WSL2/Linux boot)
#
# Network topology:
#   Internet → nginx (TLS 443) → this server (HTTP 80) → Docker container
#   TLS certificates live on the nginx server. This app runs plain HTTP.
#
# Usage:
#   sudo bash bootstrap-node.sh \
#     --repo-url    https://github.com/alto-sec/Altosec-proxy-server \
#     --token       <GitHub runner registration token> \
#     --runner-name <unique-name> \
#     --deploy-domain proxy.example.com
#
# All flags can also be set via environment variables (same names, upper-case):
#   REPO_URL, RUNNER_TOKEN, RUNNER_NAME, DEPLOY_DOMAIN
#
# Runner registration token: GitHub → repo → Settings → Actions → Runners → New self-hosted runner
# Expires within minutes — complete the script immediately after copying it.

set -euo pipefail

# ── Helpers ──────────────────────────────────────────────────────────────────

log()  { echo "[bootstrap] $*"; }
err()  { echo "[bootstrap] ERROR: $*" >&2; exit 1; }

require_root() {
    if [[ $EUID -ne 0 ]]; then
        err "This script must be run as root (sudo bash $0 ...)"
    fi
}

# ── Argument parsing ──────────────────────────────────────────────────────────

REPO_URL="${REPO_URL:-}"
RUNNER_TOKEN="${RUNNER_TOKEN:-}"
RUNNER_NAME="${RUNNER_NAME:-}"
RUNNER_ROOT="${RUNNER_ROOT:-/opt/actions-runner}"
DEPLOY_DIR="${DEPLOY_DIR:-/opt/altosec-deploy}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo-url)    REPO_URL="$2";     shift 2 ;;
        --token)       RUNNER_TOKEN="$2"; shift 2 ;;
        --runner-name) RUNNER_NAME="$2";  shift 2 ;;
        --runner-root) RUNNER_ROOT="$2";  shift 2 ;;
        --deploy-dir)  DEPLOY_DIR="$2";   shift 2 ;;
        *) err "Unknown argument: $1" ;;
    esac
done

[[ -z "$REPO_URL"     ]] && REPO_URL="https://github.com/alto-sec/Altosec-proxy-server"
[[ -z "$RUNNER_TOKEN" ]] && err "--token (GitHub runner registration token) is required."
[[ -z "$RUNNER_NAME"  ]] && err "--runner-name is required."

require_root

# ── 1. Docker Engine ──────────────────────────────────────────────────────────

log "=== Step 1: Docker Engine ==="

# Check for dockerd (the daemon binary), not just the docker client.
# Docker Desktop WSL integration provides the docker client but not dockerd,
# so checking only 'docker info' would skip Engine install when Desktop is running.
if command -v dockerd &>/dev/null && docker info &>/dev/null 2>&1; then
    log "Docker Engine is already installed and running — skipping install."
else
    log "Installing Docker Engine via get.docker.com..."
    apt-get update -qq
    apt-get install -y -qq curl ca-certificates
    curl -fsSL https://get.docker.com | sh
    log "Docker Engine installed."
fi

# Ensure the runner user (the non-root invoker, or root itself) is in docker group.
RUNNER_USER="${SUDO_USER:-root}"
if [[ "$RUNNER_USER" != "root" ]]; then
    usermod -aG docker "$RUNNER_USER" || true
    log "Added $RUNNER_USER to docker group."
fi

# Only manage docker via systemd if docker.service exists.
# Docker Desktop WSL integration provides docker without a systemd unit.
if systemctl list-unit-files docker.service 2>/dev/null | grep -q 'docker.service'; then
    systemctl enable docker
    systemctl start docker
    log "Docker service enabled and started."
else
    log "docker.service unit not found — Docker is available via Docker Desktop WSL integration or similar; skipping systemctl."
fi

# ── 2. Firewall (ufw) ─────────────────────────────────────────────────────────

log "=== Step 2: Firewall ==="

if command -v ufw &>/dev/null; then
    ufw allow 22/tcp comment 'SSH'                         2>/dev/null || true
    ufw allow 80/tcp comment 'HTTP from nginx reverse proxy' 2>/dev/null || true
    if ! ufw status | grep -q "Status: active"; then
        ufw --force enable
        log "ufw enabled with rules for TCP 22, 80."
    else
        log "ufw already active — rules added."
    fi
else
    log "ufw not found — skipping. Ensure TCP 22 and 80 are open in your cloud security group."
fi

# ── 3. Deploy directory + environment variables ───────────────────────────────

log "=== Step 3: Deploy directory ==="

mkdir -p "$DEPLOY_DIR"

# Write ALTOSEC_DEPLOY_DIR to /etc/environment and runner .env so deploy jobs
# can locate compose files without hardcoding the path.
cat > /etc/profile.d/altosec-deploy.sh << EOF
export ALTOSEC_DEPLOY_DIR="${DEPLOY_DIR}"
EOF
chmod 644 /etc/profile.d/altosec-deploy.sh

sed -i '/^ALTOSEC_DEPLOY_DIR=/d' /etc/environment 2>/dev/null || true
echo "ALTOSEC_DEPLOY_DIR=${DEPLOY_DIR}" >> /etc/environment
log "ALTOSEC_DEPLOY_DIR=${DEPLOY_DIR} written to /etc/environment."

RUNNER_ENV_FILE="${RUNNER_ROOT}/.env"
mkdir -p "$RUNNER_ROOT"
sed -i '/^ALTOSEC_DEPLOY_DIR=/d' "$RUNNER_ENV_FILE" 2>/dev/null || true
echo "ALTOSEC_DEPLOY_DIR=${DEPLOY_DIR}" >> "$RUNNER_ENV_FILE"
log "ALTOSEC_DEPLOY_DIR written to ${RUNNER_ENV_FILE} (runner systemd EnvironmentFile)."

# ── 4. GitHub Actions runner ─────────────────────────────────────────────────

log "=== Step 4: GitHub Actions runner ==="

mkdir -p "$RUNNER_ROOT"

if [[ ! -f "$RUNNER_ROOT/config.sh" ]]; then
    log "Downloading latest GitHub Actions runner (linux-x64)..."
    RUNNER_REL="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest)"
    RUNNER_URL="$(echo "$RUNNER_REL" | grep -oP '"browser_download_url":\s*"\K[^"]+actions-runner-linux-x64-[\d.]+\.tar\.gz')"
    [[ -z "$RUNNER_URL" ]] && err "Could not determine latest runner download URL."
    curl -fsSL "$RUNNER_URL" | tar -xz -C "$RUNNER_ROOT"
    log "Runner extracted to $RUNNER_ROOT."
fi

if [[ "$RUNNER_USER" != "root" ]]; then
    chown -R "$RUNNER_USER:$RUNNER_USER" "$RUNNER_ROOT"
fi

if [[ ! -f "$RUNNER_ROOT/.runner" ]]; then
    log "Configuring runner (name=$RUNNER_NAME, repo=$REPO_URL)..."
    LABELS="self-hosted,Linux,altosec-proxy-node,${RUNNER_NAME}"
    if [[ "$RUNNER_USER" == "root" ]]; then
        RUNNER_ALLOW_RUNASROOT=1 \
        "$RUNNER_ROOT/config.sh" \
            --url "$REPO_URL" \
            --token "$RUNNER_TOKEN" \
            --name "$RUNNER_NAME" \
            --labels "$LABELS" \
            --unattended \
            --replace
    else
        sudo -u "$RUNNER_USER" \
        "$RUNNER_ROOT/config.sh" \
            --url "$REPO_URL" \
            --token "$RUNNER_TOKEN" \
            --name "$RUNNER_NAME" \
            --labels "$LABELS" \
            --unattended \
            --replace
    fi
    log "Runner configured."
else
    log "Runner already configured (.runner exists) — skipping config."
fi

SVCNAME=""
pushd "$RUNNER_ROOT" > /dev/null
if [[ "$RUNNER_USER" == "root" ]]; then
    RUNNER_ALLOW_RUNASROOT=1 ./svc.sh install root 2>/dev/null || true
else
    ./svc.sh install "$RUNNER_USER" 2>/dev/null || true
fi
SVCNAME="$(ls /etc/systemd/system/actions.runner.*.service 2>/dev/null | head -1)"
popd > /dev/null

if [[ -n "$SVCNAME" ]]; then
    systemctl daemon-reload
    systemctl enable "$(basename "$SVCNAME")"
    systemctl restart "$(basename "$SVCNAME")"
    log "Runner service $(basename "$SVCNAME") enabled and started."
else
    log "WARNING: Could not determine runner service name. Start manually: cd $RUNNER_ROOT && ./run.sh"
fi

# ── Done ──────────────────────────────────────────────────────────────────────

log ""
log "=== Bootstrap complete ==="
log "  Docker Engine  : $(docker --version 2>/dev/null)"
log "  Deploy dir     : $DEPLOY_DIR"
log "  Runner root    : $RUNNER_ROOT"
log "  Runner name    : $RUNNER_NAME"
log ""
log "Next: confirm the runner shows 'Idle' in GitHub -> Settings -> Actions -> Runners,"
log "then trigger the Deploy workflow (docker pull + compose up on port 80)."
