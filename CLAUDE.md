# OpenBSD PF Firewall with Adaptive Threat Blocking

## Project Overview

This project provides an adaptive OpenBSD Packet Filter (PF) configuration with automatic threat IP blocking and categorized blocklists. It blocks 45+ threat intelligence sources, monitoring services, security scanners, and web crawlers using separate PF tables per source.

## Architecture

### Core Components

1. **Config Generator** (`generate-pfconf.sh`)
   - Generates `/etc/pf.conf` from `pf.conf.template`
   - Injects conditional sections (LAN mode, security rules)
   - Auto-applies config when run as root

2. **Blocklist Updater** (`update-blocklist.sh`)
   - Downloads threat IPs from 45 categorized sources
   - Supports IP mode (individual IPs) and ASN mode (network ranges)
   - Generates per-source table files in `output/tables/`
   - Creates aggregated `output/blocklist` for backward compatibility

3. **Blocklist Applier** (`apply-blocklist.sh`)
   - Fast GitHub CI pre-generated blocklist download
   - Loads all tables into active PF ruleset
   - Dry-run and force-reapply modes

4. **Network Logger** (`install-pktstat-logger.sh`)
   - Optional pktstat-based connection monitor
   - Daily log rotation with 7-day retention
   - CDN/ASN lookup integration

### Blocking Categories

Providers sourced from [nikescar/cdn-lookup](https://github.com/nikescar/cdn-lookup/blob/main/providers.conf):

| Category | Sources | Block Rule | Purpose |
|----------|---------|------------|---------|
| **Threat Intelligence** | 13 | IN + OUT | Malware, spam, compromised IPs |
| **Monitoring** | 14 | IN only | Uptime checkers, synthetic monitors |
| **Security** | 4 | IN + OUT | WAF/DDoS protection services |
| **Crawlers & Bots** | 13 | IN + OUT | Search engines, AI scrapers |

Each source gets a dedicated PF table: `<category_source>` (e.g., `threat_spamhaus`, `monitor_pingdom`).

### File Structure

```
pf/
├── input/                     # Data sources (git-ignored)
│   ├── ip2asn-v4.tsv         # IP-to-ASN mapping database
│   ├── ip2asn-v4-int.tsv     # Integer-indexed version
│   ├── inbound.txt           # Legacy blocklist (deprecated)
│   └── outbound.txt          # Legacy blocklist (deprecated)
├── output/                    # Generated files (git-ignored)
│   ├── blocklist             # Aggregated blocklist (backward compat)
│   └── tables/               # Per-source PF table files
│       ├── threat_asndrop.txt
│       ├── monitor_pingdom.txt
│       └── ...
├── .env                       # Configuration (copy from .env.example)
├── pf.conf.template          # Master PF template
├── generate-pfconf.sh        # Config generator
├── update-blocklist.sh       # Blocklist generator
├── apply-blocklist.sh        # Fast blocklist applier
└── install-pktstat-logger.sh # Optional logger installer
```

## Configuration (.env)

### Interface Settings
- `PF_ISP_INTERFACE` - WAN interface (e.g., `ure0`, `em0`)
- `PF_LAN_INTERFACE` - LAN interface (e.g., `ure1`, `em1`)
- `PF_LAN_ENABLED` - `1` for router mode, `0` for single interface

### Blocklist Settings
- `PF_BLOCKLIST_MODE` - `ip` (individual IPs) or `asn` (network ranges)
- `PF_BLOCKLIST_CACHE_DAYS` - IP2ASN database cache duration (default: 180)
- `PF_PROVIDERS_CONF_URL` - Provider list source
- `PF_PROVIDERS_CACHE_DAYS` - Provider IP cache duration (default: 7)

### Security Rules (0=disabled, 1=enabled)
- `PF_CONNLIMIT_PER_IP` - Max connections per IP (0=disabled)
- `PF_DROP_INVALID_STATE` - Drop malformed packets
- `PF_GUARD_UDP_FLOOD` - Rate limit UDP
- `PF_GUARD_PORT_SCANNER` - Block port scanners

See `.env.example` for all options.

## Usage

### Quick Start

```bash
# 1. Configure
cp .env.example .env
vi .env  # Set PF_ISP_INTERFACE, enable rules

# 2. Generate and apply config
doas ./generate-pfconf.sh

# 3. Verify
doas pfctl -sr | head -20
doas pfctl -t threat_spamhaus -T show | wc -l
```

### Update Blocklists

**Automated (recommended)**:
```bash
# Pull pre-generated lists from GitHub CI
doas ./apply-blocklist.sh

# Preview changes
doas ./apply-blocklist.sh --dry-run
```

**Manual regeneration** (slow, 5-10 min):
```bash
./update-blocklist.sh
```

### Verification

```bash
# Show table entry counts
doas pfctl -vvsTables | grep -E "(threat_|monitor_|sec_|crawler_)"

# Check specific source
doas pfctl -t monitor_pingdom -T show | head -10

# Verify active rules
doas pfctl -sr | grep "threat_"
```

### Network Logging (Optional)

```bash
# Install logger
doas ./install-pktstat-logger.sh

# View logs
tail -f /var/log/pktstat/pktstat-$(date +%Y-%m-%d).log
```

## Blocklist Modes

### IP Mode (default)
- Blocks individual IPs from threat feeds
- Auto-aggregates to /24 subnets if >100k entries
- Fast, precise blocking

### ASN Mode
- Converts IPs to full ASN network ranges
- Broader coverage, slower processing
- Set `PF_BLOCKLIST_MODE=asn` in `.env`

## Troubleshooting

### Config generation fails
```bash
# Test template syntax
pfctl -nf pf.conf.template

# Check .env variables
grep PF_ .env
```

### Table not loading
```bash
# Check table file exists
ls -lh output/tables/threat_spamhaus.txt

# Manually load table
doas pfctl -t threat_spamhaus -T replace -f output/tables/threat_spamhaus.txt

# Check PF memory limits
doas pfctl -sm
```

### Provider download fails
```bash
# Test individual provider URL
curl -sSL "https://github.com/jonhadfield/cloud-ips/raw/refs/heads/main/spamhaus.json"

# Check cache
ls -lh input/*.tsv

# Force fresh download
rm input/ip2asn-v4.tsv && ./update-blocklist.sh
```

## Development

### Adding New Provider

1. Add to `providers.conf` (or fork nikescar/cdn-lookup)
2. Categorize in `update-blocklist.sh`:
   - Add to `THREAT_INTEL`, `MONITORING`, `SECURITY`, or `CRAWLERS` variable
3. Update `pf.conf.template` with new table declaration
4. Run `./update-blocklist.sh` to generate table
5. Apply with `doas ./apply-blocklist.sh`

### Testing Changes

```bash
# Always test syntax before applying
pfctl -nf /etc/pf.conf

# Dry-run blocklist update
./apply-blocklist.sh --dry-run

# Check diff before commit
git diff pf.conf.template
```

## Backups

All scripts maintain single backup files (no timestamps):
- `/etc/pf.conf.bak` - Last PF config
- `output/blocklist.bak` - Last aggregated blocklist
- `output/blocklist.info.txt.bak` - Metadata

## External Dependencies

- `curl` - Download providers and IP lists
- `jq` - Parse JSON provider sources
- `wget` - Download cdn-lookup tool (optional)
- `pktstat` - Network logging (optional)

## References

- [OpenBSD PF User's Guide](https://www.openbsd.org/faq/pf/)
- [nikescar/cdn-lookup](https://github.com/nikescar/cdn-lookup) - Provider IP lists
- [jonhadfield/cloud-ips](https://github.com/jonhadfield/cloud-ips) - Threat feeds
- [rezmoss/cloud-provider-ip-addresses](https://github.com/rezmoss/cloud-provider-ip-addresses) - Cloud/CDN ranges

## License

See LICENSE file.
