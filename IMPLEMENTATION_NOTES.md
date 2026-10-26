# Implementation Notes

## Architecture Refactoring (2026-10-26)

### Unified Script Design

**Before**: Three separate scripts
- `update-blocklist.sh` - Download and generate tables
- `generate-pfconf.sh` - Generate PF config
- `apply-blocklist.sh` - Load/purge tables

**After**: Single `pfhelper.sh` with three commands
- `--install` - Complete setup
- `--update` - Update tables only
- `--purge` - Remove tables

### Benefits

1. **Simplified mental model** - One script, three commands
2. **Reduced duplication** - Common code in `lib/common.sh`
3. **Atomic operations** - Each command is self-contained
4. **Better error handling** - Centralized validation
5. **Easier maintenance** - Single entry point

### Code Organization

```
pf/
├── pfhelper.sh              # Main entry point
├── lib/
│   ├── common.sh           # Shared utilities (logging, env, validation)
│   └── parse-providers.sh  # Provider parsing (JSON + regex)
├── pf.conf.template        # PF config template
├── .env                    # Configuration
├── providers.conf          # Provider list (auto-downloaded)
└── output/
    ├── tables/*.txt        # Per-provider tables (31 files)
    ├── blocklist           # Aggregated (backward compat)
    └── blocklist.info.txt  # Metadata
```

### lib/common.sh Functions

**Logging**:
- `log()` - RFC 5424 syslog-style base logger
- `log_info()`, `log_warn()`, `log_error()`, `log_trace()` - Level wrappers

**Environment**:
- `load_env()` - Load and validate .env file
- `require_root()` - Check if running as root, exit if not

**Utilities**:
- `get_script_dir()` - Portable script directory detection
- `ensure_dir()` - Create directory if doesn't exist
- `backup_file()` - Single .bak file backup (no timestamps)
- `download_file()` - HTTP download with timeout and validation
- `require_command()` - Check for required executables

### Command Workflows

**`--install`** (complete setup):
1. Load .env and validate
2. Check root privileges
3. Download providers.conf
4. Generate 31 provider tables
5. Generate /etc/pf.conf from template
6. Validate PF syntax
7. Apply PF config
8. Load all provider tables

**`--update`** (update tables only):
1. Load .env and validate
2. Check root privileges
3. Download providers.conf
4. Regenerate 31 provider tables
5. Reload tables into PF
6. Skip config generation

**`--purge`** (remove all tables):
1. Check root privileges
2. Query active provider tables
3. Flush each table with `pfctl -t <name> -T flush`
4. Report purged count

### Provider Parsing Strategy

**Two-stage approach** (in `lib/parse-providers.sh`):

1. **jq-based JSON parsing** (primary)
   - Handles: `prefixes[].ipv4Prefix`, nested arrays, object arrays
   - Fast and accurate for well-formed JSON

2. **Regex extraction** (fallback)
   - Extracts all IPv4 addresses and CIDR ranges
   - Validates octet ranges (0-255) and CIDR prefix (/0-32)
   - Used when jq parsing fails or returns no results

**Supported formats**:
- AWS-style: `{"prefixes": [{"ipv4Prefix": "1.2.3.4/24"}]}`
- Simple arrays: `["1.2.3.4", "5.6.7.8"]`
- Object arrays: `[{"ip": "1.2.3.4"}]`
- Plain text: One IP/CIDR per line
- Mixed format: Any combination with regex fallback

### Provider Status (31 working)

**Threat Intelligence (7)**:
binarydefense, blocklistde, cinsscore, emergingthreats, greensnow, ipsum, stopforumspam

**Monitoring (7)**:
betterstack, hetrixtools, ohdear, pingdom, sentry, statuscake, uptimerobot

**Security (4)**:
imperva, stormwall, sucuri, zscaler

**Crawlers (13)**:
amazonbot, anthropic, applebot, ccbot, claudebot, commoncrawl, duckassistbot, duckduckbot, googlebot, googlesc, googleutf, gptbot, perplexitybot

**Failed/Excluded (13)**:
- Monitoring (7): checkly, grafana, newrelic, nodeping, site24x7, updown, uptrends - No IPs extractable
- Threat (5): cymru, dshield, feodo, spamhaus, threatfox - Incompatible format
- Excluded (1): asndrop - ASN-only, no IP addresses

### Migration from Old Scripts

**Old workflow**:
```bash
./update-blocklist.sh
doas ./generate-pfconf.sh
doas ./apply-blocklist.sh
```

**New workflow**:
```bash
doas ./pfhelper.sh --install    # One command
```

**Weekly updates** (old):
```bash
./update-blocklist.sh
doas ./apply-blocklist.sh
```

**Weekly updates** (new):
```bash
doas ./pfhelper.sh --update     # One command
```

### Future Enhancements

1. **Add `--status`** - Show current state (tables loaded, counts, last update)
2. **Add `--validate`** - Dry-run validation without applying
3. **Add ASN-to-IP conversion** - Support ASN-only providers
4. **Incremental updates** - Only download changed providers
5. **Provider health monitoring** - Detect upstream format changes
6. **Table diff** - Show what changed between updates

### Testing

**Manual tests**:
```bash
# Test help
./pfhelper.sh --help

# Test install (requires root)
doas ./pfhelper.sh --install
doas pfctl -sTables | grep -c "^threat_"  # Expect 7

# Test update
doas ./pfhelper.sh --update

# Test purge
doas ./pfhelper.sh --purge
doas pfctl -sTables | grep "^threat_"    # Expect empty

# Restore
doas ./pfhelper.sh --install
```

**Automated cron test**:
```bash
# Add to crontab
0 3 * * 1 cd /path/to/pf && doas ./pfhelper.sh --update

# Verify next run
crontab -l
```

### Performance

- **--install**: 1-3 minutes (31 provider downloads + config generation)
- **--update**: 1-3 minutes (31 provider downloads, no config)
- **--purge**: <5 seconds (flush 31 tables)

### Backward Compatibility

- Aggregated `output/blocklist` file maintained for legacy tools
- Old .env configuration fully compatible
- Same PF template format
- Same provider sources
