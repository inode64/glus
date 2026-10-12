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


def runtime_setup(root):
    return f'''
SYS_CONF_FILE={shlex.quote(str(root / 'glus.conf'))}
GLUS_LOG_DIR={shlex.quote(str(root / 'logs'))}
GLUS_LOCK_FILE={shlex.quote(str(root / 'lock'))}
GLUS_FETCH_DELAY=0; GLUS_CANCEL_GRACE=1
errors=0
sleep() {{ :; }}
get_versions() {{ :; }}
change_versions() {{ skip_step 'No systemd change'; }}
update_devel() {{ :; }}
etc_update_portage() {{ :; }}
ensure_crypt() {{ skip_step 'Headers present'; }}
find_emerge() {{ printf fake_emerge; }}
fake_emerge() {{ printf 'Fake emerge: %s\\n' "$*"; return "${{MOCK_EXIT:-0}}"; }}
emaint() {{ printf 'Fake emaint: %s\\n' "$*"; }}
rebuild_perl() {{ command true; }}
rebuild_dependencies() {{ command true; }}
'''


class PersistentLogs(unittest.TestCase):
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
        for status in (0, 1):
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

    def test_plan_creates_no_runtime_artifacts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = bash(runtime_setup(root) + '''
curl() { echo UNEXPECTED_NETWORK; return 1; }
main --plan --color false --notify always
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
            self.assertEqual(titles, actual)

    def test_rebuilders_share_options(self):
        result = plan("--binary only --exclude 'app-test/*'", setup="EMERGE_OPTS='--jobs=2'")
        self.assertEqual(result.returncode, 0, result.stderr)
        for line in result.stdout.splitlines():
            if any(name in line for name in ('/fake/emerge ', 'perl-cleaner ', 'revdep-rebuild ')):
                self.assertIn('-K', line)
                self.assertIn('--exclude', line)
                self.assertIn('--jobs=2', line)








if __name__ == '__main__':
    unittest.main()
