#!/usr/bin/env bash
# Update production Kitsu:
#   1. Build a fresh image from ./repo, tagged with today's date
#   2. Optionally rebuild the git-importer image (./kitsu-git-importer)
#   3. Back up the database first (uses backup_prod.sh)
#   4. Point docker-compose.yaml at the new image(s)
#   5. Recreate the containers (zou upgrade-db runs automatically on start)
#
# Interactive by default; --yes answers all prompts with their default,
# --skip-backup skips the backup step.
#
# Run from your kitsu deploy dir (the one containing docker-compose.yaml,
# repo/ and backups/):
#   cd ~/kitsu && ./repo/scripts/update_prod.sh [--yes] [--skip-backup]

set -euo pipefail

IMAGE_NAME="${IMAGE_NAME:-xp-kitsu}"
IMPORTER_IMAGE_NAME="${IMPORTER_IMAGE_NAME:-xp-kitsu-git-importer}"
REPO_DIR="${REPO_DIR:-$PWD/repo}"
IMPORTER_DIR="${IMPORTER_DIR:-$PWD/kitsu-git-importer}"
COMPOSE_FILE="${COMPOSE_FILE:-$PWD/docker-compose.yaml}"
TAG="$(date +%F)"

ASSUME_YES=0
SKIP_BACKUP=0
for arg in "$@"; do
    case "$arg" in
        --yes)         ASSUME_YES=1 ;;
        --skip-backup) SKIP_BACKUP=1 ;;
        *) echo "Usage: $0 [--yes] [--skip-backup]" >&2; exit 1 ;;
    esac
done

# confirm "question" [default y|n] - returns 0 for yes.
# Non-interactive (no TTY or --yes) takes the default.
confirm() {
    local prompt="$1" def="${2:-y}" ans hint
    if [[ "$ASSUME_YES" -eq 1 || ! -t 0 ]]; then
        [[ "$def" == "y" ]]
        return
    fi
    if [[ "$def" == "y" ]]; then hint="[Y/n]"; else hint="[y/N]"; fi
    read -r -p "$prompt $hint " ans
    ans="${ans:-$def}"
    [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

if [[ ! -f "$COMPOSE_FILE" ]]; then
    echo "ERROR: $COMPOSE_FILE not found - run this from the kitsu deploy dir" >&2
    exit 1
fi
if [[ ! -f "$REPO_DIR/Dockerfile" ]]; then
    echo "ERROR: no Dockerfile in $REPO_DIR" >&2
    exit 1
fi

BUILD_IMPORTER=0
if [[ -f "$IMPORTER_DIR/Dockerfile" ]]; then
    if confirm "Also rebuild $IMPORTER_IMAGE_NAME from $IMPORTER_DIR?" y; then
        BUILD_IMPORTER=1
    fi
fi

echo
echo "Update plan:"
echo "  - build $IMAGE_NAME:$TAG from $REPO_DIR"
[[ "$BUILD_IMPORTER" -eq 1 ]] && echo "  - build $IMPORTER_IMAGE_NAME:$TAG from $IMPORTER_DIR"
[[ "$SKIP_BACKUP" -eq 0 ]] && echo "  - back up the database before switching"
echo "  - retag image(s) in $COMPOSE_FILE and recreate containers"
echo
confirm "Proceed?" y || { echo "Aborted."; exit 1; }

echo "==> Building $IMAGE_NAME:$TAG"
docker build -t "$IMAGE_NAME:$TAG" "$REPO_DIR"

if [[ "$BUILD_IMPORTER" -eq 1 ]]; then
    echo "==> Building $IMPORTER_IMAGE_NAME:$TAG"
    docker build -t "$IMPORTER_IMAGE_NAME:$TAG" "$IMPORTER_DIR"
fi

if [[ "$SKIP_BACKUP" -eq 0 ]]; then
    if confirm "Back up the database before switching?" y; then
        echo "==> Backing up database"
        if [[ "$ASSUME_YES" -eq 1 ]]; then
            "$REPO_DIR/scripts/backup_prod.sh" --stop
        else
            "$REPO_DIR/scripts/backup_prod.sh"
        fi
    fi
fi

echo "==> Updating image tag(s) in $COMPOSE_FILE"
# The ':' right after the name keeps xp-kitsu: from matching xp-kitsu-git-importer:
sed -i -E "s|(image:[[:space:]]*['\"]?)$IMAGE_NAME:[^'\"]*|\1$IMAGE_NAME:$TAG|" "$COMPOSE_FILE"
if [[ "$BUILD_IMPORTER" -eq 1 ]]; then
    sed -i -E "s|(image:[[:space:]]*['\"]?)$IMPORTER_IMAGE_NAME:[^'\"]*|\1$IMPORTER_IMAGE_NAME:$TAG|" "$COMPOSE_FILE"
fi
grep -n "image:" "$COMPOSE_FILE"

confirm "Recreate containers with the new image(s) now?" y || {
    echo "Compose file updated but containers NOT recreated."
    echo "Run 'docker compose up -d' when ready."
    exit 0
}

echo "==> Recreating containers"
docker compose -f "$COMPOSE_FILE" up -d

echo "==> Done - now running $IMAGE_NAME:$TAG"
docker compose -f "$COMPOSE_FILE" ps
