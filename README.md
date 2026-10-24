# OpenBSD PF with Firehol Blocklist

Adaptive firewall with automatic threat IP blocking (45K+ IPs) and optional security rules.

## Quick Start

```bash
# 1. Configure interfaces and security rules
cp .env.example .env
vi .env  # Edit PF_ISP_INTERFACE, PF_LAN_INTERFACE, enable security rules

# 2. Generate and apply config
./gen-pf-conf.sh
pfctl -f /etc/pf.conf

# 3. Verify
pfctl -sr | head -20
pfctl -t blocklist -T show | wc -l
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
./apply-blocklist.sh --dry-run

# Pull but don't reload PF
./apply-blocklist.sh --check-only
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

## Files

- `.env` - Configuration (copy from `.env.example`)
- `pf.conf.template` - Master template
- `gen-pf-conf.sh` - Config generator
- `apply-blocklist.sh` - Pull pre-generated blocklist (fast)
- `update-blocklist.sh` - Regenerate blocklist locally (slow)
