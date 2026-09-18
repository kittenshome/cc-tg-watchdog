#!/bin/bash
# Claude Code Telegram Startup Script
# Handles: credential refresh, orphan message recovery, clean tmux launch,
# and Telegram connection verification.

set -u

# ── Config ──────────────────────────────────────────────────────────────
SESSION_NAME="${SESSION_NAME:-tgbot}"
LOG="${LOG:-$HOME/${SESSION_NAME}-restart.log}"
MODEL="${MODEL:-claude-sonnet-4-6}"
EFFORT="${EFFORT:-medium}"
REFRESH_MODEL="${REFRESH_MODEL:-claude-haiku-4-5-20251001}"
ORPHAN_HELPER="${ORPHAN_HELPER:-$HOME/tgbot-orphan.py}"

# Claude config directory. Change this if you use a separate config
# for Telegram (recommended to isolate credentials).
CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# Optional: path to a custom settings JSON
# SETTINGS_FILE="$HOME/.claude/my-settings.json"

# Project directory where session JSONLs are stored
project_slug=$(printf '%s' "$HOME" | sed 's|/|-|g')
PROJECT_DIR="${PROJECT_DIR:-$CLAUDE_CONFIG_DIR/projects/$project_slug}"
BUN_PID_FILE="$CLAUDE_CONFIG_DIR/channels/telegram/bot.pid"
# ────────────────────────────────────────────────────────────────────────

# ── Orphan recovery ────────────────────────────────────────────────────
# Before killing the old session, check if the last inbound message
# was never replied to. If so, save it for the new session to handle.
ORPHAN_JSONL=$(find "$PROJECT_DIR" -type f -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null \
  | sort -nr | head -1 | cut -d' ' -f2-)
ORPHAN_MSG=""
if [ -n "$ORPHAN_JSONL" ] && [ -f "$ORPHAN_HELPER" ]; then
  ORPHAN_MSG=$(python3 "$ORPHAN_HELPER" "$ORPHAN_JSONL" 2>/dev/null)
fi

# ── Credential refresh ─────────────────────────────────────────────────
# Run a minimal Claude call to force credential refresh before starting
# the real session. Without this, expired tokens cause 401 loops.
CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR" timeout 60 \
  claude -p "ok" --model "$REFRESH_MODEL" >/dev/null 2>&1 \
  && echo "$(date '+%F %T') credential refresh OK" >> "$LOG" \
  || echo "$(date '+%F %T') credential refresh failed (continuing)" >> "$LOG"

# ── Stop only this session's processes ─────────────────────────────────
# Save this profile's Bun PID before removing the stale PID file. Avoid
# global pkill patterns, which can terminate unrelated Claude sessions.
old_bun_pid=""
if [ -r "$BUN_PID_FILE" ]; then
  candidate=$(tr -cd '0-9' < "$BUN_PID_FILE")
  if [ -n "$candidate" ] && kill -0 "$candidate" 2>/dev/null \
      && ps -p "$candidate" -o args= 2>/dev/null | grep -Eq 'bun.*server\.ts'; then
    old_bun_pid="$candidate"
  fi
fi
tmux kill-session -t "$SESSION_NAME" 2>/dev/null
sleep 2
if [ -n "$old_bun_pid" ] && kill -0 "$old_bun_pid" 2>/dev/null; then
  kill "$old_bun_pid" 2>/dev/null
  sleep 1
  kill -9 "$old_bun_pid" 2>/dev/null || true
fi
rm -f "$BUN_PID_FILE"

# ── Launch new session ──────────────────────────────────────────────────
# Build the tmux command with all necessary environment variables.
printf -v quoted_config '%q' "$CLAUDE_CONFIG_DIR"
printf -v quoted_model '%q' "$MODEL"
TMUX_CMD="export CLAUDE_CONFIG_DIR=$quoted_config;"
TMUX_CMD+=" export CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=0;"
TMUX_CMD+=" export PATH=\$HOME/.bun/bin:\$PATH;"
TMUX_CMD+=" exec claude"
# Optional: custom settings
# TMUX_CMD+=" --settings $SETTINGS_FILE"
TMUX_CMD+=" --channels plugin:telegram@claude-plugins-official"
TMUX_CMD+=" --model $quoted_model"

# Fixed cwd to avoid nested project paths from random directories.
tmux new-session -d -c "$HOME" -s "$SESSION_NAME" "$TMUX_CMD"
sleep 12
tmux send-keys -t "$SESSION_NAME" Enter

# ── Wait for Telegram connection ────────────────────────────────────────
deadline=$((SECONDS + 45))
while [ "$SECONDS" -lt "$deadline" ]; do
  bun_pid=""
  if [ -r "$BUN_PID_FILE" ]; then
    candidate=$(tr -cd '0-9' < "$BUN_PID_FILE")
    if [ -n "$candidate" ] && kill -0 "$candidate" 2>/dev/null \
        && ps -p "$candidate" -o args= 2>/dev/null | grep -Eq 'bun.*server\.ts'; then
      bun_pid="$candidate"
    fi
  fi
  if [ -n "$bun_pid" ] && ss -tnp 2>/dev/null | grep -q "pid=$bun_pid"; then
    # Set effort level
    tmux send-keys -t "$SESSION_NAME" "/effort $EFFORT" Enter
    sleep 5

    # ── Orphan recovery injection ───────────────────────────────────
    if [ -n "$ORPHAN_MSG" ]; then
      ORPHAN_CHATID=$(python3 "$ORPHAN_HELPER" "$ORPHAN_JSONL" --chatid 2>/dev/null)
      if ! [[ "$ORPHAN_CHATID" =~ ^-?[0-9]+$ ]]; then
        echo "$(date '+%F %T') orphan recovery skipped: no valid chat_id" >> "$LOG"
        ORPHAN_CHATID=""
      fi
    fi
    if [ -n "$ORPHAN_MSG" ] && [ -n "$ORPHAN_CHATID" ]; then
      RECOVERY_DIR="$CLAUDE_CONFIG_DIR/watchdog-recovery"
      umask 077
      mkdir -p "$RECOVERY_DIR"
      chmod 700 "$RECOVERY_DIR"
      find "$RECOVERY_DIR" -type f -name 'context.*' -mtime +1 -delete 2>/dev/null || true
      CTX_FILE=$(mktemp "$RECOVERY_DIR/context.XXXXXX")
      python3 "$ORPHAN_HELPER" "$ORPHAN_JSONL" --context > "$CTX_FILE" 2>/dev/null

      REPROMPT="[Orphan recovery] You just restarted. Read ${CTX_FILE}. The final User entry (chat_id ${ORPHAN_CHATID}) has no successful Telegram reply recorded. Reply to it now naturally, continuing the conversation."

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
      echo "$(date '+%F %T') orphan recovery sent_ok=$sent_ok" >> "$LOG"
    else
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
