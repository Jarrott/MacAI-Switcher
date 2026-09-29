"""Verify shell argument routing without starting Codex or reading credentials."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class CodexShellTests(unittest.TestCase):
    """Exercise the sourced function against an isolated argument-recording CLI."""

    def test_optional_email_repair_is_version_scoped(self):
        """Use the repair only for interactive calls on its exact upstream version."""
        source = Path(__file__).with_name("codex-shell.zsh").read_text()
        cases = [
            ([], ["repair", "--no-daemon"]),
            (["resume", "id"], ["repair", "resume", "--no-daemon", "id"]),
            (["--no-daemon", "a b"], ["repair", "--no-daemon", "a b"]),
            (["--remote", "unix://test"], ["repair", "--remote", "unix://test"]),
            (["login", "status"], ["upstream", "login", "status"]),
            (["app-server"], ["upstream", "app-server"]),
            (["--help"], ["upstream", "--help"]),
        ]
        with tempfile.TemporaryDirectory(prefix="aiswitcher-repair-test-") as directory:
            root = Path(directory)
            integration = root / "codex-shell.zsh"
            integration.write_text(source)
            upstream = root / "codex"
            upstream.write_text(
                '#!/bin/sh\nif [ "$1" = --version ]; then\n'
                'printf "%s\\n" "$TEST_CODEX_VERSION"; exit 0; fi\n'
                'printf "%s\\0" upstream "$@"\nexit 17\n'
            )
            upstream.chmod(0o700)
            repair = root / "codex-status/bin/codex"
            repair.parent.mkdir(parents=True)
            repair.write_text('#!/bin/sh\nprintf "%s\\0" repair "$AISWITCHER_CODEX_AI_SUGGESTIONS" "$@"\nexit 17\n')
            repair.chmod(0o700)
            environment = dict(os.environ, PATH=directory + ":/usr/bin:/bin")
            environment.pop("AISWITCHER_CODEX_AI_SUGGESTIONS", None)
            for version in ["codex-cli 0.159.0", "codex-cli 0.160.0", "unknown"]:
                for args, expected in cases:
                    with self.subTest(version=version, args=args):
                        if version != "codex-cli 0.159.0":
                            expected = ["upstream", *expected[1:]]
                        if expected[0] == "repair":
                            expected = [expected[0], "1", *expected[1:]]
                        result = subprocess.run(
                            ["/bin/zsh", "-dfc", 'source "$1"; shift; codex "$@"',
                             "test", str(integration), *args],
                            env=dict(environment, TEST_CODEX_VERSION=version),
                            capture_output=True, check=False,
                        )
                        self.assertEqual(result.stdout.decode().split("\0")[:-1], expected)
                        self.assertEqual(result.returncode, 17)
                        self.assertEqual(result.stderr, b"")
            disabled = subprocess.run(
                ["/bin/zsh", "-dfc", 'source "$1"; codex', "test", str(integration)],
                env=dict(environment, TEST_CODEX_VERSION="codex-cli 0.159.0",
                         AISWITCHER_CODEX_AI_SUGGESTIONS="0"),
                capture_output=True, check=False,
            )
            self.assertEqual(disabled.stdout.decode().split("\0")[:-1],
                             ["repair", "0", "--no-daemon"])
            self.assertEqual(disabled.returncode, 17)

    def test_routing_and_exit_status(self):
        """Preserve utility/remote calls, quoting and failures; isolate local sessions."""
        integration = Path(__file__).with_name("codex-shell.zsh").resolve()
        cases = [
            ([], ["--no-daemon"]),
            (["fix the tests"], ["--no-daemon", "fix the tests"]),
            (["--model", "test-model"], ["--no-daemon", "--model", "test-model"]),
            (["resume", "session-1"], ["resume", "--no-daemon", "session-1"]),
            (["resume"], ["resume", "--no-daemon"]),
            (["resume", "session-1", ""], ["resume", "--no-daemon", "session-1", ""]),
            (["fork", "--last"], ["fork", "--no-daemon", "--last"]),
            (["-C", "a directory", "resume", "id"],
             ["-C", "a directory", "resume", "--no-daemon", "id"]),
            (["-c", 'model="test"', "resume", "--last"],
             ["-c", 'model="test"', "resume", "--no-daemon", "--last"]),
            (["--", "$(never-run) `never-run`"],
             ["--no-daemon", "--", "$(never-run) `never-run`"]),
        ]
        passthrough = [
            ["login", "status"], ["exec", "synthetic prompt"], ["agents"],
            ["app-server", "daemon", "version"], ["features", "list"],
            ["--version"], ["resume", "--help"], ["resume", "--no-daemon", "id"],
            ["--no-daemon"], ["--remote", "unix://"],
            ["resume", "--remote=unix://", "id"],
            ["resume", "id", "--remote", "unix://"],
            ["synthetic prompt", "--remote", "unix://"],
            ["--model", "test-model", "exec", "synthetic prompt"],
        ]
        cases.extend((args, args) for args in passthrough)
        with tempfile.TemporaryDirectory(prefix="aiswitcher-shell-test-") as directory:
            executable = Path(directory) / "codex"
            executable.write_text('#!/bin/sh\nprintf "%s\\0" "$@"\nexit 17\n')
            executable.chmod(0o700)
            environment = dict(os.environ, PATH=directory + ":/usr/bin:/bin")
            for args, expected in cases:
                with self.subTest(args=args):
                    result = subprocess.run(
                        ["/bin/zsh", "-dfc", 'source "$1"; shift; codex "$@"',
                         "test", str(integration), *args],
                        env=environment, capture_output=True, check=False,
                    )
                    actual = result.stdout.decode().split("\0")[:-1]
                    self.assertEqual(actual, expected)
                    self.assertEqual(result.returncode, 17)
                    self.assertEqual(result.stderr, b"")


if __name__ == "__main__":
    unittest.main()
