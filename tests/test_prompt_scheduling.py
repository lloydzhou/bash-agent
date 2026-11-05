#!/usr/bin/env python3
"""Static scheduling contract; e2e golden tests verify emitted prompt bytes."""
import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = (
    "tests/fixtures/system_prompt_expected.txt",
    "tests/fixtures/system_prompt_expected_zh_CN.txt",
)
RUNTIMES = ("src/agent.sh", "go/agent.go", "rust/src/lib.rs", "c/agent.c")

# Snapshot of parallel-tools BATCH_RULE at cff5068; no cross-repository dependency.
BATCH_RULE = (
    "Before calling tools, briefly check what other useful work can run now without these results. "
    "Use an internal dependency DAG for the current subgoal: batch all ready, independent tool calls together in one response, within tool/output limits, with known inputs and prerequisites met. "
    "Gather independent evidence together even if later combined. "
    "Wait for results that decide whether or how to act, approvals, or shared-state ordering (including read-before-edit). "
    "While background work runs, continue work independent of its results and non-interfering with its state. "
    "After results, reassess; never repeat running/completed work. "
    "Real dependency chains and single calls are valid; never invent work. "
    "Use tools as intended, not shell wrappers or delegation to simulate batching. "
    "No printed DAG or extra scheduling turns; preserve required plan, todo, and approval workflows. "
    "Aim to reduce model round trips; actual concurrency depends on runtime."
)
LOCAL_RULE = (
    "Each call must advance the current subgoal, answer a concrete question, or test a relevant hypothesis. "
    "Bounded read-only exploration is welcome; avoid redundant or low-value calls."
)


def guidance(path):
    text = (ROOT / path).read_text()
    return text.split("<using-your-tools>\n", 1)[1].split("\n</using-your-tools>", 1)[0]


def runtime_guidance(path):
    """Decode the actual language literal(s), retaining Unicode and newlines."""
    text = (ROOT / path).read_text()
    if path == "src/agent.sh":
        # The build script requires this ANSI-C assignment on one physical line.
        literal = re.search(r"^    tool_guidance=\$'([^\n]*)'$", text, re.M).group(1)
        return literal.replace(r"\'", "'").replace(r"\n", "\n")
    if path == "go/agent.go":
        block = text.split("toolGuidance := ", 1)[1].split('appendSection("using-your-tools"', 1)[0]
    elif path == "c/agent.c":
        block = text.split("const char *tool_guidance =", 1)[1].split('prompt_append_section(&buf, "using-your-tools"', 1)[0]
    else:
        block = text.split('"using-your-tools",', 1)[1].split("None,", 1)[0]
    return "".join(json.loads(literal) for literal in re.findall(r'"(?:[^"\\]|\\.)*"', block))


class SchedulingPromptTests(unittest.TestCase):
    def test_locales_share_guidance_without_appended_rules(self):
        english, chinese = map(guidance, FIXTURES)
        self.assertEqual(english, chinese)
        # Replace the original three scheduling bullets with core + local policy.
        self.assertEqual(len(english.splitlines()), 11)
        for old in ("- Think of the current subgoal", "- Issue all useful, ready, independent", "- After results arrive", "- Batch independent, useful tool calls"):
            self.assertNotIn(old, english)

    def test_exact_plugin_snapshot_and_separate_local_rule(self):
        self.assertEqual(len(BATCH_RULE.encode()), 945)
        for fixture in FIXTURES:
            with self.subTest(fixture=fixture):
                rules = guidance(fixture).splitlines()
                self.assertEqual(rules[4:6], ["- " + BATCH_RULE, "- " + LOCAL_RULE])
                self.assertEqual(guidance(fixture).count(BATCH_RULE), 1)
                self.assertEqual(guidance(fixture).count(LOCAL_RULE), 1)

    def test_encoded_rules_match_every_runtime_exactly_once(self):
        encoded = r"\n".join(["- " + BATCH_RULE, "- " + LOCAL_RULE]) + r"\n"
        for runtime in RUNTIMES:
            with self.subTest(runtime=runtime):
                self.assertEqual((ROOT / runtime).read_text().count(encoded), 1)

    def test_decoded_runtime_guidance_matches_both_locales(self):
        for runtime in RUNTIMES:
            for fixture in FIXTURES:
                with self.subTest(runtime=runtime, fixture=fixture):
                    self.assertEqual(runtime_guidance(runtime), guidance(fixture))

    def test_scheduling_contract(self):
        clauses = (
            "Before calling tools, briefly check what other useful work can run now without these results.",
            "batch all ready, independent tool calls together in one response",
            "within tool/output limits, with known inputs and prerequisites met",
            "Gather independent evidence together even if later combined",
            "Wait for results that decide whether or how to act, approvals, or shared-state ordering (including read-before-edit)",
            "While background work runs, continue work independent of its results and non-interfering with its state",
            "After results, reassess; never repeat running/completed work",
            "Real dependency chains and single calls are valid; never invent work",
            "Use tools as intended, not shell wrappers or delegation to simulate batching",
            "No printed DAG or extra scheduling turns; preserve required plan, todo, and approval workflows",
            "Aim to reduce model round trips; actual concurrency depends on runtime",
        )
        for fixture in FIXTURES:
            for clause in clauses:
                with self.subTest(fixture=fixture, clause=clause):
                    self.assertIn(clause, guidance(fixture))


if __name__ == "__main__":
    unittest.main()
