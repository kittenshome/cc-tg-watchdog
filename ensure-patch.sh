#!/bin/bash
# Ensures a custom patch (e.g., memory injection) stays applied to the
# Telegram plugin's server.ts after official plugin updates.
#
# The official Telegram plugin can auto-update, which overwrites server.ts
# and removes any custom patches. This script:
# 1. Checks if the patch marker is already present
# 2. Dry-runs the patch to verify it applies cleanly
# 3. Applies it with a backup
# 4. Verifies the result compiles
# 5. Rolls back on any failure
#
# Usage:
#   ./ensure-patch.sh                    # auto-detect plugin directory
#   ./ensure-patch.sh /path/to/plugin    # explicit plugin directory

set -u

LOG="${LOG:-/root/tgbot-restart.log}"
PATCH="${PATCH:-/root/my-telegram.patch}"  # path to your portable patch file
PATCH_MARKER="MY_CUSTOM_PATCH"             # unique string your patch adds to server.ts

# Resolve plugin directory
if [ "$#" -ge 1 ] && [ -n "$1" ]; then
  plugin_dir="$1"
else
  # Auto-detect from Claude's installed plugins manifest
  plugin_dir=$(python3 - <<'PY'
import json
p = '${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json'
try:
    data = json.load(open(p))
    items = data.get('plugins', {}).get('telegram@claude-plugins-official', [])
    print(items[-1].get('installPath', '') if items else '')
except Exception:
    print('')
PY
)
fi

server="$plugin_dir/server.ts"
if [ ! -f "$server" ]; then
  echo "$(date '+%F %T') patch check failed: server.ts not found at $plugin_dir" >> "$LOG"
  exit 1
fi

# Already patched? Nothing to do.
if grep -q "$PATCH_MARKER" "$server"; then
  exit 0
fi

# Verify the patch applies cleanly (dry run)
if [ ! -f "$PATCH" ] || ! patch --batch --dry-run "$server" < "$PATCH" >/dev/null 2>&1; then
  echo "$(date '+%F %T') patch check failed: patch does not apply to $plugin_dir" >> "$LOG"
  exit 1
fi

# Apply with backup
stamp=$(date +%Y%m%d-%H%M%S)
backup="$server.before-patch-$stamp"
cp -a "$server" "$backup"
if ! patch --batch "$server" < "$PATCH" >/dev/null 2>&1; then
  cp -a "$backup" "$server"
  echo "$(date '+%F %T') patch apply failed, rolled back: $plugin_dir" >> "$LOG"
  exit 1
fi

# Verify it compiles (requires bun)
if command -v bun >/dev/null 2>&1; then
  check_dir=$(mktemp -d /tmp/tgbot-patch-build.XXXXXX)
  if ! (cd "$plugin_dir" && bun build ./server.ts --target=bun --outdir="$check_dir" >/dev/null 2>&1); then
    cp -a "$backup" "$server"
    rm -rf "$check_dir"
    echo "$(date '+%F %T') patch build failed, rolled back: $plugin_dir" >> "$LOG"
    exit 1
  fi
  rm -rf "$check_dir"
fi

echo "$(date '+%F %T') patch restored after plugin update: $plugin_dir backup=$backup" >> "$LOG"
exit 0
