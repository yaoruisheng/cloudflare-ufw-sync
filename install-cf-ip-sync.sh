#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

# One-click installer for Cloudflare IP synchronization via UFW.
# Creates:
#   /usr/local/sbin/cf-ip-sync.sh
#   /etc/systemd/system/cf-ip-sync.service
#   /etc/systemd/system/cf-ip-sync.timer

SYNC_SCRIPT="/usr/local/sbin/cf-ip-sync.sh"
SERVICE="/etc/systemd/system/cf-ip-sync.service"
TIMER="/etc/systemd/system/cf-ip-sync.timer"

if [[ $EUID -ne 0 ]]; then
    echo "Error: Run this installer as root." >&2
    exit 1
fi

for cmd in apt-get systemctl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: Missing command: $cmd" >&2
        exit 1
    fi
done

# Install jq if it is not already available.
if ! command -v jq >/dev/null 2>&1; then
    echo "Installing jq..."
    apt-get update
    apt-get install -y jq
fi

for cmd in curl ufw flock grep awk sort mktemp jq cmp install; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: Missing command: $cmd" >&2
        exit 1
    fi
done

if ! systemctl is-system-running >/dev/null 2>&1; then
    echo "Error: systemd is not running normally." >&2
    exit 1
fi

# Create the Cloudflare IP synchronization script.
cat > "$SYNC_SCRIPT" <<'SYNC_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

TAG_A="CF-IP-SYNC-A"
TAG_B="CF-IP-SYNC-B"
LOCK="/run/cf-ip-sync.lock"
ETAG_FILE="/var/lib/cf-ip-sync/etag"
API_URL="https://api.cloudflare.com/client/v4/ips"

# 1. Check prerequisites
if [[ $EUID -ne 0 ]]; then
    echo "Error: Run this script as root." >&2
    exit 1
fi

for cmd in curl ufw flock grep awk sort mktemp jq cmp install; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: Missing command: $cmd" >&2
        exit 1
    fi
done

# 2. Acquire execution lock
exec 9>"$LOCK"

if ! flock -n 9; then
    echo "Another sync process is running. Exiting." >&2
    exit 1
fi

# 3. Create temporary working directory
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# 4. Check UFW status
if ! ufw status | grep -Fq "Status: active"; then
    echo "Error: UFW is not active." >&2
    exit 1
fi

# 5. Fetch Cloudflare IP ranges through the official API
API_FILE="$WORKDIR/api.json"
NEW_IP_LIST="$WORKDIR/ip-list"

if ! curl -fsSL \
    --connect-timeout 10 \
    --max-time 60 \
    --retry 3 \
    --retry-delay 2 \
    --retry-connrefused \
    "$API_URL" -o "$API_FILE"; then
    echo "Error: Failed to download Cloudflare API response." >&2
    exit 1
fi

# Validate the API response and extract the ETag
if ! jq -e '
    .success == true and
    (.errors | type == "array" and length == 0) and
    (.result.etag | type == "string" and length > 0) and
    (.result.ipv4_cidrs |
        type == "array" and length > 0 and all(.[]; type == "string")) and
    (.result.ipv6_cidrs |
        type == "array" and length > 0 and all(.[]; type == "string"))
' "$API_FILE" >/dev/null; then
    echo "Error: Invalid Cloudflare API response." >&2
    exit 1
fi

NEW_ETAG="$(jq -er '.result.etag' "$API_FILE")"

# 6. Compare with the previously saved ETag
if [[ -f "$ETAG_FILE" ]] &&
   [[ "$(cat "$ETAG_FILE")" == "$NEW_ETAG" ]]; then
    echo "Cloudflare IP list unchanged. Exiting."
    exit 0
fi

echo "Cloudflare IP list changed. Starting UFW sync."

# 7. Generate the complete IP list, one CIDR per line
if ! jq -r '.result.ipv4_cidrs[], .result.ipv6_cidrs[]' \
    "$API_FILE" | sort -u > "$NEW_IP_LIST"; then
    echo "Error: Failed to generate IP list." >&2
    exit 1
fi

if [[ ! -s "$NEW_IP_LIST" ]]; then
    echo "Error: Cloudflare IP list is empty." >&2
    exit 1
fi

# 8. Read existing rules and detect tags
if ! ufw status numbered > "$WORKDIR/status"; then
    echo "Error: Failed to read UFW rules." >&2
    exit 1
fi

HAS_A=0
HAS_B=0

grep -Fq -- "$TAG_A" "$WORKDIR/status" && HAS_A=1 || true
grep -Fq -- "$TAG_B" "$WORKDIR/status" && HAS_B=1 || true

# 9. Determine old and new tags
if (( HAS_A == 1 && HAS_B == 1 )); then
    OLD_TAG="$TAG_A"
    NEW_TAG="$TAG_B"
elif (( HAS_A == 1 )); then
    OLD_TAG="$TAG_A"
    NEW_TAG="$TAG_B"
else
    OLD_TAG="$TAG_B"
    NEW_TAG="$TAG_A"
fi

echo "Old tag: $OLD_TAG"
echo "New tag: $NEW_TAG"

# 10. Add rules with the new tag
ADD_FAILED=0

while IFS= read -r IP || [[ -n "$IP" ]]; do
    [[ -z "$IP" ]] && continue

    if ! ufw allow proto tcp from "$IP" to any comment "$NEW_TAG"; then
        echo "Error: Failed to add rule for $IP" >&2
        ADD_FAILED=1
    fi
done < "$NEW_IP_LIST"

if (( ADD_FAILED != 0 )); then
    echo "Error: Rule addition failed. Existing rules may have been updated." >&2
    exit 1
fi

echo "All new rule commands succeeded."

# 11. Read rules again
if ! ufw status numbered > "$WORKDIR/status"; then
    echo "Error: Failed to read UFW rules after adding." >&2
    exit 1
fi

# 12. Extract old-tag rule numbers in descending order
awk -v tag="$OLD_TAG" '
    index($0, tag) {
        if (match($0, /^\[[[:space:]]*[0-9]+\]/)) {
            n = substr($0, RSTART, RLENGTH)
            gsub(/[^0-9]/, "", n)
            print n
        }
    }
' "$WORKDIR/status" | sort -rn > "$WORKDIR/delete-list"

# 13. Delete old rules in descending order
DEL_FAILED=0

while IFS= read -r NUM; do
    [[ -z "$NUM" ]] && continue

    if ! ufw --force delete "$NUM"; then
        echo "Warning: Failed to delete old rule number $NUM" >&2
        DEL_FAILED=1
    fi
done < "$WORKDIR/delete-list"

if (( DEL_FAILED != 0 )); then
    echo "Warning: Some old rules remain. ETag not updated." >&2
    exit 1
fi

# 14. Save the ETag only after successful synchronization
install -d -m 755 "$(dirname "$ETAG_FILE")"

if ! printf '%s\n' "$NEW_ETAG" > "$WORKDIR/etag.new" ||
   ! install -m 644 "$WORKDIR/etag.new" "$ETAG_FILE"; then
    echo "Error: Failed to save ETag. A later run can retry." >&2
    exit 1
fi

echo "Cloudflare IP sync completed."
echo "Active tag: $NEW_TAG"
echo "ETag updated."
SYNC_EOF

chmod 755 "$SYNC_SCRIPT"

# Create the systemd service.
cat > "$SERVICE" <<'SERVICE_EOF'
[Unit]
Description=Cloudflare IP ranges UFW synchronization
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/cf-ip-sync.sh
SERVICE_EOF

# Create the daily timer.
cat > "$TIMER" <<'TIMER_EOF'
[Unit]
Description=Daily Cloudflare IP synchronization

[Timer]
OnCalendar=*-*-* 04:20:00
Persistent=true
Unit=cf-ip-sync.service

[Install]
WantedBy=timers.target
TIMER_EOF

systemctl daemon-reload
systemctl enable --now cf-ip-sync.timer

echo
echo "Cloudflare IP sync script and timer installed."
echo "Script:   $SYNC_SCRIPT"
echo "Schedule: Daily at 04:20 server local time."
echo
systemctl list-timers cf-ip-sync.timer --no-pager
echo
echo "To run now: systemctl start cf-ip-sync.service"
echo "Logs:       journalctl -u cf-ip-sync.service -n 50 --no-pager"
echo
echo "The installer enables the timer but does not run the sync immediately."
