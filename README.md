# Cloudflare UFW Sync

Automatically synchronize Cloudflare's official IPv4 and IPv6 ranges with UFW TCP allow rules.

## Features

- Fetches IPv4 and IPv6 ranges from Cloudflare's official endpoints.
- Allows TCP traffic from Cloudflare IP ranges without restricting destination ports.
- Uses alternating rule tags (`CF-IP-SYNC-A` and `CF-IP-SYNC-B`) to manage updates.
- Removes obsolete rules after all new rule commands succeed.
- Preserves unrelated UFW rules.
- Uses a file lock to prevent concurrent executions.
- Supports automatic retries for failed downloads.
- Requires no additional software beyond standard Linux utilities, `curl`, and UFW.

## Requirements

- Linux with UFW enabled
- Bash
- `curl`
- `flock`
- Standard utilities: `grep`, `awk`, `sort`, and `mktemp`
- Root privileges

## Installation

Download the script and save it as:

```text
/usr/local/sbin/cf-ip-sync.sh
```

Make it executable:

```bash
chmod +x /usr/local/sbin/cf-ip-sync.sh
```

Run the script as root:

```bash
/usr/local/sbin/cf-ip-sync.sh
```

## Cloudflare IP Sources

The script retrieves the official IP ranges from:

- IPv4: https://www.cloudflare.com/ips-v4
- IPv6: https://www.cloudflare.com/ips-v6

The ranges are combined, deduplicated, and applied to UFW.

## How It Works

1. Checks prerequisites and acquires an execution lock.
2. Detects existing synchronization tags.
3. Downloads the official IPv4 and IPv6 lists.
4. Adds or updates rules using the alternate tag.
5. Stops cleanup if any rule addition command fails.
6. Removes obsolete rules associated with the previous tag, in descending rule-number order.
7. Reports the result.

The script uses two tags:

- `CF-IP-SYNC-A`
- `CF-IP-SYNC-B`

Rules without these tags are not intentionally removed by the cleanup process.

## Scheduling

To run the script daily at 04:00, create a cron entry:

```cron
0 4 * * * /usr/local/sbin/cf-ip-sync.sh >> /var/log/cf-ip-sync.log 2>&1
```

Edit the root user's crontab with:

```bash
crontab -e
```

## Important Notes

- The script manages TCP allow rules without restricting destination ports.
- It does not validate the format or count of downloaded CIDR entries.
- If a download fails, a response is empty, or a rule addition command fails, cleanup is skipped.
- UFW may update the comment of an existing matching rule instead of creating a separate rule. Therefore, a failed update can leave some existing rules with changed tags.
- Rule deletion failures are reported, and remaining old rules can be retried on a later run.
- This script does not replace a firewall backup or a review of your UFW configuration.
