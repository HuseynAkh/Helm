import unittest
from static_checks import check

class StaticChecksTests(unittest.TestCase):
    def errors(self, text, module='HelmCore'):
        return check('fixture.swift', text, module)[0]
    def test_import_guards_and_dag(self):
        self.assertTrue(self.errors('import AppKit'))
        self.assertFalse(self.errors('#if canImport(AppKit)\nimport AppKit\n#endif'))
        self.assertTrue(self.errors('#if os(macOS)\n#else\nimport AppKit\n#endif'))
        self.assertTrue(self.errors('import HelmPersistence', 'HelmFileSystem'))
        self.assertFalse(self.errors('import HelmCore', 'HelmFileSystem'))
    def test_initializers_and_nesting(self):
        self.assertTrue(self.errors('public struct A { struct B { public init() {} } }'))
        self.assertFalse(self.errors('public struct A { public init() {} }'))
    def test_bans_and_balance(self):
        for text in ['try! work()', 'x as! Thing', '@objc func x() {}', 'NSPredicate(format: "x")', 'func x( { }']:
            self.assertTrue(self.errors(text), text)
        self.assertFalse(self.errors('// as! safe: checked invariant\nlet x = y as! Thing'))
        self.assertFalse(self.errors('let x = "{(try!" // }\n/* nested /* { */ } */'))
    def test_only_top_level_symbols(self):
        self.assertEqual(check('x', 'struct A { struct B {} }', 'HelmCore')[1], ['A'])

if __name__ == '__main__': unittest.main()
