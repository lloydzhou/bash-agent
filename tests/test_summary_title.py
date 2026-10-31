#!/usr/bin/env python3
"""Focused PR98 summary-title regressions; no server, API key, or compiler needed.

Run: python3 tests/test_summary_title.py
Bash tests execute the production llm_summary_call with transport/store helpers
stubbed. C/Go/Rust checks cover only instruction literals, not runtime extraction
or persistence. No agent startup or full end-to-end suite is exercised.
"""

import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
PREFIX = (
    "The conversation context above needs to be compacted. IMPORTANT: Do NOT use any tools. "
    "Do NOT think. Just output the summary directly as plain text. "
    "Summarize the key information from the messages above into a concise context summary. "
    "Update the existing summary snapshot using the messages above. "
    "Use exactly these fields:\nTitle: "
)
SUFFIX = (
    "\nTask focus:\nLatest request:\nKey technical concepts:\nFiles and code:\nProgress:"
    "\nTool evidence:\nErrors and fixes:\nReflections:\nNext step:\nCritical context:"
    "\n\nThe Title line is the session title: keep it EXACTLY as written above when present; "
    "otherwise write one short line (at most 60 characters, no surrounding quotes) "
    "describing this conversation."
)
STRING_LITERAL = r'"(?:\\.|[^"\\])*"'


def literals(source):
    """Decode the ordinary quoted literals used by these instruction builders."""
    return "".join(json.loads(value) for value in re.findall(STRING_LITERAL, source))


@unittest.skipUnless(shutil.which("bash"), "bash is required")
class BashSummaryTitleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = (ROOT / "src/agent.sh").read_text()
        # Load only the real function, avoiding main and agent startup side effects.
        match = re.search(r"^llm_summary_call\(\) \{\n.*?^\}", source, re.M | re.S)
        if match is None:
            raise AssertionError("cannot locate production llm_summary_call")
        cls.function = match.group(0)

    def call_summary(self, previous_summary, response="Title: generated\nTask focus: test"):
        with tempfile.TemporaryDirectory(prefix="summary-title-test-") as directory:
            work = Path(directory)
            summary = work / "summary.txt"
            if previous_summary is not None:
                summary.write_text(previous_summary)
            dropped = work / "dropped.jsonl"
            original_message = {"role": "user", "content": "Please summarize this task."}
            dropped.write_text(json.dumps(original_message) + "\n")
            capture = work / "captured.json"
            script = self.function + r'''
CONTEXT_SUMMARY_FILE="$1"
CAPTURE="$3"
PYTHON="$4"
MOCK_RESPONSE="$5"
util_json_escape() {
    printf '%s' "$1" | "$PYTHON" -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1], end="")'
}
store_conv_get_messages() {
    "$PYTHON" -c 'import json,sys; print(json.dumps([json.loads(line) for line in open(sys.argv[1])]))' "$1"
}
llm_call() {
    [[ "$2" == "" && "$3" == disabled ]] || return 1
    printf '%s' "$1" > "$CAPTURE"
    printf 'TEXT\0%s\0' "$MOCK_RESPONSE"
}
util_read_msg() {
    REPLY_MESSAGE=()
    IFS= read -r -d '' REPLY_MESSAGE[0] && IFS= read -r -d '' REPLY_MESSAGE[1]
}
util_die() { printf '%s\n' "$*" >&2; exit 1; }
llm_summary_call "$2"
'''
            result = subprocess.run(
                ["bash", "-c", script, "summary-title-test", str(summary), str(dropped),
                 str(capture), sys.executable, response],
                text=True, capture_output=True, timeout=10,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, response)
            messages = json.loads(capture.read_text())
            self.assertEqual(len(messages), 2)
            self.assertEqual(messages[0], original_message)
            self.assertEqual(messages[1]["role"], "user")
            return messages[1]["content"], result.stdout

    def test_first_summary_without_title(self):
        for previous in (None, "", "Task focus: existing summary\nNo title yet"):
            with self.subTest(previous=previous):
                instruction, _ = self.call_summary(previous)
                self.assertEqual(instruction, PREFIX + SUFFIX)

    def test_extract_first_title_and_strip_exactly_one_optional_space(self):
        cases = [
            ("Title: x", "x"),
            ("Title:x", "x"),
            ("Task focus: earlier\nTitle: x\nProgress: done", "x"),
            ("Title: first\nTitle: second", "first"),
            ("Title:\nTitle: second", ""),
            (" Title: ignored\ntitle: ignored\nTitle: actual", "actual"),
            ("Title:  x", " x"),
            ("Title:\tx", "\tx"),
            ("Title: \tx  ", "\tx  "),
            ("Title: 修复 résumé", "修复 résumé"),
            ('Title: quotes " and \\ slash', 'quotes " and \\ slash'),
        ]
        for previous, title in cases:
            with self.subTest(previous=previous):
                instruction, _ = self.call_summary(previous)
                self.assertEqual(instruction, PREFIX + title + SUFFIX)
                self.assertNotIn("Title: Title:", instruction)

    def test_same_title_over_two_summary_calls(self):
        title = "Keep the original title"
        # Simulate the caller persisting the LLM response between compactions.
        # The stub returns a compliant response; this does not test LLM obedience.
        for initial in (None, "Title: " + title + "\nTask focus: old"):
            with self.subTest(initial=initial):
                first, response = self.call_summary(
                    initial, "Title: " + title + "\nTask focus: updated"
                )
                self.assertEqual(first, PREFIX + (title if initial else "") + SUFFIX)
                second, _ = self.call_summary(response)
                self.assertEqual(second, PREFIX + title + SUFFIX)
                self.assertNotIn("Title: Title:", second)


class CrossLanguageInstructionTests(unittest.TestCase):
    """Static contract checks only: these do not execute C, Go, or Rust."""

    def test_go_instruction_literal(self):
        source = (ROOT / "go/transport.go").read_text()
        match = re.search(r"summaryInstruction\s*:=\s*([^\n]+)", source)
        self.assertIsNotNone(match)
        self.assertEqual(literals(match.group(1)), PREFIX + SUFFIX)
        self.assertIn("+ currentTitle +", match.group(1))

    def test_rust_instruction_literal(self):
        source = (ROOT / "rust/src/agent.rs").read_text()
        match = re.search(r"let summary_instruction\s*=\s*format!\((.*?)\);", source, re.S)
        self.assertIsNotNone(match)
        self.assertEqual(literals(match.group(1)), PREFIX + "{current_title}" + SUFFIX)

    def test_c_instruction_literals(self):
        source = (ROOT / "c/agent.c").read_text()
        chunks = re.findall(r"sb_append\(&summary_instruction,\s*((?:" + STRING_LITERAL + r"\s*)+)\);", source)
        self.assertEqual(len(chunks), 2, "expected prefix and suffix around title extraction")
        self.assertEqual([literals(chunk) for chunk in chunks], [PREFIX, SUFFIX])


if __name__ == "__main__":
    unittest.main(verbosity=2)
