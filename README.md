# OpenBSD PF with Provider-Based Blocklist

Adaptive firewall with categorized threat blocking from 45+ sources (threat intelligence, monitoring, security, crawlers). Each source gets its own PF table with category-specific rules. All scripts use RFC 5424 syslog-style output and maintain single backup files.

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

## Blocking Categories

Provider sources from [nikescar/cdn-lookup](https://github.com/nikescar/cdn-lookup):

| Category | Sources | Block Rule | Purpose |
|----------|---------|------------|---------|
| **Threat Intelligence** | 7 | IN + OUT | Malware, spam, compromised IPs |
| **Monitoring** | 7 | IN only | Uptime checkers, synthetic monitors |
| **Security** | 4 | IN + OUT | WAF/DDoS protection services |
| **Crawlers & Bots** | 13 | IN + OUT | Search engines, AI scrapers |

**Total: 31 active sources**

Each source gets a dedicated PF table: `<category_source>` (e.g., `threat_blocklistde`, `monitor_pingdom`, `crawler_googlebot`).

### Working Providers

**Threat Intelligence (7)**
- Binary Defense, Blocklist.de, CINS Army List, Emerging Threats, GreenSnow, IPsum, StopForumSpam

**Monitoring (7)**
- Better Stack, HetrixTools, Oh Dear, Pingdom, Sentry, StatusCake, UptimeRobot

**Security (4)**
- Imperva, Stormwall, Sucuri, Zscaler

**Crawlers & Bots (13)**
- Amazonbot, Anthropic Crawler, Applebot, CCBot, ClaudeBot, Common Crawl, DuckAssistBot, DuckDuckBot, Googlebot, Google Special Crawlers, Google User-Triggered Fetchers, GPTBot, PerplexityBot

### Provider Notes

- **Regex Fallback**: JSON parsing failures automatically fall back to regex IP extraction
- **Failed Providers**: checkly, grafana, newrelic, nodeping, site24x7, updown, uptrends (monitoring); cymru, dshield, feodo, spamhaus, threatfox (threat) - no IPs extractable
- **Excluded**: asndrop (ASN-only, no IP addresses)

## Configuration (.env)

### Interfaces
- **PF_ISP_INTERFACE** - WAN interface (e.g., `ure0`, `em0`)
- **PF_LAN_INTERFACE** - LAN interface (e.g., `ure1`, `em1`)
- **PF_LAN_ENABLED** - `1` for router mode, `0` for single interface

### Provider Configuration
- **PF_PROVIDERS_CONF_URL** - Provider list source (cdn-lookup)
- **PF_PROVIDERS_CACHE_DAYS** - Cache duration (default: 7 days)
- **PF_PROVIDER_TIMEOUT** - HTTP timeout per provider (default: 30s)

### Security Rules (0=disabled, 1=enabled)
- **PF_CONNLIMIT_PER_IP** - Max connections per IP (0=disabled)
- **PF_DROP_INVALID_STATE** - Drop malformed packets
- **PF_GUARD_UDP_FLOOD** - Rate limit UDP
- **PF_GUARD_PORT_SCANNER** - Block port scanners

See `.env.example` for all options.

## Usage

### pfhelper.sh - Unified Management Tool

Single script for all blocklist operations:

```bash
# Complete installation (first-time setup)
doas ./pfhelper.sh --install

# Update blocklists (weekly maintenance)
doas ./pfhelper.sh --update

# Remove all provider tables
doas ./pfhelper.sh --purge
```

### Commands

**`--install`** - Complete setup
- Downloads providers.conf
- Downloads IPs from 31 providers (~1-3 min)
- Generates 31 table files in `output/tables/`
- Generates `/etc/pf.conf` from template
- Validates and applies PF config
- Loads all provider tables into PF

**`--update`** - Update workflow  
- Re-downloads provider IPs
- Regenerates table files
- Reloads tables into PF
- Does NOT regenerate `/etc/pf.conf`

**`--purge`** - Remove tables
- Flushes all provider tables from PF
- Leaves files on disk (use `--install` to reload)

### Automated Updates

**Cron setup** (weekly updates):
```bash
crontab -e
# Add: 0 3 * * 1 cd /path/to/pf && doas ./pfhelper.sh --update
```

**Cron setup** (weekly update):
```bash
crontab -e
# Add: 0 3 * * 1 cd /path/to/pf && ./update-blocklist.sh && doas ./apply-blocklist.sh
```

## Verification

Check if provider tables are active:

```bash
# Count loaded tables (expect 31)
doas pfctl -sTables | grep -cE "^(threat_|monitor_|sec_|crawler_)"

# Show all loaded tables with entry counts
doas pfctl -vvsTables | grep -E "^\s+Addresses"

# Check specific provider
doas pfctl -t threat_blocklistde -T show | wc -l
doas pfctl -t monitor_pingdom -T show | head -10
doas pfctl -t crawler_googlebot -T show

# Verify rules loaded
doas pfctl -sr | grep "threat_"
doas pfctl -sr | grep "monitor_"
doas pfctl -sr | grep "crawler_"

# Show blocking stats per table
doas pfctl -vvsTables | grep -B2 "Addresses"
```

## Network Traffic Logger (Optional)

Monitors network connections with automatic daily log rotation:

```bash
# Install and start logger
doas ./pktstathelper.sh --install

# Check status
./pktstathelper.sh --status

# View current logs
tail -f /var/log/pktstat/pktstat-$(date +%Y-%m-%d).log

# Uninstall logger
doas ./pktstathelper.sh --uninstall
```

**Interface Selection:**
- If `PF_LAN_ENABLED=1`: monitors `PF_LAN_INTERFACE` (LAN traffic)
- If `PF_LAN_ENABLED=0`: monitors `PF_ISP_INTERFACE` (WAN traffic)

Logs retained for 7 days with automatic cleanup.

## Files

### Scripts
- **`pfhelper.sh`** - Unified blocklist management (install/update/purge)
- **`pktstathelper.sh`** - Optional network traffic logger (install/uninstall/status)

### Configuration
- **`.env`** - Configuration (copy from `.env.example`)
- **`pf.conf.template`** - Master template with 31 table declarations
- **`providers.conf`** - Provider list from cdn-lookup (auto-downloaded)

### Libraries
- **`lib/common.sh`** - Shared functions (logging, env loading, utilities)
- **`lib/parse-providers.sh`** - Provider parser with JSON + regex fallback
- **`lib/github.sh`** - GitHub release download functions

### Data Directories
- **`input/`** - Legacy data sources (git-ignored)
- **`output/tables/`** - 31 provider table files (git-ignored)
- **`output/blocklist`** - Aggregated file, ~50K+ IPs (backward compat)
- **`output/blocklist.info.txt`** - Per-source metadata

### Workflow

```
pfhelper.sh --install
    ↓
    1. Download providers.conf
    2. Generate output/tables/*.txt (31 files)
    3. Generate /etc/pf.conf from template
    4. Apply config with pfctl -f
    5. Load all tables with pfctl -t <name> -T replace

pfhelper.sh --update
    ↓
    1. Download providers.conf
    2. Regenerate output/tables/*.txt
    3. Reload tables (no config change)

pfhelper.sh --purge
    ↓
    1. Flush all provider tables from PF
```

## Backups

All scripts maintain single backup files (no timestamps):
- `/etc/pf.conf.bak` - Last PF config backup
- `output/blocklist.bak` - Last aggregated blocklist backup
- `output/blocklist.info.txt.bak` - Last metadata backup

## Troubleshooting

### Tables not loading
```bash
# Check table files exist
ls -lh output/tables/

# Check PF memory limits
doas pfctl -sm

# Clear all tables and reinstall
doas ./pfhelper.sh --purge
doas ./pfhelper.sh --install
```

### Provider download fails
```bash
# Test provider URL manually
curl -sSL "https://github.com/jonhadfield/cloud-ips/raw/refs/heads/main/anthropic.json" | jq

# Check jq installed
command -v jq || doas pkg_add jq

# Force refresh providers.conf
rm providers.conf && ./update-blocklist.sh

# Check which providers failed
grep "WARN.*No IPs extracted" /var/log/pf-update.log
```

### Empty or incomplete tables
```bash
# Check table file sizes
ls -lh output/tables/ | awk '$5 == "0" {print "Empty:", $9}'

# Verify IP format in table
head output/tables/threat_blocklistde.txt

# Re-download specific category
rm output/tables/threat_*.txt && ./update-blocklist.sh
```

### Config generation fails
```bash
# Test template syntax
pfctl -nf pf.conf.template

# Check all variables set
grep PF_ .env

# Validate .env configuration
./pfhelper.sh --help  # Will fail if .env missing/invalid
```
