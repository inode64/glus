import unittest
from test_glus import bash, plan


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

    def test_rebuilders_share_options(self):
            result = plan("--binary only --exclude 'app-test/*'", setup="EMERGE_OPTS='--jobs=2'")
            self.assertEqual(result.returncode, 0, result.stderr)
            for line in result.stdout.splitlines():
                if any(name in line for name in ('/fake/emerge ', 'perl-cleaner ', 'revdep-rebuild ')):
                    self.assertIn('-K', line)
                    self.assertIn('--exclude', line)
                    self.assertIn('--jobs=2', line)
