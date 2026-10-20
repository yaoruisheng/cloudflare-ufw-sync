#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

TAG_A="CF-IP-SYNC-A"
TAG_B="CF-IP-SYNC-B"
LOCK="/run/cf-ip-sync.lock"

# 1. Check prerequisites
if [[ $EUID -ne 0 ]]; then
    echo "Error: Run this script as root." >&2
    exit 1
fi

for cmd in curl ufw flock grep awk sort mktemp; do
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

# 3. Create temporary directory
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 4. Read existing rules and detect tags
if ! ufw status numbered > "$TMP/status"; then
    echo "Error: Failed to read UFW rules." >&2
    exit 1
fi

HAS_A=0
HAS_B=0

grep -Fq -- "$TAG_A" "$TMP/status" && HAS_A=1 || true
grep -Fq -- "$TAG_B" "$TMP/status" && HAS_B=1 || true

# 5. Determine old and new tags
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

# 6. Download official Cloudflare IPv4 and IPv6 ranges
fetch_list() {
    local URL="$1"
    local OUT="$2"

    if ! curl -fsSL \
        --connect-timeout 10 \
        --max-time 60 \
        --retry 3 \
        --retry-delay 2 \
        --retry-connrefused \
        "$URL" -o "$OUT"; then
        echo "Error: Download failed: $URL" >&2
        return 1
    fi

    if [[ ! -s "$OUT" ]]; then
        echo "Error: Empty response: $URL" >&2
        return 1
    fi

    return 0
}

fetch_list "https://www.cloudflare.com/ips-v4" "$TMP/ips-v4"
fetch_list "https://www.cloudflare.com/ips-v6" "$TMP/ips-v6"

# Ensure a newline separates the two lists
{
    cat "$TMP/ips-v4"
    printf '\n'
    cat "$TMP/ips-v6"
    printf '\n'
} | sort -u > "$TMP/ip-list"

if [[ ! -s "$TMP/ip-list" ]]; then
    echo "Error: Combined IP list is empty." >&2
    exit 1
fi

# 7. Add rules with the new tag
ADD_FAILED=0

while IFS= read -r IP || [[ -n "$IP" ]]; do
    [[ -z "$IP" ]] && continue

    if ! ufw allow proto tcp from "$IP" to any \
        comment "$NEW_TAG"; then
        echo "Error: Failed to add rule for $IP" >&2
        ADD_FAILED=1
    fi
done < "$TMP/ip-list"

# Stop cleanup if any rule addition fails
if (( ADD_FAILED != 0 )); then
    echo "Error: Rule addition failed. Existing rules may have been updated." >&2
    exit 1
fi

echo "All new rule commands succeeded."

# 8. Read rules again
if ! ufw status numbered > "$TMP/status"; then
    echo "Error: Failed to read UFW rules after adding." >&2
    exit 1
fi

# 9. Extract old-tag rule numbers in descending order
awk -v tag="$OLD_TAG" '
    index($0, tag) {
        if (match($0, /^\[[[:space:]]*[0-9]+\]/)) {
            n = substr($0, RSTART, RLENGTH)
            gsub(/[^0-9]/, "", n)
            print n
        }
    }
' "$TMP/status" |
    sort -rn > "$TMP/delete-list"

# 10. Delete old rules in descending order
DEL_FAILED=0

while IFS= read -r NUM; do
    [[ -z "$NUM" ]] && continue

    if ! ufw --force delete "$NUM"; then
        echo "Warning: Failed to delete old rule number $NUM" >&2
        DEL_FAILED=1
    fi
done < "$TMP/delete-list"

# 11. Report the result
if (( DEL_FAILED != 0 )); then
    echo "Warning: Some old rules remain. A later run can retry." >&2
    exit 1
fi

echo "Cloudflare IP sync completed."
echo "Active tag: $NEW_TAG"
