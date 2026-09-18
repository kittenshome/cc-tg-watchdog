import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "orphan-recovery.py"


def inbound(text="hello", chat_id="123", user="456"):
    content = (
        f'<channel source="plugin:telegram" user="{user}" '
        f'chat_id="{chat_id}"><telegram_message>{text}</telegram_message></channel>'
    )
    return {"type": "user", "message": {"content": content}}


def reply_call(tool_id="tool-1", chat_id="123", text="hi"):
    return {
        "type": "assistant",
        "message": {"content": [{
            "type": "tool_use",
            "id": tool_id,
            "name": "mcp__plugin_telegram_telegram__reply",
            "input": {"chat_id": chat_id, "text": text},
        }]},
    }


def tool_result(tool_id="tool-1", is_error=False):
    return {
        "type": "user",
        "message": {"content": [{
            "type": "tool_result",
            "tool_use_id": tool_id,
            "is_error": is_error,
            "content": "ok" if not is_error else "failed",
        }]},
    }


class OrphanRecoveryTests(unittest.TestCase):
    def run_script(self, rows, *args, trailing_text=""):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "session.jsonl"
            path.write_text(
                "".join(json.dumps(row) + "\n" for row in rows) + trailing_text,
                encoding="utf-8",
            )
            result = subprocess.run(
                [sys.executable, str(SCRIPT), str(path), *args],
                check=True,
                capture_output=True,
                text=True,
            )
            return result.stdout.rstrip("\n")

    def test_unanswered_message_is_returned(self):
        self.assertEqual(self.run_script([inbound()]), "hello")

    def test_tool_call_without_result_is_still_orphaned(self):
        self.assertEqual(self.run_script([inbound(), reply_call()]), "hello")

    def test_successful_result_for_same_chat_is_not_orphaned(self):
        rows = [inbound(), reply_call(), tool_result()]
        self.assertEqual(self.run_script(rows), "")

    def test_result_for_different_chat_does_not_hide_orphan(self):
        rows = [inbound(), reply_call(chat_id="999"), tool_result()]
        self.assertEqual(self.run_script(rows), "hello")

    def test_error_result_does_not_hide_orphan(self):
        rows = [inbound(), reply_call(), tool_result(is_error=True)]
        self.assertEqual(self.run_script(rows), "hello")

    def test_negative_group_chat_id_is_supported(self):
        rows = [inbound(chat_id="-100123")]
        self.assertEqual(self.run_script(rows, "--chatid"), "-100123")

    def test_latest_tokens_include_uncached_input(self):
        rows = [{"message": {"usage": {
            "input_tokens": 11,
            "cache_creation_input_tokens": 20,
            "cache_read_input_tokens": 30,
        }}}]
        self.assertEqual(self.run_script(rows, "--tokens"), "61")

    def test_channel_without_numeric_user_is_ignored(self):
        self.assertEqual(self.run_script([inbound(user="system")]), "")

    def test_truncated_final_row_does_not_hide_previous_message(self):
        result = self.run_script([inbound()], trailing_text='{"type":"assistant"')
        self.assertEqual(result, "hello")


if __name__ == "__main__":
    unittest.main()
