"""Exercise Bash functions with isolated state and simulated maintenance commands."""

from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


SCRIPT = (Path(__file__).resolve().parents[1] / "glus.sh").read_text()
FUNCTIONS, ENTRYPOINT = SCRIPT[SCRIPT.index("cleanup() {"):].rsplit("\nmain ", 1)


def bash(code):
    return subprocess.run(
        ["bash", "--noprofile", "--norc"],
        input=FUNCTIONS + "\n" + code,
        text=True,
        capture_output=True,
        env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"},
        timeout=10,
    )


def plan(options, setup=''):
    return bash('''
SYS_CONF_FILE=/nonexistent/glus-test.conf; errors=0
get_versions() { :; }
find_emerge() { printf /fake/emerge; }
''' + setup + '\nmain --plan --color false ' + options + '\n')


class PackageSets(unittest.TestCase):
    def test_packages_only_plan_excludes_general_maintenance(self):
        result = plan('--packages-only dev-lang/rust-bin', setup='''
GLUS_CLEAN=true; GLUS_LIVE=true; GLUS_GO=true; GLUS_MODULES=true
GLUS_BEFORE_SYNC=true; GLUS_AFTER_COMPILE=true
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        steps = [line for line in result.stdout.splitlines() if 'Plan step:' in line]
        self.assertEqual(steps, ['[INFO] Plan step: Update selected packages: dev-lang/rust-bin'])
        commands = [shlex.split(line.split('Plan command: ', 1)[1])
                    for line in result.stdout.splitlines() if 'Plan command:' in line]
        self.assertEqual(len(commands), 2)
        for command in commands:
            self.assertEqual(command[0], '/fake/emerge')
            self.assertEqual(command[-3:], ['-u', '--', 'dev-lang/rust-bin'])

    def test_packages_only_rejects_empty_targets_and_conflicting_modes(self):
        for options in ("--packages-only ''", "--packages-only '  '",
                        '--packages-only dev-lang/rust-bin --system',
                        '--packages-only dev-lang/rust-bin --world',
                        '--packages-only dev-lang/rust-bin --full'):
            with self.subTest(options=options):
                result = plan(options)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertNotIn('Plan command:', result.stdout)

    def test_empty_selection_skips_sets_and_keeps_maintenance(self):
        result = plan('--no-security')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('Update sets', result.stdout)
        self.assertIn('-u portage', result.stdout)
        self.assertIn('@preserved-rebuild', result.stdout)

    def test_selected_sets_still_run(self):
        for options, expected in (
            ('', '@security'),
            ('--no-security --go', '@golang-rebuild'),
            ('--no-security --modules', '@modules-rebuild'),
            ('--no-security --packages app-test/pkg', 'app-test/pkg'),
        ):
            result = plan(options)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('Update sets', result.stdout)
            self.assertIn('-u ' + expected, result.stdout)

    def test_live_only_run_does_not_add_empty_update(self):
        result = plan('--no-security --live')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('@live-rebuild', result.stdout)
        self.assertNotIn('Update sets', result.stdout)


class PortageMaintenance(unittest.TestCase):
    def test_repairs_are_enabled_only_outside_pretend(self):
        for options, action in (('', '--fix'), ('--pretend', '--check')):
            result = plan(options)
            self.assertEqual(result.returncode, 0, result.stderr)
            commands = [shlex.split(line.split('Plan command: ', 1)[1])
                        for line in result.stdout.splitlines()
                        if 'Plan command: emaint ' in line and not line.rstrip().endswith('sync')]
            self.assertTrue(any(args[-1] == 'merges' for args in commands))
            self.assertTrue(any(args[-1] == 'world' for args in commands))
            for args in commands:
                self.assertIn(action, args)
                self.assertNotIn('-p', args)
                self.assertNotIn('--fix' if action == '--check' else '--check', args)
                if args[-1] == 'merges':
                    self.assertIn('--yes', args)


class PortageCleanup(unittest.TestCase):
    def test_build_directories_are_never_removed_globally(self):
        for mode in ('fetch', 'pretend', 'debug'):
            result = bash(f'''
fetch=false; pretend=false; debug=false; {mode}=true
pgrep() {{ printf 'UNEXPECTED_CHECK'; }}
rm() {{ printf 'UNEXPECTED_DELETE'; }}
clean_portage_dir
''')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn('UNEXPECTED', result.stdout)
            self.assertIn('managed by Portage', result.stdout)


class ExitHandling(unittest.TestCase):
    def test_signals_preserve_status_and_logs(self):
        for command, expected in (
            ('kill -TERM $$', 143), ('kill -INT $$', 130), ('kill -HUP $$', 129),
            ('exit 0', 0), ('exit 7', 7),
        ):
            with self.subTest(command=command), tempfile.TemporaryDirectory() as directory:
                logs = Path(directory)
                (logs / 'command.log').write_text('test output')
                (logs / 'steps.tsv').write_text('')
                result = bash(f'''
LOGS='{logs}'; RUN_INITIALIZED=true; RUN_STARTED=$SECONDS
notify_mode=never; PLAN_TITLES=()
install_traps
{command}
''')
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertTrue((logs / 'command.log').exists())
                self.assertIn(f'exit {expected}', (logs / 'summary.txt').read_text())


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
    def test_equals_and_grouped_flags_at_end(self):
        for options in ('--color=false -SC', '-SC --color=false', '-SCP --color=false'):
            result = bash(f'''
opt_parse {options}
printf '%s %s %s' "$color" "$sync" "$clean"
''')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, 'false true true')

    def test_equals_preserves_spaces_and_following_options(self):
        result = bash('''
opt_parse '--packages=app-one/pkg app-two/pkg' --color=false
printf '%s:%s' "$packages" "$color"
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'app-one/pkg app-two/pkg:false')

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
    def test_perl_maintenance_follows_effective_binary_mode(self):
        for mode, available, skipped in (
            ('false', True, False), ('true', True, False), ('only', False, True),
            ('auto', True, False), ('auto', False, False),
            ('autoonly', True, True), ('autoonly', False, False),
        ):
            with self.subTest(mode=mode, available=available):
                result = plan(f'--binary {mode} --exclude app-test/pkg', setup=f'''
check_pkg() {{ return {0 if available else 1}; }}
EMERGE_OPTS='--jobs=2'
''')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual('Binary-only policy' in result.stdout, skipped)
                commands = [shlex.split(line.split('Plan command: ', 1)[1])
                            for line in result.stdout.splitlines()
                            if 'Plan command:' in line and '/usr/sbin/perl-cleaner' in line]
                self.assertEqual(len(commands), 0 if skipped else 1)
                if commands:
                    self.assertEqual(commands[0][-2:], ['/usr/sbin/perl-cleaner', '--all'])
                    options = next(arg.split('=', 1)[1].split() for arg in commands[0]
                                   if arg.startswith('EMERGE_DEFAULT_OPTS='))
                    self.assertNotIn('-k', options)
                    self.assertNotIn('-K', options)
                    self.assertIn('--exclude=app-test/pkg', options)
                    self.assertIn('--jobs=2', options)
                # The Perl step must not alter the binary policy for later callers.
                revdep = next(line for line in result.stdout.splitlines()
                              if 'Plan command:' in line and 'revdep-rebuild' in line)
                if mode == 'true' or (mode == 'auto' and available):
                    self.assertIn('-k', shlex.split(revdep))

    def test_preserved_rebuild_honors_selected_options(self):
        result = plan(
            "--binary only --exclude 'sys-devel/* app-test/pkg' --pretend",
            setup="EMERGE_OPTS='--jobs=2 --load-average=4'",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        line = next(line for line in result.stdout.splitlines() if '@preserved-rebuild' in line)
        args = shlex.split(line.split('Plan command: ', 1)[1])
        self.assertIn('-K', args)
        self.assertIn('-p', args)
        self.assertIn('--jobs=2', args)
        self.assertIn('--load-average=4', args)
        self.assertIn('--exclude=sys-devel/*', args)
        self.assertIn('--exclude=app-test/pkg', args)
        self.assertEqual(args[args.index('--color') + 1], 'n')

    def test_exclusions_survive_rebuilder_option_splitting(self):
        result = plan("--exclude 'sys-kernel/gentoo* sys-kernel/bliss-kernel-bin'")
        self.assertEqual(result.returncode, 0, result.stderr)
        for tool in ('perl-cleaner', 'revdep-rebuild'):
            line = next(line for line in result.stdout.splitlines()
                        if 'Plan command:' in line and tool in line)
            args = shlex.split(line.split('Plan command: ', 1)[1])
            if tool == 'perl-cleaner':
                options = next(arg.split('=', 1)[1].split() for arg in args
                               if arg.startswith('EMERGE_DEFAULT_OPTS='))
                self.assertNotIn('--', args)
            else:
                options = args[args.index('--') + 1:]
            # Reproduce the unquoted option expansion used by perl-cleaner.
            split = subprocess.run(
                ['bash', '-c', 'options="$*"; printf "%s\\n" $options', '_', *options],
                text=True, capture_output=True, check=True,
            ).stdout.splitlines()
            self.assertIn('--exclude=sys-kernel/gentoo*', split)
            self.assertIn('--exclude=sys-kernel/bliss-kernel-bin', split)
            self.assertNotIn('sys-kernel/bliss-kernel-bin', split)

    def test_source_perl_rebuild_preserves_defaults_and_failure(self):
        result = bash('''
dry_run=false; debug=false
color_args=(--color n); exclude_args=(--exclude=app-test/pkg)
emerge_opts_args=(--jobs=2 --usepkg=n --getbinpkg=n)
binary_args=(); pretend_args=()
EMERGE_DEFAULT_OPTS=original
portageq() { printf -- '--load-average=4 --jobs=3'; }
command() {
    [ "$1" = env ] && [ "$3" = /usr/sbin/perl-cleaner ] &&
    [ "$4" = --all ] && [ "$#" = 4 ] || return 99
    env "$2" bash -c 'printf "%s\\n" "$EMERGE_DEFAULT_OPTS"; exit 42'
}
rebuild_perl
ret=$?
printf 'parent=%s\\n' "$EMERGE_DEFAULT_OPTS"
exit "$ret"
''')
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertIn('--load-average=4 --jobs=3 -v --fail-clean=y', result.stdout)
        self.assertIn('--exclude=app-test/pkg --jobs=2 --usepkg=n --getbinpkg=n', result.stdout)
        self.assertIn('parent=original', result.stdout)

    def test_perl_rebuild_stops_if_defaults_cannot_be_read(self):
        result = bash('''
dry_run=false; debug=false
color_args=(); exclude_args=(); emerge_opts_args=(); binary_args=(); pretend_args=()
portageq() { return 42; }
command() { echo UNEXPECTED_EXECUTION; }
rebuild_perl
''')
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertNotIn('UNEXPECTED_EXECUTION', result.stdout)

    def test_perl_rebuild_allows_unset_portage_defaults(self):
        result = bash('''
dry_run=false; debug=false
color_args=(); exclude_args=(); emerge_opts_args=(); binary_args=(); pretend_args=()
portageq() { printf '\\n'; return 1; }
command() { printf '%s\\n' "$@"; }
rebuild_perl
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('/usr/sbin/perl-cleaner\n--all', result.stdout)

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


class ToolchainProfiles(unittest.TestCase):
    def test_native_latest_selection_does_not_count_listing_lines(self):
        for function, utility in (('Last_gcc', 'gcc-config'), ('Last_binutils', 'binutils-config')):
            result = bash(f'''
fetch=false; pretend=false; debug=false
function /usr/bin/{utility} {{
    case "$1" in
        -l) printf '  [1] aarch64-linux-gnu-old\\n\\n  [2] x86_64-pc-linux-gnu-new *\\n' ;;
        latest) printf 'SELECT_NATIVE_LATEST\\n' ;;
        *) echo 'Invalid numeric profile' >&2; return 42 ;;
    esac
}}
function /usr/sbin/env-update {{ printf 'ENV_UPDATE\\n'; }}
function . {{
    [ "$1" = /etc/profile ] || return 43
    export GLUS_TEST_PROFILE=loaded
}}
{function}
ret=$?
printf '%s' "$GLUS_TEST_PROFILE"
exit "$ret"
''')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, 'SELECT_NATIVE_LATEST\nENV_UPDATE\nloaded')

    def test_selection_and_environment_failures_propagate(self):
        for function, utility in (('Last_gcc', 'gcc-config'), ('Last_binutils', 'binutils-config')):
            for fail_at in (1, 2, 3):
                result = bash(f'''
fetch=false; pretend=false; debug=false; calls=0
step() {{ ((++calls)); [ "$calls" -ne {fail_at} ] || return 42; }}
function /usr/bin/{utility} {{ step; }}
function /usr/sbin/env-update {{ step; }}
function . {{ step; }}
{function}
ret=$?
printf '%s' "$calls"
exit "$ret"
''')
                self.assertEqual(result.returncode, 42, result.stderr)
                self.assertEqual(result.stdout, str(fail_at))

    def test_simulation_and_fetch_do_not_select_profiles(self):
        for function, utility in (('Last_gcc', 'gcc-config'), ('Last_binutils', 'binutils-config')):
            for mode in ('fetch', 'pretend', 'debug'):
                result = bash(f'''
fetch=false; pretend=false; debug=false; {mode}=true
function /usr/bin/{utility} {{ printf 'UNEXPECTED_SELECTION'; return 42; }}
{function}
''')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, '')


class ToolchainFailures(unittest.TestCase):
    def test_failure_before_or_after_compile_is_reported(self):
        for fail_at in (1, 2):
            for flag, expected_errors in (('', 1), ('--no-error-count', 0)):
                with self.subTest(fail_at=fail_at, flag=flag), tempfile.TemporaryDirectory() as logs:
                    result = bash(f'''
LOGS='{logs}'; errors=0; email=''; quiet=true; NO_STDOUT=true
fetch=false; pretend=false; debug=false; calls=0
color_args=(); exclude_args=(); binary_args=(); pretend_args=(); emerge_opts_args=()
update_devel() {{
    ((++calls))
    if [ "$calls" -eq {fail_at} ]; then echo TOOLCHAIN_FAILED >&2; return 42; fi
    return 0
}}
find_emerge() {{ printf true; }}
emaint() {{ :; }}
compile {flag} -u portage
ret=$?
printf 'calls=%s errors=%s' "$calls" "$errors"
exit "$ret"
''')
                    self.assertEqual(result.returncode, 42, result.stderr)
                    self.assertEqual(result.stdout, f'calls={fail_at} errors={expected_errors}')
                    self.assertIn('TOOLCHAIN_FAILED', result.stderr)

    def test_each_preparation_step_stops_on_failure(self):
        for fail_at in range(1, 7):
            result = bash(f'''
fetch=false; pretend=false; debug=false; calls=0
step() {{ ((++calls)); [ "$calls" -ne {fail_at} ] || return 42; }}
etc-update() {{ step; }}
Last_binutils() {{ step; }}
Last_gcc() {{ step; }}
eselect() {{ [ "$*" != 'modules has python' ] || return 0; step; }}
update_devel
ret=$?
printf '%s' "$calls"
exit "$ret"
''')
            self.assertEqual(result.returncode, 42, result.stderr)
            self.assertEqual(result.stdout, str(fail_at))

    def test_python_selector_is_optional(self):
        for available in ('installed', 'missing-module', 'missing-command'):
            with self.subTest(available=available):
                setup = "PATH=/nonexistent" if available == 'missing-command' else f'''
eselect() {{
    if [ "$*" = 'modules has python' ]; then
        [ '{available}' = installed ]; return
    fi
    printf 'SELECT:%s\\n' "$*"
}}
'''
                result = bash('''
fetch=false; pretend=false; debug=false
etc-update() { printf 'CONFIG:%s\\n' "$*"; }
Last_binutils() { :; }
Last_gcc() { :; }
''' + setup + '\nupdate_devel\n')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('CONFIG:--automode -5 /etc/python-exec', result.stdout)
                self.assertEqual(result.stdout.count('SELECT:python update --python3'),
                                 2 if available == 'installed' else 0)
                self.assertEqual('Skipping Python selector update' in result.stdout,
                                 available != 'installed')

    def test_toolchain_environment_survives_command_capture(self):
        with tempfile.TemporaryDirectory() as logs:
            result = bash(f'''
LOGS='{logs}'; errors=0; email=''; quiet=true; NO_STDOUT=true
pretend=false; debug=false
update_devel() {{ export GLUS_TEST_COMPILER=new; }}
command --discard-output update_devel
printf '%s' "$GLUS_TEST_COMPILER"
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'new')


class ErrorOutput(unittest.TestCase):
    def run_command(self, exit_code=7, flags='', quiet='true', pretend='false'):
        with tempfile.TemporaryDirectory(prefix='glus-test-') as logs:
            return bash(f'''
LOGS='{logs}'; quiet={quiet}; pretend={pretend}; debug=false; email=''; errors=0
if [ "$quiet" = true ]; then NO_STDOUT=true; fi
command {flags} bash -c 'echo diagnostic-output; echo diagnostic-error >&2; exit {exit_code}'
ret=$?
printf 'errors=%s\\n' "$errors"
exit "$ret"
''')

    def test_quiet_failure_preserves_status_and_diagnostics(self):
        result = self.run_command()
        self.assertEqual(result.returncode, 7)
        self.assertEqual(result.stdout, 'errors=1\n')
        self.assertIn('[ERROR] Command failed (exit 7):', result.stderr)
        self.assertIn('diagnostic-output\n', result.stderr)
        self.assertIn('diagnostic-error\n', result.stderr)

    def test_quiet_success_remains_silent(self):
        result = self.run_command(exit_code=0)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, 'errors=0\n')
        self.assertEqual(result.stderr, '')

    def test_discarded_output_is_recovered_on_failure(self):
        result = self.run_command(flags='--discard-output', quiet='false')
        self.assertEqual(result.returncode, 7)
        self.assertIn('diagnostic-error\n', result.stderr)

    def test_retry_failure_does_not_increment_final_error_count(self):
        result = self.run_command(flags='--no-error-count')
        self.assertEqual(result.returncode, 7)
        self.assertEqual(result.stdout, 'errors=0\n')
        self.assertIn('diagnostic-error\n', result.stderr)

    def test_pretend_preserves_error_output(self):
        result = self.run_command(flags='--pretend-safe', pretend='true')
        self.assertEqual(result.returncode, 7)
        self.assertIn('diagnostic-error\n', result.stderr)

    def test_verbose_failure_does_not_duplicate_output(self):
        result = self.run_command(quiet='false')
        self.assertEqual(result.returncode, 7)
        self.assertEqual(result.stdout.count('diagnostic-error\n'), 1)
        self.assertNotIn('diagnostic-error\n', result.stderr)


if __name__ == "__main__":
    unittest.main()
