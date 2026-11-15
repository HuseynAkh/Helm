"""The gate builds and tests HelmAgent on macOS, where the manifest declares it, and nowhere else."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).parent
PORTABLE = ['HelmCore', 'HelmFileSystem', 'HelmPersistence', 'HelmOperations', 'HelmSearch', 'HelmTestKit']


class RunAllTargetTests(unittest.TestCase):
    def swift_calls(self, system):
        """Runs a copy of run_all.sh with stand-ins for swift and uname, and returns each swift call as one line."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts = root / 'scripts/rebuild'
            scripts.mkdir(parents=True)
            shutil.copyfile(SCRIPTS / 'run_all.sh', scripts / 'run_all.sh')
            (root / 'scripts/static_checks.sh').write_text('exit 0\n')
            (scripts / 'parse_check_ui.sh').write_text('exit 0\n')
            (scripts / 'check_core_type_names.py').write_text('')
            (scripts / 'check_coverage.py').write_text('')
            passing = 'import unittest\nclass Fixture(unittest.TestCase):\n def test_one(self): pass\n'
            (scripts / 'test_fixture.py').write_text(passing)
            for name in ('test_static_checks.py', 'test_privacy_check.py'):
                (root / 'scripts' / name).write_text(passing)
            calls = root / 'swift-calls.txt'
            command = ('swift() { echo "$*" >> "$CALLS"; echo "Executed 2 tests, with 0 failures"; }; '
                       'uname() { echo "$SYSTEM"; }; export -f swift uname; bash "$1"')
            env = dict(os.environ, HELM_K11_SCRATCH=str(root / 'scratch'), PLAN_DIR=str(root), CALLS=str(calls), SYSTEM=system)
            result = subprocess.run(['bash', '-c', command, 'fixture', str(scripts / 'run_all.sh')], env=env,
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return calls.read_text().splitlines()

    def built(self, calls):
        return [line.split('--target ')[1] for line in calls if line.startswith('build ')]

    def filters(self, calls):
        return [line.split('--filter ')[1] for line in calls if line.startswith('test ')]

    def test_macos_builds_and_tests_the_agent_module(self):
        calls = self.swift_calls('Darwin')
        self.assertEqual(self.built(calls), PORTABLE + ['HelmAgent'])
        self.assertEqual(self.filters(calls), ['Helm(Core|FileSystem|Persistence|Operations|Search|TestKit|Agent)Tests'])

    def test_other_systems_leave_the_agent_module_out(self):
        calls = self.swift_calls('Linux')
        self.assertEqual(self.built(calls), PORTABLE)
        self.assertEqual(self.filters(calls), ['Helm(Core|FileSystem|Persistence|Operations|Search|TestKit)Tests'])


if __name__ == '__main__':
    unittest.main()
