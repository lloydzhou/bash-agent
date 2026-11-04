#!/usr/bin/env python3
"""Static scheduling contract; e2e golden tests verify emitted prompt bytes."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = (
    "tests/fixtures/system_prompt_expected.txt",
    "tests/fixtures/system_prompt_expected_zh_CN.txt",
)
RUNTIMES = ("src/agent.sh", "go/agent.go", "rust/src/lib.rs", "c/agent.c")


def guidance(path):
    text = (ROOT / path).read_text()
    return text.split("<using-your-tools>\n", 1)[1].split("\n</using-your-tools>", 1)[0]


class SchedulingPromptTests(unittest.TestCase):
    def test_locales_share_guidance_without_appended_rules(self):
        english, chinese = map(guidance, FIXTURES)
        self.assertEqual(english, chinese)
        # Replace the existing three scheduling bullets, not append another set.
        self.assertEqual(len(english.splitlines()), 12)
        self.assertNotIn("- Batch independent, useful tool calls", english)

    def test_three_rules_match_every_runtime_exactly_once(self):
        rules = guidance(FIXTURES[0]).splitlines()[4:7]
        self.assertEqual(len(rules), 3)
        encoded = r"\n".join(rules) + r"\n"
        for runtime in RUNTIMES:
            with self.subTest(runtime=runtime):
                self.assertEqual((ROOT / runtime).read_text().count(encoded), 1)

    def test_scheduling_contract(self):
        text = guidance(FIXTURES[0])
        clauses = (
            "tool calls are nodes; required results, conditions, approvals, and state ordering are edges",
            "look ahead internally across the current subgoal, not just the next action",
            "Do not print a DAG or add a separate turn or tool call solely for scheduling",
            "required plan, todo, and approval workflows",
            "all useful, ready, independent tool calls together in the same response",
            "prerequisites must be satisfied, inputs known",
            "free of shared-state conflicts, within permissions and tool/output limits",
            "Collect independent evidence together even when later decisions depend on combining it",
            "Wait when an earlier result must determine whether or how another action runs",
            "Batching reduces model round trips; actual concurrent execution depends on the runtime",
            "After results arrive, reassess what is ready without duplicating completed or running work",
            "Bounded read-only exploration is welcome",
            "rather than inventing extra work to fill a batch",
            "A single call is correct when no other useful independent call is ready",
        )
        for clause in clauses:
            with self.subTest(clause=clause):
                self.assertIn(clause, text)


if __name__ == "__main__":
    unittest.main()
