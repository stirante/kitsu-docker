#!/usr/bin/env bash
# Backup production Kitsu database:
#   1. Logical dump  -> kitsu-db-YYYY-MM-DD.sql        (pg_dump, safe while running)
#   2. Raw data copy -> kitsu-prod-db-YYYY-MM-DD.tar.gz (tar of /var/lib/postgresql volume)
#
# For the tar step the container should be stopped so the raw copy is
# consistent. When run interactively the script asks; from cron (no TTY)
# it stops by default. Force either way with --stop / --no-stop
# (--no-stop = no downtime, but the raw copy may not be restorable alone).
#
# Backups go to ./backups relative to the current working directory
# (override with BACKUP_DIR), so run it from your kitsu deploy dir:
#   cd ~/kitsu && ./repo/scripts/backup_prod.sh [--stop|--no-stop]

set -euo pipefail

CONTAINER="${CONTAINER:-kitsu-cgwire-1}"
BACKUP_DIR="${BACKUP_DIR:-$PWD/backups}"
DB_NAME="${DB_NAME:-zoudb}"
DB_USER="${DB_USER:-root}"
DATE="$(date +%F)"

SQL_FILE="$BACKUP_DIR/kitsu-db-$DATE.sql"
TAR_FILE="$BACKUP_DIR/kitsu-prod-db-$DATE.tar.gz"

case "${1:-}" in
    --stop)    STOP_FOR_TAR=1 ;;
    --no-stop) STOP_FOR_TAR=0 ;;
    "")
        STOP_FOR_TAR=1
        if [[ -t 0 ]]; then
            read -r -p "Stop $CONTAINER during the raw copy for a consistent backup? (brief downtime) [Y/n] " ANS
            [[ "${ANS,,}" == "n" || "${ANS,,}" == "no" ]] && STOP_FOR_TAR=0
        fi
        ;;
    *) echo "Usage: $0 [--stop|--no-stop]" >&2; exit 1 ;;
esac

mkdir -p "$BACKUP_DIR"

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
    echo "ERROR: container '$CONTAINER' not found" >&2
    exit 1
fi

echo "==> [1/2] SQL dump of '$DB_NAME' from $CONTAINER"
docker exec "$CONTAINER" pg_dump -h localhost -U "$DB_USER" "$DB_NAME" > "$SQL_FILE.tmp"
mv "$SQL_FILE.tmp" "$SQL_FILE"
echo "    wrote $SQL_FILE ($(du -h "$SQL_FILE" | cut -f1))"

echo "==> [2/2] Raw copy of /var/lib/postgresql volume"
if [[ "$STOP_FOR_TAR" -eq 1 ]]; then
    echo "    stopping $CONTAINER for a consistent copy..."
    docker stop "$CONTAINER" >/dev/null
    trap 'echo "    restarting $CONTAINER..."; docker start "$CONTAINER" >/dev/null' EXIT
fi

docker run --rm \
    --volumes-from "$CONTAINER" \
    -v "$BACKUP_DIR":/backup \
    ubuntu:jammy \
    tar czf "/backup/$(basename "$TAR_FILE")" -C / var/lib/postgresql
echo "    wrote $TAR_FILE ($(du -h "$TAR_FILE" | cut -f1))"

if [[ "$STOP_FOR_TAR" -eq 1 ]]; then
    docker start "$CONTAINER" >/dev/null
    trap - EXIT
    echo "    $CONTAINER restarted"
fi

echo "==> Done"
ls -lh "$SQL_FILE" "$TAR_FILE"
