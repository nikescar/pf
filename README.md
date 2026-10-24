# OpenBSD PF with Firehol Blocklist

Adaptive firewall with automatic threat IP blocking (45K+ IPs) and optional security rules. All scripts use RFC 5424 syslog-style output and maintain single backup files.

## Quick Start

```bash
# 1. Configure interfaces and security rules
cp .env.example .env
vi .env  # Edit PF_ISP_INTERFACE, PF_LAN_INTERFACE, enable security rules

# 2. Generate and apply config (auto-applies when run as root)
doas ./generate-pfconf.sh

# 3. Verify
doas pfctl -sr | head -20
doas pfctl -t blocklist -T show | wc -l
```

## Configuration (.env)

- **PF_OUTPUT_FILE** - Generated config path (default: `/etc/pf.conf`)
- **PF_ISP_INTERFACE** - WAN interface (e.g., `ure0`, `em0`)
- **PF_LAN_INTERFACE** - LAN interface (e.g., `ure1`, `em1`)
- **PF_LAN_ENABLED** - `1` for router mode, `0` for single interface
- **PF_CONNLIMIT_PER_IP** - Max connections per IP (0=disabled)
- **PF_DROP_INVALID_STATE** - Drop malformed packets (1=enabled)
- **PF_GUARD_UDP_FLOOD** - Rate limit UDP (1=enabled)
- **PF_GUARD_PORT_SCANNER** - Block port scanners (1=enabled)
- **PF_BLOCKLIST_MODE** - Blocklist mode: `ip` (default) or `asn`
  - `ip`: Block individual IPs, auto-aggregate to /24 if >100k entries
  - `asn`: Convert IPs to ASN network ranges (slower, larger coverage)

See `.env.example` for all options.

## Blocklist Updates

### Automated (Recommended)

GitHub CI regenerates blocklist weekly (Sunday 2am UTC):

```bash
# On OpenBSD: pull and apply latest blocklist
doas ./apply-blocklist.sh

# Preview changes without applying
doas ./apply-blocklist.sh --dry-run

# Force reapply even if unchanged
doas ./apply-blocklist.sh --force
```

**Cron setup** (weekly check):
```bash
crontab -e
# Add: 0 3 * * 1 cd /path/to/pf && doas ./apply-blocklist.sh
```

### Manual Regeneration

For local processing (slow, use only if needed):

```bash
./update-blocklist.sh  # Regenerates from source IPs (~5-10 min)
```

GitHub workflow can also be triggered manually via Actions → "Update Blocklist" → "Run workflow".

## Verification

Check if blocklist is active:

```bash
# Show blocklist entry count
doas pfctl -t blocklist -T show | wc -l

# Show first 10 blocked entries
doas pfctl -t blocklist -T show | head -10

# Verify blocklist in active rules
doas pfctl -sr | grep blocklist

# Table statistics
doas pfctl -vvsTables | grep -A5 blocklist
```

## Files

- `.env` - Configuration (copy from `.env.example`)
- `pf.conf.template` - Master template
- `generate-pfconf.sh` - Config generator with auto-apply
- `apply-blocklist.sh` - Pull pre-generated blocklist (fast)
- `update-blocklist.sh` - Regenerate blocklist locally (slow)
- `install-pktstat-logger.sh` - Optional network traffic logger

## Backups

All scripts maintain single backup files (no timestamps):
- `/etc/pf.conf.bak` - Last PF config backup
- `blocklist.bak` - Last blocklist backup
- `blocklist.info.txt.bak` - Last blocklist metadata backup
