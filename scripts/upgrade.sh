#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$PROJECT_ROOT/backend_api_python/.env"
ROOT_ENV_FILE="$PROJECT_ROOT/.env"
BACKUP_DIR="$PROJECT_ROOT/backups/upgrade"
SKIP_GIT=0
DO_BACKUP=1

usage() {
    cat <<EOF
Usage: ./scripts/upgrade.sh [options]

Options:
  --skip-git    Skip git pull and only rebuild/restart containers
  --no-backup   Skip .env backup
  -h, --help    Show this help
EOF
}

log() {
    printf '\033[1;34m==>\033[0m %s\n' "$1"
}

ok() {
    printf '\033[1;32m✅\033[0m %s\n' "$1"
}

warn() {
    printf '\033[1;33m⚠️\033[0m %s\n' "$1"
}

fail() {
    printf '\033[1;31m❌\033[0m %s\n' "$1" >&2
    exit 1
}

run() {
    printf '\033[90m$'
    printf ' %q' "$@"
    printf '\033[0m\n'
    "$@"
}

trap 'fail "Upgrade failed at line $LINENO"' ERR

while [ "$#" -gt 0 ]; do
    case "$1" in
        --skip-git)
            SKIP_GIT=1
            ;;
        --no-backup)
            DO_BACKUP=0
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "Unknown option: $1"
            ;;
    esac
    shift
done

cd "$PROJECT_ROOT"

if [ ! -d .git ]; then
    fail "Not a git repository: $PROJECT_ROOT"
fi

if [ ! -f "$ENV_FILE" ]; then
    fail "$ENV_FILE not found. This script is for upgrading an existing deployment."
fi

if docker compose version >/dev/null 2>&1; then
    COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE=(docker-compose)
else
    fail "Docker Compose not found. Install docker compose or docker-compose first."
fi

log "Project: $PROJECT_ROOT"
log "Compose: ${COMPOSE[*]}"
log "Current revision: $(git rev-parse --short HEAD)"

if [ "$DO_BACKUP" -eq 1 ]; then
    timestamp="$(date +%F-%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    cp "$ENV_FILE" "$BACKUP_DIR/backend_api_python.env.$timestamp.bak"
    ok "Backed up backend_api_python/.env"

    if [ -f "$ROOT_ENV_FILE" ]; then
        cp "$ROOT_ENV_FILE" "$BACKUP_DIR/root.env.$timestamp.bak"
        ok "Backed up project-root .env"
    fi
fi

if [ "$SKIP_GIT" -eq 0 ]; then
    if ! git diff --quiet || ! git diff --cached --quiet; then
        git status --short
        fail "Tracked local changes detected. Commit, stash, or discard them before upgrading."
    fi

    log "Pulling latest code"
    run git pull --ff-only
    ok "Code updated to revision $(git rev-parse --short HEAD)"
else
    warn "Skipping git pull"
fi

log "Checking new env keys"
missing_keys="$(awk -F= '/^[A-Za-z_][A-Za-z0-9_]*=/{print $1}' backend_api_python/env.example | while read -r key; do grep -q "^${key}=" "$ENV_FILE" || printf '%s\n' "$key"; done)"
if [ -n "$missing_keys" ]; then
    warn "New keys found in env.example but missing from backend_api_python/.env:"
    printf '%s\n' "$missing_keys" | sed 's/^/  - /'
    warn "Add them manually if the upgraded version requires them. The .env file was not overwritten."
else
    ok "No missing backend .env keys detected"
fi

log "Rebuilding and restarting containers"
run "${COMPOSE[@]}" up -d --build

log "Container status"
"${COMPOSE[@]}" ps

log "Health check"
if curl -fsS http://127.0.0.1:8888/health >/dev/null 2>&1; then
    ok "Frontend health check passed: http://127.0.0.1:8888/health"
else
    warn "Frontend health check failed. Check logs with: ${COMPOSE[*]} logs -f --tail=100 backend frontend"
fi

ok "Upgrade completed"
printf '\nUseful commands:\n'
printf '  %s logs -f --tail=100 backend frontend\n' "${COMPOSE[*]}"
printf '  %s ps\n' "${COMPOSE[*]}"
