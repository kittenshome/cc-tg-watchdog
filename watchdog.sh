#!/bin/bash
# Claude Code Telegram Watchdog
# Run from crontab every 3 minutes: */3 * * * * /path/to/watchdog.sh
#
# Checks the health of a Claude Code + Telegram session running in tmux,
# and restarts it when things go wrong.

# ── Config ──────────────────────────────────────────────────────────────
SESSION_NAME="tgbot"                    # tmux session name
LOCKFILE="/tmp/.${SESSION_NAME}-watchdog.lock"
LOG="/root/${SESSION_NAME}-watchdog.log"
START_SCRIPT="/root/tgbot.sh"           # path to your startup script

# Context rotation thresholds (tokens)
CTX_LIMIT=120000        # Soft: rotate after 15 min idle
CTX_HARD_LIMIT=155000   # Hard: rotate after 2 min idle
CTX_PANIC_LIMIT=165000  # Panic: rotate immediately

# Claude config directory (where session JSONLs live)
CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
PROJECT_DIR="$CLAUDE_CONFIG_DIR/projects/-root"
# ────────────────────────────────────────────────────────────────────────

# Only one watchdog instance at a time.
exec 9>"$LOCKFILE"
flock -n 9 || exit 0

restart() {
  echo "$(date "+%F %T") restart: $1" >> "$LOG"
  flock -u 9
  exec 9>&-
  "$START_SCRIPT" >> "$LOG" 2>&1
  rm -f "/tmp/${SESSION_NAME}-noconn-flag"
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
# Read the session JSONL to get actual context size from token usage data.
# cache_creation + cache_read = real context window size.
latest_jsonl=$(ls -t "$PROJECT_DIR"/*.jsonl 2>/dev/null | head -1)
if [ -n "$latest_jsonl" ]; then
  # Get token count from last non-zero usage entry
  ctx_tokens=$(tail -c 300000 "$latest_jsonl" \
    | grep -oE '"cache_creation_input_tokens":[0-9]+,"cache_read_input_tokens":[0-9]+' \
    | awk -F'[:,]' '{s=$2+$4; if (s>0) last=s} END{print last+0}')

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

# 7) Kill orphaned Telegram Bun processes (parent is init, PID 1)
while read -r bun_pid; do
  [ -n "$bun_pid" ] || continue
  parent_pid=$(ps -p "$bun_pid" -o ppid= 2>/dev/null | tr -d " ")
  if [ "$parent_pid" = "1" ]; then
    kill -9 "$bun_pid" 2>/dev/null
    echo "$(date "+%F %T") killed orphan bun $bun_pid" >> "$LOG"
  fi
done < <(pgrep -f "bun server.ts")

# 8) Telegram TCP connection check
# Require two consecutive failures to avoid restarting on network blips.
bun_pid=$(pgrep -f "bun server.ts" | head -1)
if [ -n "$bun_pid" ]; then
  in_progress=$(screen | grep -c "esc to interrupt")
  if [ "$in_progress" -eq 0 ]; then
    has_conn=$(ss -tnp 2>/dev/null | grep -c "pid=$bun_pid")
    if [ "$has_conn" -eq 0 ]; then
      if [ -f "/tmp/${SESSION_NAME}-noconn-flag" ]; then
        restart "bun has no TCP connection (silent hang)"
        exit 0
      else
        touch "/tmp/${SESSION_NAME}-noconn-flag"
      fi
    else
      rm -f "/tmp/${SESSION_NAME}-noconn-flag"
    fi
  fi
fi
