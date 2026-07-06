#!/usr/bin/env bash
# Restore a Kitsu database backup. Scans the backups dir and lets you pick:
#   *.sql    - logical dump: stops the zou app, drops and recreates the DB,
#              imports the dump, runs zou upgrade-db, restarts the app
#   *.tar.gz - raw data copy: stops the container, wipes and re-extracts the
#              /var/lib/postgresql volume, starts the container
#
# Backups are read from ./backups relative to the current working directory
# (override with BACKUP_DIR), so run it from your kitsu deploy dir:
#   cd ~/kitsu && ./repo/scripts/restore_backup.sh

set -euo pipefail

CONTAINER="${CONTAINER:-kitsu-cgwire-1}"
BACKUP_DIR="${BACKUP_DIR:-$PWD/backups}"
DB_NAME="${DB_NAME:-zoudb}"
DB_USER="${DB_USER:-root}"

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
    echo "ERROR: container '$CONTAINER' not found" >&2
    exit 1
fi

# Collect backups, newest first
mapfile -t FILES < <(ls -1t "$BACKUP_DIR"/*.sql "$BACKUP_DIR"/*.tar.gz 2>/dev/null || true)
if [[ "${#FILES[@]}" -eq 0 ]]; then
    echo "ERROR: no .sql or .tar.gz backups found in $BACKUP_DIR" >&2
    exit 1
fi

echo "Available backups in $BACKUP_DIR (newest first):"
echo
PS3=$'\nSelect a backup to restore (q to quit): '
select CHOICE in "${FILES[@]}"; do
    [[ "${REPLY,,}" == "q" ]] && exit 0
    [[ -n "${CHOICE:-}" ]] && break
    echo "Invalid selection."
done

FILE_NAME="$(basename "$CHOICE")"
case "$FILE_NAME" in
    *.sql)    MODE="sql" ;;
    *.tar.gz) MODE="tar" ;;
    *) echo "ERROR: unrecognized backup type: $FILE_NAME" >&2; exit 1 ;;
esac

echo
echo "About to restore: $FILE_NAME ($(du -h "$CHOICE" | cut -f1))"
if [[ "$MODE" == "sql" ]]; then
    echo "Mode: logical dump - database '$DB_NAME' in $CONTAINER will be DROPPED and re-imported."
else
    echo "Mode: raw data copy - the ENTIRE postgres data volume of $CONTAINER will be wiped and replaced."
fi
read -r -p "This cannot be undone. Type 'yes' to continue: " CONFIRM
[[ "$CONFIRM" == "yes" ]] || { echo "Aborted."; exit 1; }

if [[ "$MODE" == "sql" ]]; then
    echo "==> Stopping zou app processes"
    docker exec "$CONTAINER" supervisorctl -c /etc/supervisord.conf stop 'zou-processes:*'

    echo "==> Dropping and recreating $DB_NAME"
    docker exec "$CONTAINER" dropdb -h localhost -U "$DB_USER" --if-exists "$DB_NAME"
    docker exec "$CONTAINER" createdb -h localhost -U "$DB_USER" -T template0 -E UTF8 --owner "$DB_USER" "$DB_NAME"

    echo "==> Importing $FILE_NAME"
    docker exec -i "$CONTAINER" psql -h localhost -U "$DB_USER" -q -v ON_ERROR_STOP=1 "$DB_NAME" < "$CHOICE"

    echo "==> Running zou upgrade-db (in case the dump predates current schema)"
    docker exec "$CONTAINER" bash -c '. /opt/zou/env/bin/activate && zou upgrade-db'

    echo "==> Restarting zou app processes"
    docker exec "$CONTAINER" supervisorctl -c /etc/supervisord.conf start 'zou-processes:*'
else
    echo "==> Stopping $CONTAINER"
    docker stop "$CONTAINER" >/dev/null

    echo "==> Wiping and re-extracting /var/lib/postgresql volume"
    docker run --rm \
        --volumes-from "$CONTAINER" \
        -v "$BACKUP_DIR":/backup:ro \
        ubuntu:jammy \
        bash -c "rm -rf /var/lib/postgresql/* && tar xzf '/backup/$FILE_NAME' -C /"

    echo "==> Starting $CONTAINER"
    docker start "$CONTAINER" >/dev/null
fi

echo "==> Restore complete"
