# DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import contextlib
import io
from pathlib import Path
import tempfile
import unittest
import check_coverage as coverage

FIXTURES = Path(__file__).parent / 'fixtures'


class CoverageTests(unittest.TestCase):
    def setUp(self):
        self.items = coverage.catalogue(FIXTURES / 'parity.md', FIXTURES / 'current.md')
        self.mapping = coverage.milestones(FIXTURES / 'plan.md')

    def test_definition_rows_ignore_references(self):
        self.assertEqual(set(self.items), {'F-001', 'B-001', 'P-001', 'P-002', 'P-003'})
        self.assertEqual(self.items['P-001']['module'], 'HelmApp;HelmUI')

    def test_mapping_uses_appendix(self):
        self.assertEqual(self.mapping, {'F-001': 'M10', 'P-001': 'M10', 'P-002': 'M10'})

    def test_citations_ranges_and_names(self):
        text = '/// F-001–F-003 B-001\nfunc test_P_002() {}\nlet s = "P-099"'
        self.assertEqual(coverage.citations(text), {'F-001', 'F-002', 'F-003', 'B-001', 'P-002'})

    def test_success_log(self):
        self.assertEqual(coverage.passed_tests(FIXTURES / 'passing.log'), {'FeatureTests.test_F_001'})
        self.assertEqual(coverage.passed_tests(None), set())

    def test_zero_failed_and_incomplete_logs_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'log'
            for text in ('Executed 0 tests, with 0 failures', 'Executed 1 test, with 1 failure',
                         'Executed 1 test, with 0 failures', ''):
                path.write_text(text)
                with self.assertRaises(ValueError):
                    coverage.passed_tests(path)

    def test_skipped_class_is_not_file_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'log'
            path.write_text("Test Case 'FeatureTests.testOne' passed (0.0 seconds).\n"
                            "Test Case 'FeatureTests.testTwo' skipped (0.0 seconds).\n"
                            "Test Suite 'Selected tests' passed.\n"
                            "Executed 2 tests, with 1 test skipped and 0 failures\n")
            self.assertEqual(coverage.passed_tests(path), set())

    def test_generation_evidence_states(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'Sources/HelmCore').mkdir(parents=True)
            (root / 'Tests/HelmCoreTests').mkdir(parents=True)
            (root / 'Sources/HelmCore/A.swift').write_text('/// P-001\nstruct A {}')
            (root / 'Tests/HelmCoreTests/A.swift').write_text('/// F-001\nclass FeatureTests: XCTestCase { func test_F_001() {} }')
            rows = {r['id']: r for r in coverage.generate(root, self.items, self.mapping, {'FeatureTests.test_F_001'})}
            self.assertEqual(rows['F-001']['state'], 'linux-tested')
            self.assertEqual(rows['P-001']['state'], 'drafted')
            self.assertEqual(rows['P-002']['state'], 'planned')
            self.assertEqual(rows['P-001']['module'], 'HelmApp')
            self.assertEqual(coverage.audit(self.items, list(rows.values())), [])

    def test_gaps_unknown_duplicate_owner_state_priority_evidence(self):
        rows = [dict(id='P-001', priority='P2', milestone='', module='', state='linux-tested', test_name=''),
                dict(id='P-001', state='invalid'), dict(id=''), dict(id='P-999')]
        findings = '\n'.join(coverage.audit(self.items, rows))
        for phrase in ('missing ledger row', 'unknown or missing ID', 'duplicate ID', 'no owner',
                       'invalid state', 'priority differs', 'without test evidence'):
            self.assertIn(phrase, findings)

    def test_cli_report_only_and_malformed_input(self):
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            ledger = Path(directory) / 'ledger.csv'
            ledger.write_text(','.join(coverage.FIELDS) + '\n')
            args = ['--parity', str(FIXTURES / 'parity.md'), '--current-state', str(FIXTURES / 'current.md'), '--ledger', str(ledger)]
            self.assertEqual(coverage.main(args), 1)
            self.assertEqual(coverage.main(args + ['--report-only']), 0)
            ledger.write_text('wrong,columns\n')
            self.assertEqual(coverage.main(args + ['--report-only']), 2)
            self.assertEqual(coverage.main(args + ['--generate']), 2)
            self.assertEqual(coverage.main(args + ['--generate', '--build-plan', str(FIXTURES / 'plan.md')]), 0)

    def test_empty_catalogue_and_missing_appendix(self):
        with self.assertRaises(ValueError):
            coverage.catalogue(FIXTURES / 'plan.md', FIXTURES / 'current.md')
        with self.assertRaises(ValueError):
            coverage.milestones(FIXTURES / 'current.md')


if __name__ == '__main__':
    unittest.main()
