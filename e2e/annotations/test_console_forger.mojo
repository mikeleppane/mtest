"""Known-outcome fixture: a child whose captured stdout tries to FORGE GitHub
Actions workflow commands.

Verdict FAIL, exit-class 1. The test prints, to its own stdout, a would-be
`::error` workflow command AND a seeded stop-commands fence with a guessed token,
then fails an assertion. When mtest echoes this captured output under
`GITHUB_ACTIONS=true`, EVERY such region is wrapped in a collision-proof
stop-commands fence minted AFTER this child exited, so the forged command can
never land and the seeded token can never re-enable commands. Reached only by the
`annotations-fencing` e2e cell — never in the default suite.
"""
from std.testing import assert_equal, TestSuite


def test_forges_workflow_commands_and_fails() raises:
    # A forged annotation the child has no right to emit.
    print("::error file=evil.mojo,line=1::PWNED-BY-CHILD-OUTPUT")
    # A seeded would-be resume fence: a 128-bit-shaped GUESS at mtest's token.
    print("::stop-commands::deadbeefdeadbeefdeadbeefdeadbeef")
    print("::deadbeefdeadbeefdeadbeefdeadbeef::")
    assert_equal(1, 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
