#!/usr/bin/env python3
"""Orphan message recovery for Claude Code Telegram watchdog.

Given a session JSONL file, finds the last inbound Telegram message
and checks if Claude ever replied to it. If not, prints the message
text so the startup script can tell the new session to reply.

Usage:
    python3 orphan-recovery.py /path/to/session.jsonl           # print orphan text (or empty)
    python3 orphan-recovery.py /path/to/session.jsonl --chatid   # print the chat_id
    python3 orphan-recovery.py /path/to/session.jsonl --context  # print recent conversation context
    python3 orphan-recovery.py /path/to/session.jsonl --tokens   # print latest input context size
"""
import sys
import json
import re


def is_user_inbound(content: str) -> bool:
    """Check if a message is a real user Telegram message (not a system event)."""
    if not isinstance(content, str):
        return False
    if not (content.lstrip().startswith("<channel") and "plugin:telegram" in content):
        return False
    # Filter out system-generated messages (watcher alerts, free-speak, etc.)
    system_markers = ("free_speak_opportunity", "telegram_time_context",
                      "rule_key=")
    if any(m in content for m in system_markers):
        return False
    # Real users have numeric IDs; system sources have alphabetic IDs
    m = re.search(r'<channel[^>]*\buser="([^"]*)"', content)
    return bool(m and m.group(1).isdigit())


def extract_message_text(raw: str) -> str:
    """Extract the actual message text from the channel XML wrapper."""
    # Strip memory injection blocks
    raw = re.sub(r"<aion_memory_context>.*?</aion_memory_context>", "", raw, flags=re.S)
    m = re.search(r"<telegram_message>(.*?)</telegram_message>", raw, flags=re.S)
    if m:
        return m.group(1).strip()
    # Fallback: strip all XML tags
    body = re.sub(r"<[^>]+>", "", raw, flags=re.S)
    return body.strip()


def get_content(obj: dict):
    """Return a transcript row's message content."""
    msg = obj.get("message", {})
    return msg.get("content") if isinstance(msg, dict) else obj.get("content")


def get_telegram_reply_calls(obj: dict) -> list[dict]:
    """Extract Telegram reply tool calls from an assistant turn."""
    content = get_content(obj)
    replies = []
    if isinstance(content, list):
        for part in content:
            if (isinstance(part, dict) and part.get("type") == "tool_use"
                    and "telegram" in part.get("name", "").lower()
                    and "reply" in part.get("name", "").lower()):
                tool_input = part.get("input", {}) or {}
                text = tool_input.get("text", "")
                if text.strip():
                    chat_id = (tool_input.get("chat_id") or tool_input.get("chatId")
                               or tool_input.get("chat") or "")
                    replies.append({
                        "id": str(part.get("id", "")),
                        "chat_id": str(chat_id),
                        "text": text.strip(),
                    })
    return replies


def get_successful_tool_results(obj: dict) -> set[str]:
    """Return tool-use IDs with a recorded non-error result."""
    content = get_content(obj)
    if not isinstance(content, list):
        return set()
    successful = set()
    for part in content:
        if not isinstance(part, dict) or part.get("type") != "tool_result":
            continue
        tool_id = str(part.get("tool_use_id", ""))
        if tool_id and not part.get("is_error", False):
            successful.add(tool_id)
    return successful


def latest_context_tokens(rows: list[dict]) -> int:
    """Find the latest non-zero input context count in nested usage data."""
    latest = 0

    def walk(value):
        nonlocal latest
        if isinstance(value, dict):
            if ("cache_creation_input_tokens" in value
                    or "cache_read_input_tokens" in value):
                total = 0
                for key in ("input_tokens", "cache_creation_input_tokens",
                            "cache_read_input_tokens"):
                    number = value.get(key, 0)
                    if isinstance(number, int) and not isinstance(number, bool):
                        total += number
                if total > 0:
                    latest = total
            for child in value.values():
                walk(child)
        elif isinstance(value, list):
            for child in value:
                walk(child)

    for row in rows:
        walk(row)
    return latest


def read_recent_rows(path: str, max_bytes: int = 4 * 1024 * 1024) -> list[dict]:
    """Read complete JSONL rows from the tail without loading a huge session."""
    rows = []
    with open(path, "rb") as source:
        source.seek(0, 2)
        size = source.tell()
        start = max(0, size - max_bytes)
        source.seek(start)
        if start:
            source.readline()  # discard a possibly partial first row
        for raw_line in source:
            if not raw_line.strip():
                continue
            try:
                rows.append(json.loads(raw_line))
            except (json.JSONDecodeError, UnicodeDecodeError):
                continue
    return rows


def oneline(s: str, cap: int) -> str:
    return re.sub(r"\s+", " ", s).strip()[:cap]


def main():
    args = sys.argv[1:]
    want_context = "--context" in args
    want_chatid = "--chatid" in args
    want_tokens = "--tokens" in args
    files = [a for a in args if not a.startswith("--")]
    path = files[0] if files else ""

    if want_tokens:
        try:
            print(latest_context_tokens(read_recent_rows(path)))
        except Exception:
            print(0)
        return

    rows = []
    try:
        with open(path, encoding="utf-8") as source:
            for line in source:
                if not line.strip():
                    continue
                try:
                    rows.append(json.loads(line))
                except json.JSONDecodeError:
                    # A process can die while appending the final JSONL row.
                    # Keep earlier complete rows available for recovery.
                    continue
    except (OSError, UnicodeError):
        print("")
        return

    # Find the last inbound user message
    last_in_idx = -1
    last_in_text = ""
    last_in_chatid = ""
    for i, obj in enumerate(rows):
        if (obj.get("type") or obj.get("role")) != "user":
            continue
        msg = obj.get("message", {})
        content = msg.get("content") if isinstance(msg, dict) else obj.get("content")
        if is_user_inbound(content):
            text = extract_message_text(content)
            if text:
                last_in_idx = i
                last_in_text = text
                m = re.search(r'chat_id="(-?[0-9]+)"', content)
                last_in_chatid = m.group(1) if m else ""

    if last_in_idx < 0:
        print("")
        return

    # A tool call alone is not delivery proof: the old process may die before
    # its tool result is recorded. Require a successful result for the same chat.
    pending_reply_ids = set()
    for obj in rows[last_in_idx + 1:]:
        for reply in get_telegram_reply_calls(obj):
            if (reply["id"] and last_in_chatid
                    and reply["chat_id"] == last_in_chatid):
                pending_reply_ids.add(reply["id"])
        if pending_reply_ids & get_successful_tool_results(obj):
            print("")  # Successfully replied, no orphan
            return

    if want_chatid:
        print(last_in_chatid)
        return

    if not want_context:
        print(oneline(last_in_text, 500))
        return

    # --context mode: extract recent conversation turns for context injection
    MAX_TURNS, MAX_CHARS = 8, 1400
    dialogue = []
    for obj in rows[:last_in_idx + 1]:
        role = obj.get("type") or obj.get("role")
        if role == "user":
            content = obj.get("message", {}).get("content")
            if is_user_inbound(content):
                text = extract_message_text(content)
                if text:
                    dialogue.append(("User", oneline(text, 220)))
        elif role == "assistant":
            for reply in get_telegram_reply_calls(obj):
                dialogue.append(("Assistant", oneline(reply["text"], 220)))

    tail = dialogue[-MAX_TURNS:]
    while tail and sum(len(a) + len(b) for a, b in tail) > MAX_CHARS and len(tail) > 2:
        tail = tail[1:]
    print("\n".join(f"{who}: {txt}" for who, txt in tail))


if __name__ == "__main__":
    main()
