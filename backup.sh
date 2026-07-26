#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# backup.sh
# Tar+gzip DATA_DIR (with a checksum manifest), ship it to DEST, rotate old
# copies, and never leave a half-finished backup at the destination.
# ---------------------------------------------------------------------------

CONFIG_FILE="/etc/backup.env"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: config file not found: $CONFIG_FILE" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

: "${DATA_DIR:?DATA_DIR not set in $CONFIG_FILE}"
: "${ALERT_TO:?ALERT_TO not set in $CONFIG_FILE}"
: "${DEST:?DEST not set in $CONFIG_FILE}"
: "${RETAIN_DAYS:?RETAIN_DAYS not set in $CONFIG_FILE}"

HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname)"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE_NAME="backup-${HOSTNAME_FQDN}-${TIMESTAMP}.tar.gz"

TMP_DIR="$(mktemp -d)"
STATUS=0
ERROR_ALREADY_REPORTED=0



on_error() {
    local lineno="$1"
    local failed_command="$2"
    local exit_code=$?

    ERROR_ALREADY_REPORTED=1

    {
        echo "Host: ${HOSTNAME_FQDN}"
        echo "Timestamp: $(date -Iseconds)"
        echo "Script: $0"
        echo "Line: ${lineno}"
        echo "Command: ${failed_command}"
        echo "Exit code: ${exit_code}"
    } | mail -s "SCRIPT ERROR: ${HOSTNAME_FQDN} - $0 failed at line ${lineno}" "$ALERT_TO" || true
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
# ---------------------------------------------------------------------------
# cleanup(): always removes the temp dir; on non-zero exit, emails failure.
# Registered with `trap ... EXIT` so it fires on any exit path, including
# `set -e` aborting the script early.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2317
cleanup() {
    STATUS=$?

    if (( STATUS != 0 ))&& (( ERROR_ALREADY_REPORTED != 1 )); then
        {
            echo "Host: ${HOSTNAME_FQDN}"
            echo "Timestamp: $(date -Iseconds)"
            echo "Exit code: ${STATUS}"
            echo
            echo "backup.sh failed before completing. No new archive was left"
            echo "in a half-finished state at the destination."
        } | mail -s "BACKUP FAILED: ${HOSTNAME_FQDN}" "$ALERT_TO" || true
    fi

    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Sanity check DATA_DIR exists before doing any work
# ---------------------------------------------------------------------------
if [[ ! -d "$DATA_DIR" ]]; then
    echo "ERROR: DATA_DIR does not exist: $DATA_DIR" >&2
    exit 1
fi

DATA_DIR_ABS="$(cd "$DATA_DIR" && pwd)"
DATA_PARENT="$(dirname "$DATA_DIR_ABS")"
DATA_BASENAME="$(basename "$DATA_DIR_ABS")"

# ---------------------------------------------------------------------------
# 1. Build the manifest (checksum of every file that will be archived)
#    Excludes match the tar excludes below so the manifest stays consistent
#    with what actually ends up in the archive.
# ---------------------------------------------------------------------------
(
    cd "$DATA_DIR_ABS"
    find . -type f \
        ! -name '*.log' \
        ! -name '*.tmp' \
        -exec md5sum {} +
) > "$TMP_DIR/manifest.txt"

# ---------------------------------------------------------------------------
# 2. Archive: data dir + manifest.txt, excluding *.log / *.tmp
# ---------------------------------------------------------------------------
ARCHIVE_PATH="${TMP_DIR}/${ARCHIVE_NAME}"

tar -czf "$ARCHIVE_PATH" \
    --exclude='*.log' \
    --exclude='*.tmp' \
    -C "$TMP_DIR" manifest.txt \
    -C "$DATA_PARENT" "$DATA_BASENAME"

ARCHIVE_SIZE="$(du -h "$ARCHIVE_PATH" | cut -f1)"

# ---------------------------------------------------------------------------
# 3. Ship the archive to DEST. Supports:
#      - local directory:      /srv/backup-target
#      - remote host:          user@host:/path/to/dir
# ---------------------------------------------------------------------------
if [[ "$DEST" == *:* ]]; then
    # shellcheck disable=SC2029
    REMOTE_HOST="${DEST%%:*}"
    # shellcheck disable=SC2029
    REMOTE_PATH="${DEST#*:}"
    rsync -az "$ARCHIVE_PATH" "$DEST/"
else
    mkdir -p "$DEST"
    rsync -az "$ARCHIVE_PATH" "$DEST/"
fi

# ---------------------------------------------------------------------------
# 4. Rotate: delete archives older than RETAIN_DAYS at the destination
# ---------------------------------------------------------------------------
if [[ "$DEST" == *:* ]]; then
    # shellcheck disable=SC2029	
    ssh "$REMOTE_HOST" "find '${REMOTE_PATH}' -maxdepth 1 -name 'backup-*.tar.gz' -mtime +${RETAIN_DAYS} -delete"
else
    find "$DEST" -maxdepth 1 -name 'backup-*.tar.gz' -mtime "+${RETAIN_DAYS}" -delete
fi

# ---------------------------------------------------------------------------
# 5. Success report
# ---------------------------------------------------------------------------
{
    echo "Host: ${HOSTNAME_FQDN}"
    echo "Timestamp: $(date -Iseconds)"
    echo "Archive: ${ARCHIVE_NAME}"
    echo "Size: ${ARCHIVE_SIZE}"
    echo "Destination: ${DEST}"
    echo "Retention: ${RETAIN_DAYS} days"
} | mail -s "Backup OK: ${HOSTNAME_FQDN}" "$ALERT_TO"

echo "Backup complete: ${ARCHIVE_NAME} (${ARCHIVE_SIZE}) -> ${DEST}"

exit 0
