#!/bin/bash
# Claude Code Telegram Startup Script
# Handles: credential refresh, orphan message recovery, clean tmux launch,
# and Telegram connection verification.

set -u

# ── Config ──────────────────────────────────────────────────────────────
SESSION_NAME="tgbot"
LOG="/root/${SESSION_NAME}-restart.log"
MODEL="claude-sonnet-4-6"
EFFORT="medium"

# Claude config directory. Change this if you use a separate config
# for Telegram (recommended to isolate credentials).
CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# Optional: override auth token (e.g., from a long-lived OAuth token file)
# OAUTH_TOKEN_FILE="/root/.my-token"

# Optional: path to a custom settings JSON
# SETTINGS_FILE="$HOME/.claude/my-settings.json"

# Project directory where session JSONLs are stored
PROJECT_DIR="$CLAUDE_CONFIG_DIR/projects/-root"
# ────────────────────────────────────────────────────────────────────────

# ── Orphan recovery ────────────────────────────────────────────────────
# Before killing the old session, check if the last inbound message
# was never replied to. If so, save it for the new session to handle.
ORPHAN_JSONL=$(find "$PROJECT_DIR" -type f -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null \
  | sort -nr | head -1 | cut -d' ' -f2-)
ORPHAN_MSG=""
if [ -n "$ORPHAN_JSONL" ]; then
  ORPHAN_MSG=$(python3 "$(dirname "$0")/orphan-recovery.py" "$ORPHAN_JSONL" 2>/dev/null)
fi

# ── Credential refresh ─────────────────────────────────────────────────
# Run a minimal Claude call to force credential refresh before starting
# the real session. Without this, expired tokens cause 401 loops.
CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR" timeout 60 \
  claude -p "ok" --model claude-haiku-4-5-20251001 >/dev/null 2>&1 \
  && echo "$(date '+%F %T') credential refresh OK" >> "$LOG" \
  || echo "$(date '+%F %T') credential refresh failed (continuing)" >> "$LOG"

# ── Kill old processes ──────────────────────────────────────────────────
pkill -9 -f "bun server.ts" 2>/dev/null
pkill -9 -f "bun run.*telegram" 2>/dev/null
pkill -9 -f "claude --channels" 2>/dev/null
tmux kill-session -t "$SESSION_NAME" 2>/dev/null
rm -f "$CLAUDE_CONFIG_DIR/channels/telegram/bot.pid"
sleep 2

# ── Launch new session ──────────────────────────────────────────────────
# Build the tmux command with all necessary environment variables.
TMUX_CMD="export CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR;"
TMUX_CMD+=" export CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=0;"
TMUX_CMD+=" export PATH=\$HOME/.bun/bin:\$PATH;"

# Optional: set OAuth token from file
# TMUX_CMD+=" export CLAUDE_CODE_OAUTH_TOKEN=\$(cat $OAUTH_TOKEN_FILE);"

TMUX_CMD+=" claude"
# Optional: custom settings
# TMUX_CMD+=" --settings $SETTINGS_FILE"
TMUX_CMD+=" --channels plugin:telegram@claude-plugins-official"
TMUX_CMD+=" --model $MODEL"

# Fixed cwd to avoid nested project paths from random directories.
tmux new-session -d -c "$HOME" -s "$SESSION_NAME" "$TMUX_CMD"
sleep 12
tmux send-keys -t "$SESSION_NAME" Enter

# ── Wait for Telegram connection ────────────────────────────────────────
deadline=$((SECONDS + 45))
while [ "$SECONDS" -lt "$deadline" ]; do
  bun_pid=$(pgrep -f "bun server.ts" | head -1)
  if [ -n "$bun_pid" ] && ss -tnp 2>/dev/null | grep -q "pid=$bun_pid"; then
    # Set effort level
    tmux send-keys -t "$SESSION_NAME" "/effort $EFFORT" Enter
    sleep 5

    # ── Orphan recovery injection ───────────────────────────────────
    if [ -n "$ORPHAN_MSG" ]; then
      CTX_FILE=/tmp/tgbot-replay-context.txt
      python3 "$(dirname "$0")/orphan-recovery.py" "$ORPHAN_JSONL" --context > "$CTX_FILE" 2>/dev/null
      ORPHAN_CHATID=$(python3 "$(dirname "$0")/orphan-recovery.py" "$ORPHAN_JSONL" --chatid 2>/dev/null)

      REPROMPT="[Orphan recovery] You just restarted. Read file ${CTX_FILE} for recent context. The last message \"${ORPHAN_MSG:0:30}\" was from the user (chat_id ${ORPHAN_CHATID}) and you never replied. Reply to it now naturally, continuing the conversation."

      sent_ok=0
      for attempt in 1 2 3; do
        tmux send-keys -t "$SESSION_NAME" -l "$REPROMPT"
        sleep 2
        tmux send-keys -t "$SESSION_NAME" Enter
        sleep 4
        if ! tmux capture-pane -t "$SESSION_NAME" -p 2>/dev/null | tail -6 | grep -q "Orphan recovery"; then
          sent_ok=1; break
        fi
        tmux send-keys -t "$SESSION_NAME" C-c; sleep 1
        tmux send-keys -t "$SESSION_NAME" C-u; sleep 1
      done
      echo "$(date '+%F %T') orphan recovery sent_ok=$sent_ok: ${ORPHAN_MSG:0:40}" >> "$LOG"
    else
      rm -f /tmp/tgbot-replay-context.txt
      echo "$(date '+%F %T') no orphan message found" >> "$LOG"
    fi

    echo "$(date '+%F %T') $SESSION_NAME ready: claude=$(pgrep -f '^claude --channels' | head -1) bun=$bun_pid" >> "$LOG"
    echo "OK: session started, Telegram connected."
    exit 0
  fi
  sleep 1
done

echo "$(date '+%F %T') $SESSION_NAME failed: Telegram Bun/TCP not ready" >> "$LOG"
echo "FAIL: Claude started but Telegram did not connect."
exit 1
