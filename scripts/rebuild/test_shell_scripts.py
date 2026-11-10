# DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
"""Exercise shell gates with fake Swift commands; no Swift build in these fixtures."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).parent


class ShellTests(unittest.TestCase):
    def test_parse_handles_spaces_and_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            folder = root / 'Sources/HelmUI'
            folder.mkdir(parents=True)
            (folder / 'With space.swift').write_text('// syntax fixture')
            for status in (0, 1):
                command = f'swiftc() {{ return {status}; }}; export -f swiftc; bash "$1" "$2"'
                result = subprocess.run(['bash', '-c', command, 'fixture', str(SCRIPTS / 'parse_check_ui.sh'), str(root)], capture_output=True, text=True)
                self.assertEqual(result.returncode, status)
                self.assertIn('1 files', result.stdout)
                self.assertIn('syntax only', result.stdout)

    def test_parse_empty_is_explicit_not_run(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(['bash', str(SCRIPTS / 'parse_check_ui.sh'), directory], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('NOT RUN', result.stdout)

    def test_runner_failure_zero_skipped_and_success(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts = root / 'scripts/rebuild'
            scripts.mkdir(parents=True)
            shutil.copyfile(SCRIPTS / 'run_all.sh', scripts / 'run_all.sh')
            (root / 'scripts/static_checks.sh').write_text('exit 0\n')
            (scripts / 'parse_check_ui.sh').write_text('exit 0\n')
            (scripts / 'check_core_type_names.py').write_text('')
            (scripts / 'check_coverage.py').write_text('print("fixture coverage")\n')
            (scripts / 'test_fixture.py').write_text('import unittest\nclass Fixture(unittest.TestCase):\n def test_one(self): pass\n')
            for name in ('test_static_checks.py', 'test_privacy_check.py'):
                (root / 'scripts' / name).write_text('import unittest\nclass Fixture(unittest.TestCase):\n def test_one(self): pass\n')
            for count, skipped, build_status, expected in ((2, 0, 0, 0), (0, 0, 0, 1), (2, 2, 0, 1), (2, 1, 0, 0), (2, 0, 1, 1)):
                log = f'Executed {count} tests, with {skipped} tests skipped and 0 failures'
                command = 'swift() { if [[ "$1" == build ]]; then return "$BUILD_STATUS"; fi; echo "$TEST_LOG"; }; export -f swift; bash "$1"'
                env = dict(os.environ, HELM_K11_SCRATCH=str(root / 'scratch'), TEST_LOG=log, BUILD_STATUS=str(build_status), PLAN_DIR=str(root))
                result = subprocess.run(['bash', '-c', command, 'fixture', str(scripts / 'run_all.sh')], env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                self.assertIn(f'{count} executed; {skipped} skipped', result.stdout)

    def smoke_fixture(self, directory, app_script):
        """A checkout with host_smoke.sh, one step for each run and a stand-in for HelmDev, in a folder with spaces."""
        root = Path(directory, 'Checkout with spaces')
        scripts = root / 'scripts/rebuild'
        (scripts / 'smoke.d').mkdir(parents=True)
        for name in ('host_smoke.sh', 'deny-network.sb'):
            shutil.copyfile(SCRIPTS / name, scripts / name)
        (scripts / 'host_smoke_steps.txt').write_text('windows 1\nquit\n')
        (scripts / 'host_smoke_restore_steps.txt').write_text('windows 1\n')
        app = root / 'Stand-in Helm'
        # Called as: --home <home> --support <support> --smoke <steps>
        app.write_text('#!/bin/bash\n' + app_script)
        app.chmod(0o755)
        return scripts / 'host_smoke.sh', app

    def test_smoke_runs_must_reach_their_end(self):
        # A run that stops early exits 0 like one that finished, so each run must show it got to its end:
        # the first run's final quit (SMOKE_QUIT) and the restore run's SMOKE_END.
        with tempfile.TemporaryDirectory() as directory:
            smoke, app = self.smoke_fixture(directory, 'echo "PASS windows 1"\ncase "$6" in\n'
                                            '*restore.txt) [ -z "$RESTORE_ENDS" ] || echo "SMOKE_END PASS all steps passed" ;;\n'
                                            '*) [ -z "$FIRST_ENDS" ] || echo SMOKE_QUIT ;;\nesac\n')
            for first, restore, expected in (('yes', 'yes', 0), ('', 'yes', 1), ('yes', '', 1)):
                env = dict(os.environ, HELM_SMOKE_BIN=str(app), HELM_SMOKE_NETWORK='allow', FIRST_ENDS=first, RESTORE_ENDS=restore)
                result = subprocess.run(['bash', str(smoke)], env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                if not first:
                    self.assertIn('FAIL: the first run stopped before its last step', result.stdout)
                if not restore:
                    self.assertIn('FAIL: the restore run stopped before its last step', result.stdout)
            # A step file of its own that quits would end the first run there, and skip every step after it.
            (smoke.parent / 'smoke.d/early.txt').write_text('windows 1\nquit\n')
            env = dict(os.environ, HELM_SMOKE_BIN=str(app), HELM_SMOKE_NETWORK='allow', FIRST_ENDS='yes', RESTORE_ENDS='yes')
            result = subprocess.run(['bash', str(smoke)], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn('the steps quit before their last step', result.stderr)
            self.assertNotIn('First run exit', result.stdout)

    @unittest.skipUnless(sys.platform == 'darwin' and shutil.which('sandbox-exec'), 'the network block needs sandbox-exec')
    def test_smoke_network_block_stops_a_connection(self):
        # The same stand-in, finishing both runs, but the first run tries the network: the sandbox kills it.
        with tempfile.TemporaryDirectory() as directory:
            connect = 'import socket\nsocket.socket().connect(("127.0.0.1", 9))\n'
            smoke, app = self.smoke_fixture(directory, 'case "$6" in\n*restore.txt) echo "SMOKE_END PASS" ;;\n'
                                            f'*) echo SMOKE_QUIT; exec /usr/bin/python3 -I -c \'{connect}\' ;;\nesac\n')
            env = {key: value for key, value in os.environ.items() if key != 'HELM_SMOKE_NETWORK'}
            result = subprocess.run(['bash', str(smoke)], env=dict(env, HELM_SMOKE_BIN=str(app)), capture_output=True, text=True)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn('Network: blocked', result.stdout)
            self.assertIn('killed in the first run, most likely for trying to use the network', result.stdout)
            self.assertIn('First run exit 137', result.stdout)


if __name__ == '__main__':
    unittest.main()
