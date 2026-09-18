# Claude Code Telegram Watchdog

Keep a Claude Code + Telegram session alive 24/7 on a VPS, with automatic restart, context rotation (auto "breathing"), orphan message recovery, and optional memory injection across restarts.

## The Problem

Running `claude --channels plugin:telegram@claude-plugins-official` on a VPS works great until it doesn't:

- The tmux session dies silently
- Claude hits a rate limit dialog and gets stuck
- The Telegram Bun process loses its TCP connection
- API credentials expire mid-session (401 loops)
- The context window fills up and Claude starts forgetting things
- A restart happens right when a message arrives, and nobody replies

This repo solves all of them.

## Architecture

```
crontab (every 3 min)
  |
  v
tgbot-watchdog.sh ── checks health ── all good? exit
  |                                       |
  | (something wrong)                     |
  v                                       |
tgbot.sh ── kills old session             |
  |      ── recovers orphan messages      |
  |      ── refreshes credentials         |
  |      ── launches new tmux session     |
  |      ── verifies Telegram connection  |
  v                                       |
claude --channels plugin:telegram  <------+
  (running in tmux session "tgbot")
```

## Quick Start

### Prerequisites

- A VPS with Claude Code CLI installed and authenticated
- The Telegram plugin (`plugin:telegram@claude-plugins-official`)
- `tmux` installed
- A working Telegram bot token configured in the plugin

### 1. Copy the scripts

```bash
# Put these in your home directory (or wherever you like)
cp watchdog.sh ~/tgbot-watchdog.sh
cp start.sh ~/tgbot.sh
cp orphan-recovery.py ~/tgbot-orphan.py
chmod +x ~/tgbot-watchdog.sh ~/tgbot.sh
```

### 2. Configure

Edit `tgbot.sh` and set:

```bash
# Your Claude config directory (where .credentials.json lives)
CLAUDE_CONFIG_DIR="/root/.claude"

# tmux session name
SESSION_NAME="tgbot"

# Model to use
MODEL="claude-sonnet-4-6"
```

### 3. Set up crontab

```bash
crontab -e
# Add this line:
*/3 * * * * /root/tgbot-watchdog.sh
```

That's it. The watchdog runs every 3 minutes, checks health, and restarts if needed.

## What the Watchdog Checks

The watchdog runs a series of health checks, in order:

| # | Check | What it catches | Action |
|---|-------|----------------|--------|
| 1 | tmux session exists | Process crash, OOM kill, server reboot | Full restart |
| 2 | Screen content: `could not be parsed` | Unrecoverable channel parse failure | Full restart |
| 3 | Screen content: `Upgrade your plan` | Rate limit dialog blocking input | Send Escape key |
| 4 | Screen content: `Select login method` | Accidentally entered login flow | Send Escape, restart if stuck |
| 5 | Context token count | Context window filling up | Restart when idle (see below) |
| 6 | Screen content: `API Error: 401` (x2) | Expired credentials | Full restart |
| 7 | Orphaned Bun processes | Zombie Telegram processes | Kill orphans |
| 8 | Bun TCP connection | Silent Telegram disconnection | Restart after 2 consecutive fails |

## Context Rotation ("Breathing")

The watchdog automatically rotates the Claude session when the context window gets too large. This prevents Claude's built-in context compression from kicking in, which causes worse "memory loss" than a clean restart.

Three thresholds:

| Threshold | Tokens | Idle requirement | Rationale |
|-----------|--------|-----------------|-----------|
| Soft | 120,000 | 15 min idle | Normal rotation. Waits for a quiet moment. |
| Hard | 155,000 | 2 min idle | Approaching compression zone. Brief idle check to avoid killing an in-flight reply. |
| Panic | 165,000 | None | About to hit compression. Restart immediately. |

**How it measures tokens:** Reads the session JSONL file and extracts `cache_creation_input_tokens + cache_read_input_tokens` from the last non-zero usage entry. This is the actual context window size, not an estimate.

**How it knows Claude is idle:** Checks two things:
1. The tmux screen does NOT contain "esc to interrupt" (Claude is not mid-response)
2. The JSONL file's mtime is old enough (Claude hasn't processed anything recently)

## Orphan Message Recovery

The most painful failure mode: a restart happens right when someone sends a message. The old session dies before replying, and the new session has no idea the message exists.

The orphan recovery system fixes this:

1. **Before killing the old session**, `tgbot.sh` reads its JSONL transcript
2. `tgbot-orphan.py` finds the last inbound message and checks if any `assistant` turn after it contains a `telegram__reply` tool call
3. If the last message was never replied to, it's an "orphan"
4. After the new session starts, the startup script injects a prompt telling Claude to reply to that orphan message, with a few turns of preceding context for continuity

```python
# The key logic in orphan-recovery.py:
# 1. Find the last inbound Telegram message from the user
# 2. Check if any assistant turn after it called telegram__reply
# 3. If not: it's an orphan. Return the text for the startup script.
```

## Memory Injection (Optional Advanced Feature)

For users who want Claude to retain context across restarts, you can build a memory gateway that:

1. Records all inbound/outbound Telegram messages to a database
2. On each new message, retrieves relevant memories and recent conversation history
3. Injects this context as a preamble to the user's message before Claude sees it

This requires patching the Telegram plugin's `server.ts`. See [Memory Gateway](docs/memory-gateway.md) for details.

The `ensure-patch.sh` script automatically re-applies this patch when the plugin auto-updates, with rollback on failure:

1. Check if `server.ts` already has the patch markers
2. If not, try applying the portable `.patch` file
3. Build the result to verify it compiles
4. If the build fails, roll back to the backup

## Files

| File | Purpose |
|------|---------|
| `watchdog.sh` | Health checker, runs from crontab every 3 min |
| `start.sh` | Full startup procedure with orphan recovery |
| `orphan-recovery.py` | Detects unreplied messages in session transcripts |
| `ensure-patch.sh` | Maintains memory gateway patch across plugin updates |

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_CONFIG_DIR` | `~/.claude` | Claude Code config directory |
| `CLAUDE_CODE_OAUTH_TOKEN` | (none) | Override authentication token |
| `SESSION_NAME` | `tgbot` | tmux session name |
| `MODEL` | `claude-sonnet-4-6` | Claude model to use |
| `GIN_SKIP_INITIAL_RECENT_CONTEXT` | `0` | Skip initial memory injection |

### Tuning Context Rotation

Edit the thresholds in `watchdog.sh`:

```bash
CTX_LIMIT=120000      # Soft limit: rotate when idle for 15 min
CTX_HARD_LIMIT=155000 # Hard limit: rotate when idle for 2 min
CTX_PANIC_LIMIT=165000 # Panic: rotate immediately
```

Lower these if you want more frequent rotation (shorter conversations, less context usage). Raise them if you want longer conversations before rotation.

## Lessons Learned

These are real failure modes discovered in production over months of 24/7 operation:

1. **Don't use arrow keys in rate limit dialogs.** The "Upgrade your plan / Stop and wait" dialog ignores arrow keys. Pressing Enter selects "Upgrade" and puts Claude into a `/upgrade` login flow it can't escape. Use Escape instead.

2. **Context rotation must check idle state.** An early version rotated mid-conversation. The user's first message to the new session hit a Claude with zero context. Now rotation waits for idle.

3. **Hard rotation limits need idle checks too.** Even the hard limit (155k tokens) needs at least 2 minutes of idle. A message arrived 4 seconds before a forced rotation and was swallowed with no reply.

4. **Bun zombies need parent-PID checks.** Simply killing all `bun server.ts` processes can kill the active one. Only kill orphans whose parent PID is 1 (init-adopted).

5. **TCP connection checks need two consecutive failures.** A single check without a Telegram TCP connection can be a momentary network blip. Require two consecutive failures before restarting.

6. **401 errors need a count threshold.** A single 401 can be transient. Two or more means the credentials are actually expired.

7. **Credential refresh before restart.** Run a minimal Claude call (haiku, "ok") before starting the real session to force credential refresh. Without this, a 401 loop can repeat 21 times without recovery.

8. **Orphan detection must distinguish real messages from system events.** The Telegram channel delivers both user messages and system notifications (watcher alerts, free-speak opportunities) in the same `<channel>` format. Orphan detection must filter by user ID (real users have numeric IDs).

## License

MIT
