"""Runtime tests use temporary directories and fake maintenance/network commands."""

import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import tempfile
import time
import unittest

from test_glus import FUNCTIONS, bash, plan


def runtime_setup(root, *, mock_perl=True):
    return f'''
SYS_CONF_FILE={shlex.quote(str(root / 'glus.conf'))}
GLUS_LOG_DIR={shlex.quote(str(root / 'logs'))}
GLUS_LOCK_FILE={shlex.quote(str(root / 'lock'))}
GLUS_FETCH_DELAY=0; GLUS_CANCEL_GRACE=1
errors=0
get_versions() {{ :; }}
change_versions() {{ skip_step 'No systemd change'; }}
update_devel() {{ :; }}
etc_update_portage() {{ :; }}
ensure_crypt() {{ skip_step 'Headers present'; }}
find_emerge() {{ printf fake_emerge; }}
fake_emerge() {{ printf 'Fake emerge: %s\\n' "$*"; return "${{MOCK_EXIT:-0}}"; }}
emaint() {{ printf 'Fake emaint: %s\\n' "$*"; }}
{'rebuild_perl() { command true; }' if mock_perl else ''}
rebuild_dependencies() {{ command true; }}
'''


class PersistentLogs(unittest.TestCase):
    def test_disabled_colors_reach_sync_children_and_logs(self):
        for mode in ('false', 'auto'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                result = bash(runtime_setup(root) + f'''
emaint() {{
    bash -c 'if [ "$NOCOLOR" = true ] && [ "$NO_COLOR" = 1 ]; then
        printf "plain sync output\\n"
    else
        printf "\\033[32mcolored sync output\\033[0m\\n"
    fi'
}}
main --sync --no-security --color {mode}
''')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('plain sync output', result.stdout)
                self.assertNotIn('\x1b', result.stdout + result.stderr)
                run = next((root / 'logs').glob('run-*'))
                self.assertTrue(any('plain sync output' in log.read_text()
                                    for log in run.glob('command-*.log')))
                for log in run.glob('*.log'):
                    self.assertNotIn(b'\x1b', log.read_bytes())

    def test_complete_script_with_isolated_configuration(self):
        script = Path(__file__).resolve().parents[1] / 'glus.sh'
        for mode in ('--plan', '--debug', '--pretend', ''):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                config_dir = root / 'etc' / 'portage'
                config_dir.mkdir(parents=True)
                (config_dir / 'glus.conf').write_text(runtime_setup(root))
                args = ['bash', str(script), '--no-sync', '--no-security', '--color', 'false']
                if mode:
                    args.append(mode)
                result = subprocess.run(args, capture_output=True, text=True, timeout=10,
                                        env={'PATH': '/usr/bin:/bin', 'LC_ALL': 'C', 'ETCDIR': str(root / 'etc')})
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual((root / 'logs').exists(), mode not in ('--plan', '--debug'))
                if mode not in ('--plan', '--debug'):
                    summary = next((root / 'logs').glob('run-*/summary.txt')).read_text()
                    self.assertIn('success (exit 0)', summary)

    def test_success_failure_and_unique_command_logs(self):
        for status in (0, 2):
            with self.subTest(status=status), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                result = bash(runtime_setup(root) + f'''
MOCK_EXIT={status}
main --no-sync --no-security --color false --quiet
''')
                self.assertEqual(result.returncode, status, result.stderr)
                runs = list((root / 'logs').glob('run-*'))
                self.assertEqual(len(runs), 1)
                run = runs[0]
                self.assertEqual(run.stat().st_mode & 0o777, 0o700)
                summary = (run / 'summary.txt').read_text()
                self.assertIn(f'exit {status}', summary)
                self.assertIn('Logs: ', result.stdout)
                self.assertIn('skipped:', summary)
                logs = list(run.glob('command-*.log'))
                self.assertGreater(len(logs), 1)
                self.assertTrue(any('Fake emerge:' in log.read_text() for log in logs))
                self.assertTrue(all(Path(str(log) + '.meta').exists() for log in logs))
                rows = (run / 'steps.tsv').read_text().splitlines()
                indices = [row.split('\t')[0] for row in rows]
                self.assertEqual(len(indices), len(set(indices)))
                if status:
                    self.assertIn('previous step failed', summary)

    def test_retention_only_removes_completed_marked_runs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            logs = root / 'logs'
            logs.mkdir()
            for name in ('run-old', 'run-unfinished', 'run-foreign', 'run-recent'):
                run = logs / name
                run.mkdir()
                if name != 'run-foreign':
                    (run / '.glus-run').touch()
                if name != 'run-unfinished':
                    (run / 'summary.txt').touch()
                if name != 'run-recent':
                    os.utime(run, (time.time() - 86400 * 5,) * 2)
            (logs / 'run-link').symlink_to(logs / 'run-foreign', target_is_directory=True)
            result = bash(runtime_setup(root) + '\nmain --no-sync --no-security --color false --log-retention-days 1\n')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((logs / 'run-old').exists())
            for name in ('run-unfinished', 'run-foreign', 'run-recent', 'run-link'):
                self.assertTrue((logs / name).exists())

    def test_rotation_count_defaults_configuration_and_cli_override(self):
        for config, options, expected in (
            ('', '', 10), ('GLUS_LOG_ROTATIONS=4\n', '', 4),
            ('GLUS_LOG_ROTATIONS=4\n', '--log-rotations 3', 3),
            ('GLUS_LOG_ROTATIONS=0\n', '', 13),
        ):
            with self.subTest(config=config, options=options), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / 'glus.conf').write_text(config)
                logs = root / 'logs'
                logs.mkdir()
                for i in range(12):
                    run = logs / f'run-old-{i:02d}'
                    run.mkdir()
                    (run / '.glus-run').touch()
                    (run / 'summary.txt').write_text('completed\n')
                    timestamp = time.time() - 3600 + i
                    os.utime(run, (timestamp, timestamp))
                unfinished = logs / 'run-unfinished'
                unfinished.mkdir()
                (unfinished / '.glus-run').touch()
                foreign = logs / 'run-foreign'
                foreign.mkdir()
                (foreign / 'summary.txt').touch()
                (logs / 'run-link').symlink_to(foreign, target_is_directory=True)
                result = bash(runtime_setup(root) + f'''
main --packages-only sys-libs/readline --quiet --color false {options}
''')
                self.assertEqual(result.returncode, 0, result.stderr)
                kept = [p for p in logs.glob('run-*') if not p.is_symlink()
                        and (p / '.glus-run').exists() and (p / 'summary.txt').exists()]
                self.assertEqual(len(kept), expected)
                old_kept = sorted(p.name for p in kept if p.name.startswith('run-old-'))
                self.assertEqual(old_kept, [f'run-old-{i:02d}' for i in range(13 - expected, 12)])
                self.assertTrue(unfinished.exists())
                self.assertTrue(foreign.exists())
                self.assertTrue((logs / 'run-link').is_symlink())

    def test_plan_creates_no_runtime_artifacts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = bash(runtime_setup(root) + '''
curl() { echo UNEXPECTED_NETWORK; return 1; }
main --plan --color false --slack-webhook https://hooks.slack.com/services/T/B/SECRET --notify always
''')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn('UNEXPECTED_NETWORK', result.stdout)
            self.assertNotIn('SECRET', result.stdout + result.stderr)
            self.assertFalse((root / 'logs').exists())
            self.assertFalse((root / 'lock').exists())

    def test_log_creation_failure_prevents_maintenance(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'logs').write_text('not a directory')
            result = bash(runtime_setup(root) + '\nmain --no-sync --color false\n')
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('Fake emerge', result.stdout)

    def test_finalizer_is_idempotent(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = bash(runtime_setup(root) + '''
notify_run() { printf 'NOTIFY_ONCE\n'; }
main --no-sync --no-security --color false
finalize_run 0
''')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.count('NOTIFY_ONCE'), 1)


class SharedPlan(unittest.TestCase):
    def test_quiet_summary_has_command_times_without_streaming_build_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = bash(runtime_setup(root) + '''
main --packages-only sys-libs/readline --color false --quiet
''')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn('Fake emerge:', result.stdout)
            self.assertIn('Update selected packages: sys-libs/readline', result.stdout)
            self.assertRegex(result.stdout, r'fake_emerge \(fetch\): \d+s, exit 0')
            self.assertRegex(result.stdout, r'fake_emerge: \d+s, exit 0')
            run = next((root / 'logs').glob('run-*'))
            self.assertTrue(any('Fake emerge:' in p.read_text() for p in run.glob('command-*.log')))
            self.assertEqual(result.stdout, (run / 'summary.txt').read_text())

    def test_targeted_run_only_executes_selected_package_and_records_status(self):
        for status in (0, 2):
            with self.subTest(status=status), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                result = bash(runtime_setup(root) + f'''
update_devel() {{ echo UNEXPECTED_TOOLCHAIN; return 42; }}
emaint() {{ echo UNEXPECTED_MAINTENANCE; return 42; }}
rebuild_perl() {{ echo UNEXPECTED_PERL; return 42; }}
MOCK_EXIT={status}
main --packages-only dev-lang/rust-bin --clean --color false
''')
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertNotIn('UNEXPECTED', result.stdout + result.stderr)
                run = next((root / 'logs').glob('run-*'))
                steps = (run / 'steps.tsv').read_text().splitlines()
                self.assertEqual(len(steps), 1)
                self.assertEqual(steps[0].split('\t')[1], 'failed' if status else 'completed')
                commands = (run / 'commands.tsv').read_text().splitlines()
                self.assertEqual(len(commands), 1 if status else 2)
                self.assertTrue(all('dev-lang/rust-bin' in line for line in commands))

    def test_system_fallback_only_runs_after_failure(self):
        for status in (0, 1):
            result = bash(f'''
calls=0
compile() {{ ((++calls)); [ "$calls" -gt 1 ] && return 0; return {status}; }}
update_system
ret=$?
printf '%s' "$calls"
exit "$ret"
''')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, '1' if status == 0 else '2')

    def test_step_order_matches_execution(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            setup = runtime_setup(root)
            options = '--no-sync --no-security --color false'
            planned = bash(setup + '\nmain --plan ' + options)
            executed = bash(setup + '\nmain ' + options)
            self.assertEqual(planned.returncode, 0, planned.stderr)
            self.assertEqual(executed.returncode, 0, executed.stderr)
            titles = [line.split('Plan step: ', 1)[1] for line in planned.stdout.splitlines() if 'Plan step: ' in line]
            run = next((root / 'logs').glob('run-*'))
            actual = [line.split('\t')[4] for line in (run / 'steps.tsv').read_text().splitlines()]
            self.assertEqual(len(titles), len(actual))
            for expected, recorded in zip(titles, actual):
                self.assertTrue(recorded == expected or recorded.startswith(expected + ' ('), recorded)

    def test_rebuilders_share_options(self):
        result = plan("--binary only --exclude 'app-test/*'", setup="EMERGE_OPTS='--jobs=2'")
        self.assertEqual(result.returncode, 0, result.stderr)
        for line in result.stdout.splitlines():
            if any(name in line for name in ('/fake/emerge ', 'perl-cleaner ', 'revdep-rebuild ')):
                self.assertIn('-K', line)
                self.assertIn('--exclude', line)
                self.assertIn('--jobs=2', line)

    def test_binary_only_perl_skip_is_recorded_without_running_commands(self):
        for mode in ('only', 'autoonly'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                result = bash(runtime_setup(root, mock_perl=False) + f'''
check_pkg() {{ return 0; }}
portageq() {{ echo UNEXPECTED_QUERY; return 42; }}
main --no-sync --no-security --color false --quiet --binary {mode}
''')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn('UNEXPECTED_QUERY', result.stdout)
                run = next((root / 'logs').glob('run-*'))
                rows = [line.split('\t') for line in (run / 'steps.tsv').read_text().splitlines()]
                perl = next(row for row in rows if row[4].startswith('Update Perl packages'))
                self.assertEqual(perl[1:3], ['skipped', '0'])
                self.assertIn('Binary-only policy', perl[4])
                self.assertIn('Binary-only policy', (run / 'summary.txt').read_text())
                self.assertNotIn('perl-cleaner', (run / 'commands.tsv').read_text())


class RetryControls(unittest.TestCase):
    def simulate(self, status=1, attempts=3, succeed_at=99):
        return bash(f'''
errors=0; fetch=true; pretend=false; debug=false; fetch_attempts={attempts}; fetch_delay=4
color_args=(); exclude_args=(); binary_args=(); pretend_args=(); emerge_opts_args=()
find_emerge() {{ printf fake; }}
calls=0
command() {{
    if [[ " $* " == *' -f '* ]]; then
        ((++calls))
        [ "$calls" -lt {succeed_at} ] && return {status}
    fi
    return 0
}}
sleep() {{ printf 'WAIT:%s\\n' "$1"; }}
compile -u portage
ret=$?
printf 'calls=%s errors=%s\\n' "$calls" "$errors"
exit "$ret"
''')

    def test_total_attempts_delay_and_final_failure(self):
        result = self.simulate()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout.count('WAIT:4'), 2)
        self.assertIn('calls=3 errors=1', result.stdout)

    def test_successful_retry_is_not_a_final_error(self):
        result = self.simulate(succeed_at=2)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count('WAIT:4'), 1)
        self.assertIn('calls=2 errors=0', result.stdout)

    def test_nonretryable_exit_codes_stop_immediately(self):
        for status in (2, 126, 127, 130, 143):
            result = self.simulate(status=status)
            self.assertEqual(result.returncode, status)
            self.assertNotIn('WAIT:', result.stdout)
            self.assertIn('calls=1 errors=1', result.stdout)

    def test_known_bad_arguments_are_not_retried(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'command.log'
            path.write_text('!!! invalid-name is not a valid package atom.\n')
            result = bash(f'LAST_COMMAND_LOG={shlex.quote(str(path))}\nfetch_retryable 1\n')
            self.assertEqual(result.returncode, 1)

    def test_rejects_invalid_numbers_before_execution(self):
        for option, value in (('--fetch-attempts', '0'), ('--fetch-delay', 'abc'),
                              ('--cancel-grace', '999'), ('--log-retention-days', '01'),
                              ('--log-rotations', 'abc'), ('--log-rotations', '100001')):
            result = plan(f'{option} {value}')
            self.assertEqual(result.returncode, 2)
            self.assertNotIn('Plan step:', result.stdout)


class SlackNotifications(unittest.TestCase):
    def test_email_and_slack_both_receive_the_final_result(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'summary.txt').write_text('summary\n')
            result = bash(f'''
LOGS={shlex.quote(directory)}; notify_mode=always; email=admin@example.com
slack_webhook=https://hooks.slack.com/services/T/B/SECRET
mailx() {{ cat >"$LOGS/email-message"; }}
curl() {{ cat >/dev/null; printf ok; }}
notify_run 0
''')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((root / 'email-message').read_text(), 'summary\n')
            self.assertEqual((root / 'notifications.log').read_text(), 'Email: sent\nSlack: sent\n')

    def test_payload_and_secret_handling(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'summary.txt').write_text('GLUS "host": failed\nDuration: 1s\nSteps: 1\nLogs: /tmp/café\\logs\n')
            result = bash(f'''
LOGS={shlex.quote(directory)}; notify_mode=always
slack_webhook=https://hooks.slack.com/services/T/B/TESTSECRET
curl() {{ printf '%s\\n' "$@" >"$LOGS/curl-args"; cat >"$LOGS/curl-config"; printf ok; }}
notify_run 1
''')
            self.assertEqual(result.returncode, 0, result.stderr)
            data = json.loads((root / 'slack.json').read_text())
            self.assertEqual(data['blocks'][0]['text']['type'], 'plain_text')
            self.assertIn('café\\logs', data['blocks'][0]['text']['text'])
            self.assertNotIn('TESTSECRET', (root / 'curl-args').read_text())
            self.assertIn('TESTSECRET', (root / 'curl-config').read_text())
            self.assertNotIn('TESTSECRET', result.stdout + result.stderr)
            self.assertIn('Slack: sent', (root / 'notifications.log').read_text())

    def test_notification_policy_and_simulation(self):
        cases = [('failures', 0, '', False), ('failures', 1, '', True),
                 ('always', 0, '', True), ('never', 1, '', False),
                 ('always', 1, 'dry_run=true', False),
                 ('always', 1, 'pretend=true', False),
                 ('always', 1, 'debug=true', False)]
        for mode, status, flags, send in cases:
            with self.subTest(mode=mode, status=status, flags=flags), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / 'summary.txt').write_text('summary')
                result = bash(f'''
LOGS={shlex.quote(directory)}; notify_mode={mode}
slack_webhook=https://hooks.slack.com/services/T/B/SECRET
curl() {{ cat >/dev/null; echo CALLED >"$LOGS/called"; printf ok; }}
{flags}
notify_run {status}
''')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual((root / 'called').exists(), send)

    def test_slack_failure_does_not_change_update_status(self):
        for status in (0, 2):
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / 'glus.conf').write_text('GLUS_SLACK_WEBHOOK="https://hooks.slack.com/services/T/B/SECRET"\nGLUS_NOTIFY=always\n')
                result = bash(runtime_setup(root) + f'''
MOCK_EXIT={status}
curl() {{ cat >/dev/null; return 22; }}
main --no-sync --no-security --color false
''')
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertIn('Slack notification failed', result.stderr)
                self.assertNotIn('SECRET', result.stdout + result.stderr)

    def test_invalid_webhook_is_rejected_without_revealing_it(self):
        result = plan('--slack-webhook https://example.com/SECRET')
        self.assertEqual(result.returncode, 2)
        self.assertNotIn('SECRET', result.stdout + result.stderr)

    def test_no_slack_overrides_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'glus.conf').write_text('GLUS_SLACK_WEBHOOK="https://hooks.slack.com/services/T/B/SECRET"\nGLUS_NOTIFY=always\n')
            result = bash(runtime_setup(root) + '''
curl() { echo UNEXPECTED; return 22; }
main --no-sync --no-security --color false --no-slack
''')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn('UNEXPECTED', result.stdout + result.stderr)


class ProcessCancellation(unittest.TestCase):
    def test_signal_stops_worker_and_grandchild_and_preserves_logs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            code = runtime_setup(root) + f'''
fake_emerge() {{
    sleep 60 &
    child=$!
    printf '%s' "$child" >{shlex.quote(str(root / 'child.pid'))}
    wait "$child"
}}
main --no-sync --no-security --color false
'''
            proc = subprocess.Popen(['bash', '--noprofile', '--norc'], stdin=subprocess.PIPE,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                    env={'PATH': '/usr/bin:/bin', 'LC_ALL': 'C'})
            try:
                proc.stdin.write(FUNCTIONS + '\n' + code)
                proc.stdin.close()
                proc.stdin = None
                deadline = time.monotonic() + 5
                while not (root / 'child.pid').exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue((root / 'child.pid').exists())
                child = int((root / 'child.pid').read_text())
                proc.send_signal(signal.SIGTERM)
                stdout, stderr = proc.communicate(timeout=5)
                self.assertEqual(proc.returncode, 143, stdout + stderr)
                stat = Path(f'/proc/{child}/stat')
                if stat.exists():
                    self.assertEqual(stat.read_text().split()[2], 'Z')
                run = next((root / 'logs').glob('run-*'))
                summary = (run / 'summary.txt').read_text()
                self.assertIn('interrupted (exit 143)', summary)
                self.assertIn('Update portage', summary)
                self.assertTrue(list(run.glob('command-*.log')))
            finally:
                if proc.poll() is None:
                    proc.send_signal(signal.SIGTERM)
                    proc.communicate(timeout=5)


if __name__ == '__main__':
    unittest.main()
