# DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
"""Exercise shell gates with fake Swift commands; no Swift build in these fixtures."""
import os
from pathlib import Path
import shutil
import subprocess
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
            (root / 'scripts/test_static_checks.py').write_text('import unittest\nclass Fixture(unittest.TestCase):\n def test_one(self): pass\n')
            for count, skipped, build_status, expected in ((2, 0, 0, 0), (0, 0, 0, 1), (2, 2, 0, 1), (2, 1, 0, 0), (2, 0, 1, 1)):
                log = f'Executed {count} tests, with {skipped} tests skipped and 0 failures'
                command = 'swift() { if [[ "$1" == build ]]; then return "$BUILD_STATUS"; fi; echo "$TEST_LOG"; }; export -f swift; bash "$1"'
                env = dict(os.environ, HELM_K11_SCRATCH=str(root / 'scratch'), TEST_LOG=log, BUILD_STATUS=str(build_status), PLAN_DIR=str(root))
                result = subprocess.run(['bash', '-c', command, 'fixture', str(scripts / 'run_all.sh')], env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                self.assertIn(f'{count} executed; {skipped} skipped', result.stdout)


if __name__ == '__main__':
    unittest.main()
