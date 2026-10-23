# OpenBSD PF with Firehol Blacklist

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
pfctl -t blacklist -T show | wc -l
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

See `.env.example` for all options.

## Weekly Auto-Update

```bash
crontab -e
# Add: 0 3 * * 0 /path/to/update-blocklist.sh > /tmp/pf-update.log 2>&1
```

## Files

- `.env` - Configuration (copy from `.env.example`)
- `pf.conf.template` - Master template
- `gen-pf-conf.sh` - Config generator
- `update-blocklist.sh` - Blocklist updater
