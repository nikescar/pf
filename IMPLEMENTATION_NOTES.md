
## Table Management

### Apply Script Features

**Loading Modes:**
- Normal: Load all tables from `output/tables/` directory
- Dry-run: Preview tables and entry counts without loading
- Force: Reload all tables even if already loaded

**Purge Mode:**
- Flushes all provider tables from active PF ruleset
- Searches for tables matching: `threat_*`, `monitor_*`, `sec_*`, `crawler_*`
- Safe to run - only affects provider tables, not other PF tables
- Useful before maintenance, testing, or complete reload

**Usage Examples:**
```bash
# Normal workflow
doas ./apply-blocklist.sh

# Preview before loading
doas ./apply-blocklist.sh --dry-run

# Complete refresh
doas ./apply-blocklist.sh --purge
./update-blocklist.sh
doas ./apply-blocklist.sh

# Force reload without purge
doas ./apply-blocklist.sh --force
```

### Table Lifecycle

1. **Generation**: `update-blocklist.sh` downloads IPs and creates `output/tables/*.txt`
2. **Loading**: `apply-blocklist.sh` loads tables into PF with `pfctl -t <name> -T replace`
3. **Active State**: Tables remain in PF memory until flushed or system restart
4. **Purging**: `--purge` flag removes all provider tables from PF
5. **Persistence**: Tables survive config reloads but not reboots (reload needed after boot)

### Automatic Updates

**Cron Setup** (recommended for weekly updates):
```bash
# /etc/crontab or user crontab
0 3 * * 1  cd /path/to/pf && ./update-blocklist.sh && doas ./apply-blocklist.sh
```

**Before System Maintenance:**
```bash
# Save current state
doas pfctl -sTables > /tmp/pf-tables-backup.txt

# Purge provider tables
doas ./apply-blocklist.sh --purge

# Do maintenance...

# Restore
doas ./apply-blocklist.sh
```

## Script Integration

### generate-pfconf.sh + apply-blocklist.sh

After refactoring, clear separation of concerns:

**generate-pfconf.sh** (config generator):
- Reads `pf.conf.template` and `.env`
- Replaces placeholders with actual values
- Removes disabled security sections (based on .env flags)
- Validates syntax with `pfctl -nf`
- Applies config with `pfctl -f` (if root)
- **Automatically calls `apply-blocklist.sh`** to load tables (if root)

**apply-blocklist.sh** (table manager):
- Loads all provider tables from `output/tables/*.txt`
- Supports dry-run, force reload, and purge modes
- Can run standalone (no config generation)
- Reports loaded/failed counts

### Integration Flow

**Normal workflow (as root):**
```bash
./update-blocklist.sh      # Generate tables
doas ./generate-pfconf.sh  # Generate config + load tables
```

**Standalone table updates:**
```bash
./update-blocklist.sh         # Regenerate tables
doas ./apply-blocklist.sh    # Reload tables only (no config change)
```

**Maintenance workflow:**
```bash
doas ./apply-blocklist.sh --purge  # Clear all provider tables
# Do maintenance...
doas ./apply-blocklist.sh          # Restore tables
```

### Why Separate Scripts?

1. **Modularity** - Table loading independent of config generation
2. **Flexibility** - Update tables without config reload
3. **Troubleshooting** - Test table loading in isolation
4. **Cron-friendly** - Scheduled table updates without config changes

### Legacy Compatibility

Old workflow (single blocklist file):
```bash
doas pfctl -t blocklist -T replace -f blocklist
```

New workflow (31 provider tables):
```bash
doas ./apply-blocklist.sh
```

Backward compatibility maintained via aggregated `output/blocklist` file.
