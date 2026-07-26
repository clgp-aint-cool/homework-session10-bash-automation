#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# health-check.sh
# Kiểm tra sức khỏe của host (disk, RAM, services, web endpoint) và gửi
# đúng MỘT email cảnh báo nếu có vấn đề. Host khỏe mạnh -> im lặng, exit 0.
# ---------------------------------------------------------------------------

CONFIG_FILE="/etc/monitoring.env"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: config file not found: $CONFIG_FILE" >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"

#   ALERT_TO, DISK_THRESHOLD, RAM_MIN_FREE, SERVICES, HEALTH_URL
: "${ALERT_TO:?ALERT_TO not set in $CONFIG_FILE}"
: "${DISK_THRESHOLD:?DISK_THRESHOLD not set in $CONFIG_FILE}"
: "${RAM_MIN_FREE:?RAM_MIN_FREE not set in $CONFIG_FILE}"
: "${SERVICES:?SERVICES not set in $CONFIG_FILE}"
: "${HEALTH_URL:?HEALTH_URL not set in $CONFIG_FILE}"

HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname)"
ALERTS=()

# ---------------------------------------------------------------------------
# send_alert(): gửi email duy nhất chứa toàn bộ danh sách findings
# ---------------------------------------------------------------------------
send_alert() {
    local subject="ALERT: ${HOSTNAME_FQDN} - health-check found ${#ALERTS[@]} issue(s)"
    local body
    body="Health-check report for host: ${HOSTNAME_FQDN}"
    body+=$'\n'"Timestamp: $(date -Iseconds)"
    body+=$'\n\n'"Issues found:"
    for finding in "${ALERTS[@]}"; do
        body+=$'\n'"  - ${finding}"
    done

    echo "$body" | mail -s "$subject" "$ALERT_TO"
}

# ---------------------------------------------------------------------------
# 1. Disk usage check (root filesystem, % used)
# ---------------------------------------------------------------------------
check_disk() {
    local disk_used
    disk_used="$(df -P / | awk 'NR==2 {gsub("%","",$5); print $5}')"

    if (( disk_used >= DISK_THRESHOLD )); then
        ALERTS+=("Disk usage on / is ${disk_used}% (threshold: ${DISK_THRESHOLD}%)")
    fi
}

# ---------------------------------------------------------------------------
# 2. RAM check (% free, must stay >= RAM_MIN_FREE)
# ---------------------------------------------------------------------------
check_ram() {
    local total_kb avail_kb free_pct
    total_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
    avail_kb="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"

    if [[ -z "$total_kb" || -z "$avail_kb" || "$total_kb" -eq 0 ]]; then
        ALERTS+=("Unable to read memory info from /proc/meminfo")
        return
    fi

    free_pct=$(( avail_kb * 100 / total_kb ))

    if (( free_pct < RAM_MIN_FREE )); then
        ALERTS+=("Free RAM is ${free_pct}% (minimum required: ${RAM_MIN_FREE}%)")
    fi
}

# ---------------------------------------------------------------------------
# 3. Services check (systemctl is-active for each unit in $SERVICES)
# ---------------------------------------------------------------------------
check_services() {
    local svc status
    for svc in $SERVICES; do
        status="$(systemctl is-active "$svc" 2>/dev/null || true)"
        if [[ "$status" != "active" ]]; then
            ALERTS+=("Service '${svc}' is not active (status: ${status:-unknown})")
        fi
    done
}

# ---------------------------------------------------------------------------
# 4. Web endpoint liveness check
# ---------------------------------------------------------------------------
check_web_endpoint() {
    if ! curl -sf --max-time 5 "$HEALTH_URL" > /dev/null; then
        ALERTS+=("Web endpoint unreachable: ${HEALTH_URL}")
    fi
}
    
    
check_disk
check_ram
check_services
check_web_endpoint

if (( ${#ALERTS[@]} > 0 )); then
    send_alert
    exit 1
fi

exit 0
