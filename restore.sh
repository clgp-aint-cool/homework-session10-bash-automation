#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# restore-test.sh
# Extracts the newest archive from DEST into a throwaway directory and
# re-verifies every file against manifest.txt (md5sum -c). Reports how many
# files matched. This is what proves a backup is actually restorable.
# ---------------------------------------------------------------------------

CONFIG_FILE="/etc/backup.env"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: config file not found: $CONFIG_FILE" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

: "${DEST:?DEST not set in $CONFIG_FILE}"

RESTORE_DIR="$(mktemp -d)"
trap 'rm -rf "$RESTORE_DIR"' EXIT

# ---------------------------------------------------------------------------
# 1. Locate the newest archive at DEST (local dir or user@host:/path)
# ---------------------------------------------------------------------------
if [[ "$DEST" == *:* ]]; then
    REMOTE_HOST="${DEST%%:*}"
    REMOTE_PATH="${DEST#*:}"
    LATEST_NAME="$(ssh "$REMOTE_HOST" "cd '${REMOTE_PATH}' && ls -t backup-*.tar.gz 2>/dev/null | head -n1")"

    if [[ -z "$LATEST_NAME" ]]; then
        echo "ERROR: no archives found at ${DEST}" >&2
        exit 1
    fi

    rsync -az "${DEST}/${LATEST_NAME}" "${RESTORE_DIR}/"
    ARCHIVE_PATH="${RESTORE_DIR}/${LATEST_NAME}"
else
    LATEST_NAME="$(cd "$DEST" && ls -t backup-*.tar.gz 2>/dev/null | head -n1)"

    if [[ -z "$LATEST_NAME" ]]; then
        echo "ERROR: no archives found at ${DEST}" >&2
        exit 1
    fi

    ARCHIVE_PATH="${DEST}/${LATEST_NAME}"
fi

echo "Restoring: ${LATEST_NAME}"

# ---------------------------------------------------------------------------
# 2. Extract to the throwaway directory
# ---------------------------------------------------------------------------
EXTRACT_DIR="${RESTORE_DIR}/extracted"
mkdir -p "$EXTRACT_DIR"
tar -xzf "$ARCHIVE_PATH" -C "$EXTRACT_DIR"

if [[ ! -f "${EXTRACT_DIR}/manifest.txt" ]]; then
    echo "ERROR: manifest.txt not found in archive" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 3. Find the extracted data directory (everything except manifest.txt)
# ---------------------------------------------------------------------------
DATA_SUBDIR="$(find "$EXTRACT_DIR" -mindepth 1 -maxdepth 1 -type d | head -n1)"

if [[ -z "$DATA_SUBDIR" ]]; then
    echo "ERROR: no data directory found inside archive" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 4. Verify checksums. Manifest paths are relative (./file) to the data
#    dir root, so md5sum -c must run from inside that same directory.
# ---------------------------------------------------------------------------
echo "Verifying against manifest..."
set +e
CHECK_OUTPUT="$(cd "$DATA_SUBDIR" && md5sum -c "${EXTRACT_DIR}/manifest.txt" 2>&1)"
CHECK_STATUS=$?
set -e

echo "$CHECK_OUTPUT"

TOTAL_FILES="$(echo "$CHECK_OUTPUT" | wc -l)"
OK_FILES="$(echo "$CHECK_OUTPUT" | grep -c ': OK$' || true)"

echo
echo "Restore verification: ${OK_FILES}/${TOTAL_FILES} files matched manifest."

if (( CHECK_STATUS != 0 )); then
    echo "RESULT: FAILED - one or more files did not match the manifest." >&2
    exit 1
fi

echo "RESULT: PASSED - all files verified against manifest."
exit 0
