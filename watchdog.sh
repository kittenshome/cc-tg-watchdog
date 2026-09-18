#!/bin/bash
# Claude Code Telegram Watchdog
# Run from crontab every 3 minutes: */3 * * * * /path/to/watchdog.sh
#
# Checks the health of a Claude Code + Telegram session running in tmux,
# and restarts it when things go wrong.

# ── Config ──────────────────────────────────────────────────────────────
SESSION_NAME="${SESSION_NAME:-tgbot}"   # tmux session name
LOG="${LOG:-$HOME/${SESSION_NAME}-watchdog.log}"
START_SCRIPT="${START_SCRIPT:-$HOME/tgbot.sh}"
ORPHAN_HELPER="${ORPHAN_HELPER:-$HOME/tgbot-orphan.py}"

# Context rotation thresholds (tokens)
CTX_LIMIT="${CTX_LIMIT:-120000}"        # Soft: rotate after 15 min idle
CTX_HARD_LIMIT="${CTX_HARD_LIMIT:-155000}"   # Hard: rotate after 2 min idle
CTX_PANIC_LIMIT="${CTX_PANIC_LIMIT:-165000}" # Panic: rotate immediately

# Claude config directory (where session JSONLs live)
CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
project_slug=$(printf '%s' "$HOME" | sed 's|/|-|g')
PROJECT_DIR="${PROJECT_DIR:-$CLAUDE_CONFIG_DIR/projects/$project_slug}"
BUN_PID_FILE="$CLAUDE_CONFIG_DIR/channels/telegram/bot.pid"
WATCHDOG_STATE_DIR="${WATCHDOG_STATE_DIR:-$CLAUDE_CONFIG_DIR/watchdog-state}"
umask 077
mkdir -p "$WATCHDOG_STATE_DIR"
chmod 700 "$WATCHDOG_STATE_DIR"
LOCKFILE="$WATCHDOG_STATE_DIR/${SESSION_NAME}.lock"
NOCONN_FLAG="$WATCHDOG_STATE_DIR/${SESSION_NAME}.noconn"
# ────────────────────────────────────────────────────────────────────────

# Only one watchdog instance at a time.
exec 9>"$LOCKFILE"
flock -n 9 || exit 0

restart() {
  echo "$(date "+%F %T") restart: $1" >> "$LOG"
  flock -u 9
  exec 9>&-
  "$START_SCRIPT" >> "$LOG" 2>&1
  rm -f "$NOCONN_FLAG"
}

# 1) tmux session exists?
tmux has-session -t "$SESSION_NAME" 2>/dev/null || {
  restart "tmux session gone"
  exit 0
}

# Helper: capture tmux screen content
screen() {
  tmux capture-pane -t "$SESSION_NAME" -p 2>/dev/null
}

# 2) Unrecoverable channel parse failure
screen | grep -q "could not be parsed" && {
  restart "channel parse failure"
  exit 0
}

# 3) Rate limit dialog ("Upgrade your plan")
# IMPORTANT: Do NOT use arrow keys here. They don't work in this dialog,
# and pressing Enter selects "Upgrade" which puts Claude into a login flow.
# Escape dismisses the dialog and lets Claude resume when quota refreshes.
screen | grep -q "Upgrade your plan" && {
  tmux send-keys -t "$SESSION_NAME" Escape
  echo "$(date "+%F %T") rate limit dialog dismissed with Escape" >> "$LOG"
  exit 0
}

# 4) Stuck in login selection page
screen | grep -q "Select login method" && {
  tmux send-keys -t "$SESSION_NAME" Escape
  sleep 3
  if screen | grep -q "Select login method"; then
    restart "stuck in login page"
  else
    echo "$(date "+%F %T") login page dismissed with Escape" >> "$LOG"
  fi
  exit 0
}

# 5) Context window rotation
# Read the session JSONL to estimate input context size from usage data.
latest_jsonl=$(ls -t "$PROJECT_DIR"/*.jsonl 2>/dev/null | head -1)
if [ -n "$latest_jsonl" ]; then
  # input_tokens + cache_creation + cache_read approximates the input context.
  ctx_tokens=0
  if [ -f "$ORPHAN_HELPER" ]; then
    ctx_tokens=$(python3 "$ORPHAN_HELPER" "$latest_jsonl" --tokens 2>/dev/null || printf '0')
  fi

  # Is Claude currently processing? ("esc to interrupt" visible on screen)
  busy=$(screen | grep -c "esc to interrupt")

  # How long since last activity?
  idle_secs=$(( $(date +%s) - $(stat -c %Y "$latest_jsonl") ))

  if [ -n "$ctx_tokens" ] && [ "$busy" -eq 0 ]; then
    # Panic: about to hit auto-compression, restart no matter what
    if [ "$ctx_tokens" -ge "$CTX_PANIC_LIMIT" ]; then
      restart "context ${ctx_tokens} tokens panic (compression imminent)"
      exit 0
    fi
    # Hard: close to compression, but still wait for brief idle
    if [ "$ctx_tokens" -ge "$CTX_HARD_LIMIT" ] && [ "$idle_secs" -ge 120 ]; then
      restart "context ${ctx_tokens} tokens hard limit (idle ${idle_secs}s)"
      exit 0
    fi
    # Soft: normal rotation after long idle
    if [ "$ctx_tokens" -ge "$CTX_LIMIT" ] && [ "$idle_secs" -ge 900 ]; then
      restart "context ${ctx_tokens} tokens soft limit (idle ${idle_secs}s)"
      exit 0
    fi
  fi
fi

# 6) Credential failures (401 errors)
# A single 401 can be transient. Two or more = credentials actually expired.
if [ "$(screen | grep -c 'API Error: 401')" -ge 2 ]; then
  restart "401 credential failure"
  exit 0
fi

# 7) Resolve only this Telegram profile's Bun process. Never use a global
# pkill/pgrep here: a VPS may host other Claude channel sessions.
bun_pid=""
if [ -r "$BUN_PID_FILE" ]; then
  candidate=$(tr -cd '0-9' < "$BUN_PID_FILE")
  if [ -n "$candidate" ] && kill -0 "$candidate" 2>/dev/null \
      && ps -p "$candidate" -o args= 2>/dev/null | grep -Eq 'bun.*server\.ts'; then
    bun_pid="$candidate"
  fi
fi

# 8) Telegram TCP connection check
# Require two consecutive failures to avoid restarting on network blips.
in_progress=$(screen | grep -c "esc to interrupt")
if [ "$in_progress" -eq 0 ]; then
  has_conn=0
  if [ -n "$bun_pid" ]; then
    has_conn=$(ss -tnp 2>/dev/null | grep -c "pid=$bun_pid")
  fi
  if [ "$has_conn" -eq 0 ]; then
    if [ -f "$NOCONN_FLAG" ]; then
      restart "telegram bun/TCP unavailable twice"
      exit 0
    else
      touch "$NOCONN_FLAG"
    fi
  else
    rm -f "$NOCONN_FLAG"
  fi
fi
