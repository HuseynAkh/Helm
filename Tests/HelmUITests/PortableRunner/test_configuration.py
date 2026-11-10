# DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest


class ConfigurationTests(unittest.TestCase):
    def run_runner(self, scratch=None):
        environment = dict(os.environ)
        environment.pop('HELM_UI_SCRATCH', None)
        if scratch is not None:
            environment['HELM_UI_SCRATCH'] = scratch
        return subprocess.run([sys.executable, str(pathlib.Path(__file__).with_name('run.py'))],
                              env=environment, capture_output=True, text=True)

    def test_missing_configuration_is_explicit(self):
        result = self.run_runner()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('HELM_UI_SCRATCH must name', result.stderr)

    def test_empty_scratch_is_rejected_before_compilation(self):
        with tempfile.TemporaryDirectory(prefix='F5-ui-config-') as scratch:
            result = self.run_runner(scratch)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Missing Swift module directory', result.stderr)


if __name__ == '__main__':
    unittest.main()
