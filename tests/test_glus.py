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


class Arguments(unittest.TestCase):
    def test_entrypoint_preserves_zero_arguments(self):
        result = bash('main() { printf "%s" "$#"; }\nmain ' + ENTRYPOINT)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '0')

    def test_defaults_reach_validation(self):
        result = bash('''
SYS_CONF_FILE=/dev/null
validate_config() { printf '%s %s' "$sync" "$security"; return 77; }
main
''')
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(result.stdout, 'true true')

    def test_package_argument_keeps_spaces(self):
        result = bash('''
SYS_CONF_FILE=/dev/null
validate_config() { printf '%s' "$packages"; return 77; }
main --packages 'app-one/pkg app-two/pkg'
''')
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(result.stdout, 'app-one/pkg app-two/pkg')


class FetchMode(unittest.TestCase):
    def test_fetch_never_merges_configuration(self):
        for debug in ('true', 'false'):
            result = bash(f'''
fetch=true; pretend=false; debug={debug}
command() {{ printf 'CALLED'; }}
etc_update_portage
''')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, '')

    def test_regular_update_still_merges_configuration(self):
        result = bash('''
fetch=false; pretend=false; debug=false
command() { printf '%s\\n' "$@"; }
etc_update_portage
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('/usr/sbin/etc-update', result.stdout)


class CompileOptions(unittest.TestCase):
    def compile_commands(self, binary='', options='', fetch='false'):
        result = bash(f'''
fetch={fetch}; pretend=false; debug=false; errors=0
color_args=(); exclude_args=(); pretend_args=()
binary_args=({binary}); emerge_opts_args=({options})
update_devel() {{ :; }}
find_emerge() {{ printf '/fake/emerge'; }}
command() {{ printf '%s ' "$@"; printf '\\n'; }}
compile -u portage
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        return [line.split() for line in result.stdout.splitlines() if '/fake/emerge' in line]

    def test_binary_mode_applies_to_both_phases(self):
        for flag in ('-k', '-K'):
            with self.subTest(flag=flag):
                commands = self.compile_commands(binary=flag)
                self.assertEqual(len(commands), 2)
                for command in commands:
                    self.assertIn(flag, command)

    def test_fetch_only_downloads_binary_packages(self):
        commands = self.compile_commands(binary='-K', fetch='true')
        self.assertEqual(len(commands), 1)
        self.assertIn('-f', commands[0])
        self.assertIn('-K', commands[0])

    def test_source_mode_does_not_enable_binaries(self):
        for command in self.compile_commands():
            self.assertNotIn('-k', command)
            self.assertNotIn('-K', command)

    def test_emerge_options_apply_to_both_phases(self):
        commands = self.compile_commands(options='--jobs=2 --load-average=4')
        self.assertEqual(len(commands), 2)
        for command in commands:
            self.assertIn('--jobs=2', command)
            self.assertIn('--load-average=4', command)


if __name__ == "__main__":
    unittest.main()
