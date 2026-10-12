"""Exercise Bash functions with isolated state and simulated maintenance commands."""

from pathlib import Path
import subprocess
import unittest


SCRIPT = (Path(__file__).resolve().parents[1] / "glus.sh").read_text()
FUNCTIONS, ENTRYPOINT = SCRIPT[SCRIPT.index("clean_portage_dir() {"):].rsplit("\nmain ", 1)


def bash(code):
    return subprocess.run(
        ["bash", "--noprofile", "--norc"],
        input=FUNCTIONS + "\n" + code,
        text=True,
        capture_output=True,
        env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"},
        timeout=10,
    )


class Hooks(unittest.TestCase):
    def test_rejects_code_in_validation_and_execution(self):
        for payload in (
            "printf safe\nprintf INJECTED",
            "printf safe)\nprintf INJECTED\n#",
            "printf $(printf INJECTED)",
            "printf safe; printf INJECTED",
        ):
            quoted = "'" + payload.replace("'", "'\\''") + "'"
            for function in ("validate_config_command TEST", "run_config_command"):
                with self.subTest(payload=payload, function=function):
                    result = bash(f"dry_run=true\n{function} {quoted}\n")
                    self.assertNotEqual(result.returncode, 0)
                    self.assertNotIn("INJECTED", result.stdout)

    def test_quotes_escapes_empty_and_literal_arguments(self):
        result = bash(r'''
command() { printf '<%s>\n' "$@"; }
run_config_command 'printf "two words" '\''single quoted'\'' escaped\ space "" literal* $UNSET "back\slash"'
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [
            '<printf>', '<two words>', '<single quoted>', '<escaped space>',
            '<>', '<literal*>', '<$UNSET>', '<back\\slash>',
        ])

    def test_rejects_incomplete_quotes_and_escapes(self):
        for value in ('printf "unfinished', 'printf trailing\\'):
            result = bash("validate_config_command TEST '" + value + "'\n")
            self.assertNotEqual(result.returncode, 0)

    def test_plan_does_not_execute_hook(self):
        result = bash('dry_run=true\nrun_config_command "printf HOOK_EXECUTED"\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.startswith('[INFO] Plan command: printf '))
        self.assertEqual(result.stdout.count('HOOK_EXECUTED'), 1)


if __name__ == "__main__":
    unittest.main()
