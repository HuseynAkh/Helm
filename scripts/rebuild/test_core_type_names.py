"""SDK guard regressions (OK2-35)."""
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('check_core_type_names.py')

class TypeNameTests(unittest.TestCase):
    def test_checks_every_library_and_ui_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for module in ('HelmCore', 'HelmFileSystem', 'HelmPersistence', 'HelmOperations', 'HelmSearch', 'HelmTestKit', 'HelmAgent', 'HelmUI', 'HelmApp'):
                (root / 'Sources' / module).mkdir(parents=True)
            (root / 'Sources/HelmUI/Content').mkdir()
            (root / 'Sources/HelmUI/Content/ContentOverlays.swift').write_text('import SwiftUI\nvar p: HelmCore.DropProposal?')
            (root / 'Sources/HelmUI/New.swift').write_text('import SwiftUI\nvar operation: DropOperation?')
            (root / 'Sources/HelmSearch/New.swift').write_text('public struct Image {}')
            (root / 'Sources/HelmAgent/New.swift').write_text('public enum Stream {}')
            result = subprocess.run(['python3', str(SCRIPT), '--root', directory], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn('HelmSearch/New.swift', result.stderr)
            self.assertIn('HelmAgent/New.swift', result.stderr)
            self.assertIn('HelmUI/New.swift', result.stderr)
            (root / 'Sources/HelmSearch/New.swift').write_text('public struct SearchImage {}')
            (root / 'Sources/HelmAgent/New.swift').write_text('public enum AgentStream {}')
            (root / 'Sources/HelmUI/New.swift').write_text('import SwiftUI\nvar operation: HelmCore.DropOperation?')
            result = subprocess.run(['python3', str(SCRIPT), '--root', directory], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_a_missing_library_folder_fails(self):
        # Each library is named, so one that is left out of the checkout is reported, not skipped.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for module in ('HelmCore', 'HelmFileSystem', 'HelmPersistence', 'HelmOperations', 'HelmSearch', 'HelmTestKit', 'HelmUI', 'HelmApp'):
                (root / 'Sources' / module).mkdir(parents=True)
            result = subprocess.run(['python3', str(SCRIPT), '--root', directory], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn('Missing library source directory', result.stderr)
            self.assertIn('HelmAgent', result.stderr)
