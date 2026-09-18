#!/usr/bin/env python3
"""Orphan message recovery for Claude Code Telegram watchdog.

Given a session JSONL file, finds the last inbound Telegram message
and checks if Claude ever replied to it. If not, prints the message
text so the startup script can tell the new session to reply.

Usage:
    python3 orphan-recovery.py /path/to/session.jsonl          # print orphan text (or empty)
    python3 orphan-recovery.py /path/to/session.jsonl --chatid  # print the chat_id
    python3 orphan-recovery.py /path/to/session.jsonl --context # print recent conversation context
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
    if m and not m.group(1).isdigit():
        return False
    return True


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


def get_telegram_replies(obj: dict) -> list[str]:
    """Extract telegram reply texts from an assistant turn."""
    msg = obj.get("message", {})
    content = msg.get("content") if isinstance(msg, dict) else obj.get("content")
    replies = []
    if isinstance(content, list):
        for part in content:
            if (isinstance(part, dict) and part.get("type") == "tool_use"
                    and "telegram" in part.get("name", "").lower()
                    and "reply" in part.get("name", "").lower()):
                text = (part.get("input", {}) or {}).get("text", "")
                if text.strip():
                    replies.append(text.strip())
    return replies


def oneline(s: str, cap: int) -> str:
    return re.sub(r"\s+", " ", s).strip()[:cap]


def main():
    args = sys.argv[1:]
    want_context = "--context" in args
    want_chatid = "--chatid" in args
    files = [a for a in args if not a.startswith("--")]
    path = files[0] if files else ""

    try:
        rows = [json.loads(line) for line in open(path) if line.strip()]
    except Exception:
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
                m = re.search(r'chat_id="([0-9]+)"', content)
                last_in_chatid = m.group(1) if m else ""

    if last_in_idx < 0:
        print("")
        return

    # Check if any assistant turn after the last inbound has a telegram reply
    for obj in rows[last_in_idx + 1:]:
        if (obj.get("type") or obj.get("role")) == "assistant" and get_telegram_replies(obj):
            print("")  # Already replied, no orphan
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
            for txt in get_telegram_replies(obj):
                dialogue.append(("Assistant", oneline(txt, 220)))

    tail = dialogue[-MAX_TURNS:]
    while tail and sum(len(a) + len(b) for a, b in tail) > MAX_CHARS and len(tail) > 2:
        tail = tail[1:]
    print("\n".join(f"{who}: {txt}" for who, txt in tail))


if __name__ == "__main__":
    main()
