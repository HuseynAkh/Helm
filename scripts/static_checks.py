#!/usr/bin/env python3
"""Dependency-free lexical checks; Swift compilation remains the syntax authority."""
import re
import sys
from pathlib import Path

DAG = {
    'HelmCore': set(), 'HelmFileSystem': {'HelmCore'}, 'HelmPersistence': {'HelmCore'},
    'HelmOperations': {'HelmCore', 'HelmFileSystem'},
    'HelmSearch': {'HelmCore', 'HelmFileSystem'}, 'HelmTestKit': {'HelmCore', 'HelmFileSystem'},
    'HelmUI': {'HelmCore', 'HelmFileSystem', 'HelmPersistence', 'HelmOperations', 'HelmSearch'},
    'HelmApp': {'HelmUI', 'HelmCore', 'HelmFileSystem', 'HelmPersistence', 'HelmOperations', 'HelmSearch'},
    'Helm': {'HelmApp'},
}
CORE = set(list(DAG)[:6])
APPLE = {'AppKit', 'SwiftUI', 'Combine', 'Cocoa', 'QuickLook', 'QuickLookUI',
         'QuickLookThumbnailing', 'UniformTypeIdentifiers', 'CoreServices'}


def mask(source):
    """Blank comments and literals while retaining offsets and newlines; handle nested comments."""
    out = list(source)
    i = 0
    def blank(a, b):
        for k in range(a, b):
            if out[k] != '\n': out[k] = ' '
    while i < len(source):
        start = i
        if source.startswith('//', i):
            end = source.find('\n', i)
            i = len(source) if end < 0 else end
        elif source.startswith('/*', i):
            i += 2
            depth = 1
            while i < len(source) and depth:
                if source.startswith('/*', i): depth += 1; i += 2
                elif source.startswith('*/', i): depth -= 1; i += 2
                else: i += 1
        else:
            match = re.match(r'(#+)?("""|")', source[i:])
            if not match:
                i += 1
                continue
            hashes, quote = match.group(1) or '', match.group(2)
            i += len(match.group())
            end_marker = quote + hashes
            while i < len(source):
                if source.startswith('\\' + hashes, i): i += 2 + len(hashes)
                elif source.startswith(end_marker, i): i += len(end_marker); break
                else: i += 1
        blank(start, min(i, len(source)))
    return ''.join(out)


def check(path, source, module):
    code = mask(source)
    issues = []
    def fail(offset, message):
        issues.append(f'{path}:{source.count(chr(10), 0, offset) + 1}: {message}')
    stack = []
    depths = []
    for i, char in enumerate(code):
        depths.append(len(stack))
        if char in '{([': stack.append((char, i))
        elif char in '})]':
            if not stack or stack[-1][0] != {'}':'{', ')':'(', ']':'['}[char]: fail(i, 'unbalanced delimiter')
            else: stack.pop()
    for _, offset in stack: fail(offset, 'unclosed delimiter')
    guards = []
    offset = 0
    for line in code.splitlines(keepends=True):
        stripped = line.strip()
        if stripped.startswith('#if '):
            condition = stripped[4:]
            guards.append(bool(re.fullmatch(r'(?:canImport\(\w+\)|os\(macOS\))', condition)))
        elif stripped.startswith('#elseif '):
            if guards: guards[-1] = bool(re.fullmatch(r'(?:canImport\(\w+\)|os\(macOS\))', stripped[8:]))
        elif stripped == '#else':
            if guards: guards[-1] = False
        elif stripped == '#endif':
            if guards: guards.pop()
        for imp in re.finditer(r'\bimport\s+(?:(?:struct|class|enum|func|var|let|typealias|protocol)\s+)?(\w+)', line):
            name = imp.group(1)
            if module in CORE and name in APPLE and not any(guards): fail(offset + imp.start(), f'unguarded Apple import {name}')
            if name.startswith('Helm') and name not in DAG.get(module, set()): fail(offset + imp.start(), f'DAG violation: {module} imports {name}')
        offset += len(line)
    banned = [r'\btry\s*!']
    if module in CORE: banned += [r'@objc\b', r'NSPredicate\s*\(\s*format\s*:', r'canImport\(Foundation\.']
    for pattern in banned:
        for match in re.finditer(pattern, code): fail(match.start(), 'banned API: ' + match.group())
    for match in re.finditer(r'\bas\s*!', code):
        line = source[:match.start()].count('\n')
        lines = source.splitlines()
        context = '\n'.join(lines[max(0, line-1):line+1])
        if not re.search(r'(?://|/\*).*as!.*(?:safe|invariant|checked)', context, re.I):
            fail(match.start(), 'forced cast needs an as! safety/invariant comment')
    symbols = []
    for match in re.finditer(r'\b(struct|class|enum|protocol|actor|typealias)\s+(\w+)', code):
        if depths[match.start()] == 0: symbols.append(match.group(2))
    for match in re.finditer(r'\bpublic\s+struct\s+(\w+)[^{]*\{', code):
        start = match.end()
        depth = depths[start - 1] + 1
        end = next((i for i in range(start, len(code)) if code[i] == '}' and depths[i] == depth), len(code))
        inits = list(re.finditer(r'\bpublic\s+init\b', code[start:end]))
        if not any(depths[start + init.start()] == depth for init in inits): fail(match.start(), f'public struct {match.group(1)} lacks public init')
    return issues, symbols


def main():
    errors = []
    names = {}
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path('Sources')
    files = sorted(root.glob('*/**/*.swift'))
    for path in files:
        module = path.relative_to(root).parts[0]
        found, symbols = check(path, path.read_text(), module)
        errors.extend(found)
        for name in symbols:
            if name in names and names[name][0] != module:
                errors.append(f'{path}: duplicate top-level type {name} also in {names[name][1]}')
            names[name] = (module, path)
    for error in errors: print(error)
    print(f'Static checks: {len(files)} Swift files, {len(errors)} errors')
    return bool(errors)

if __name__ == '__main__': sys.exit(main())
