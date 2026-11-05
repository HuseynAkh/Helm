#!/usr/bin/env python3
# DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
"""Citation inventory, not feature acceptance. Uses only the Python standard library."""
import argparse
import collections
import csv
from pathlib import Path
import re
import sys

FIELDS = ['id', 'priority', 'milestone', 'module', 'test_name', 'state', 'notes']
STATES = ('planned', 'drafted', 'linux-tested', 'mac-only', 'deferred')
ID = re.compile(r'\b[FPB]-\d{3}\b')
MODULES = dict(Core='HelmCore', FS='HelmFileSystem', Ops='HelmOperations',
               Search='HelmSearch', Persist='HelmPersistence', UI='HelmUI', App='HelmApp')
OWNERS = {2: 'HelmCore', 3: 'HelmCore', 5: 'HelmFileSystem', 6: 'HelmFileSystem',
          7: 'HelmOperations', 8: 'HelmOperations', 10: 'HelmApp', 25: 'HelmApp'}


def catalogue(parity, current):
    """Read definition rows only; references in other columns are not definitions."""
    result = {}
    for path, prefixes in ((parity, 'P'), (current, 'FB')):
        for line in path.read_text().splitlines():
            cells = [cell.strip() for cell in line.split('|')[1:-1]]
            if not cells:
                continue
            match = re.match(r'([FPB]-\d{3})\b', cells[0])
            if not match or match[1][0] not in prefixes:
                continue
            key = match[1]
            priority = cells[4] if key.startswith('P') and len(cells) > 7 else ('bug' if key.startswith('B') else 'preserved')
            if key.startswith('P') and priority not in ('P0', 'P1', 'P2'):
                raise ValueError(f'{path}: invalid priority for {key}')
            modules = ';'.join(MODULES[m] for m in re.findall(r'\b(?:Core|FS|Ops|Search|Persist|UI|App)\b', cells[7])) if key.startswith('P') else ''
            result[key] = dict(priority=priority, module=modules)
    if not any(k.startswith('F') for k in result) or not any(k.startswith('P') for k in result):
        raise ValueError('Empty F or P catalogue: check input paths/format')
    return result


def milestones(path):
    """Appendix B is authoritative; P2 has no owner unless explicitly mapped."""
    text = path.read_text().split('## Appendix B.', 1)
    if len(text) != 2:
        raise ValueError('Build plan lacks Appendix B')
    result = {}
    for key, milestone in re.findall(r'(P-\d{3}) is scheduled at (M\d+)', text[1]):
        result[key] = milestone
    for line in text[1].splitlines():
        cells = [c.strip() for c in line.split('|')[1:-1]]
        if len(cells) < 2:
            continue
        if re.fullmatch(r'M\d+', cells[0]):
            milestone, ids = cells[0], ID.findall(' '.join(cells[1:]))
        elif re.fullmatch(r'M\d+', cells[1]):
            milestone, ids = cells[1], ID.findall(cells[0])
        else:
            continue
        for key in ids:
            if key in result and result[key] != milestone:
                raise ValueError(f'Conflicting milestone for {key}')
            result[key] = milestone
    return result


def citations(text):
    """Comments and test identifiers; expand same-prefix inclusive citation ranges."""
    parts = re.findall(r'//[^\n]*|/\*[\s\S]*?\*/|\bfunc\s+test\w+', text)
    text = '\n'.join(parts)
    found = set(ID.findall(text))
    for prefix, number in re.findall(r'([FPB])_(\d{3})(?!\d)', text):
        found.add(f'{prefix}-{number}')
    for prefix, start, end in re.findall(r'([FPB])-(\d{3})\s*[–—-]\s*(?:\1-)?(\d{3})', text):
        found.update(f'{prefix}-{n:03}' for n in range(int(start), int(end) + 1))
    return found


def passed_tests(log):
    """Require a complete, nonempty XCTest run; never infer success from discovery."""
    if log is None:
        return set()
    text = log.read_text()
    summaries = re.findall(r'Executed (\d+) tests?, with (?:\d+ tests? skipped and )?(\d+) failures?', text)
    if not summaries or int(summaries[-1][0]) == 0 or any(int(f) for _, f in summaries):
        raise ValueError('Test log has no nonempty successful XCTest summary')
    if not re.search(r"Test Suite '(?:All tests|Selected tests)' passed", text):
        raise ValueError('Test log is incomplete or unsuccessful')
    def normalized(name):
        match = re.fullmatch(r'-\[([^ ]+) ([^ ]+)\]', name)
        return f'{match[1]}.{match[2]}' if match else name

    passed = set(map(normalized, re.findall(r"Test Case '([^']+)' passed", text)))
    incomplete_classes = {normalized(name).rsplit('.', 1)[0] for name in re.findall(r"Test Case '([^']+)' (?:skipped|failed)", text)}
    return {name for name in passed if name.rsplit('.', 1)[0] not in incomplete_classes}


def generate(root, items, mapping, passed):
    sources, tests = collections.defaultdict(list), collections.defaultdict(list)
    for folder in ('Sources', 'Tests'):
        for path in sorted((root / folder).rglob('*.swift')):
            text = path.read_text()
            keys = citations(text)
            relative = str(path.relative_to(root))
            if folder == 'Sources':
                for key in keys:
                    sources[key].append(relative)
            else:
                classes = re.findall(r'\bclass\s+(\w+)\s*:\s*XCTestCase', text)
                names = sorted(t for t in passed if any(t.startswith(c + '.') or f'.{c}.' in t for c in classes))
                if not all(any(t.startswith(c + '.') or f'.{c}.' in t for t in names) for c in classes):
                    names = []
                for key in keys:
                    tests[key].append((relative, names))
    rows = []
    for key, info in sorted(items.items()):
        milestone = mapping.get(key, '')
        owner = OWNERS.get(int(milestone[1:]), 'HelmUI') if milestone else info['module']
        evidence = [name for _, names in tests[key] for name in names]
        state = 'linux-tested' if evidence else ('drafted' if sources[key] or tests[key] else 'planned')
        paths = sources[key] + [p for p, _ in tests[key]]
        rows.append(dict(id=key, priority=info['priority'], milestone=milestone,
                         module=owner, test_name=';'.join(evidence), state=state,
                         notes='DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04. ' + (('Citation/file-level evidence only; Mac acceptance pending. ' + ';'.join(paths)) if paths else 'No citation evidence; acceptance pending.')))
    return rows


def audit(items, rows):
    findings, seen = [], set()
    for index, row in enumerate(rows, 2):
        key = row.get('id', '')
        if key not in items:
            findings.append(f'row {index}: unknown or missing ID {key!r}')
        if key in seen:
            findings.append(f'row {index}: duplicate ID {key}')
        seen.add(key)
        if row.get('state') not in STATES:
            findings.append(f'{key}: invalid state {row.get("state")!r}')
        if key in items and row.get('priority') != items[key]['priority']:
            findings.append(f'{key}: priority differs from catalogue')
        if key in items and items[key]['priority'] in ('P0', 'P1') and (not row.get('module', '').strip() or not re.fullmatch(r'M\d+', row.get('milestone', ''))):
            findings.append(f'{key}: P0/P1 has no owner (module and milestone required)')
        if row.get('state') == 'linux-tested' and not row.get('test_name', '').strip():
            findings.append(f'{key}: linux-tested without test evidence')
    findings.extend(f'{key}: missing ledger row' for key in sorted(items.keys() - seen))
    return findings


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument('--parity', type=Path, required=True)
    parser.add_argument('--current-state', type=Path, required=True)
    parser.add_argument('--build-plan', type=Path)
    parser.add_argument('--ledger', type=Path)
    parser.add_argument('--generate', action='store_true', help='Replace ledger with a fresh citation inventory')
    parser.add_argument('--test-log', type=Path, help='Complete successful XCTest log for this checkout (generation only)')
    parser.add_argument('--report-only', action='store_true')
    args = parser.parse_args(argv)
    try:
        items = catalogue(args.parity, args.current_state)
        ledger = args.ledger or args.root / 'docs/handoff/coverage-ledger.csv'
        if args.generate:
            if args.build_plan is None:
                raise ValueError('--generate requires --build-plan')
            rows = generate(args.root, items, milestones(args.build_plan), passed_tests(args.test_log))
            with ledger.open('w', newline='') as stream:
                writer = csv.DictWriter(stream, fieldnames=FIELDS)
                writer.writeheader()
                writer.writerows(rows)
        else:
            with ledger.open(newline='') as stream:
                reader = csv.DictReader(stream)
                if reader.fieldnames != FIELDS:
                    raise ValueError(f'Ledger columns must be {FIELDS}')
                rows = list(reader)
        findings = audit(items, rows)
        for finding in findings:
            print('GAP:', finding)
        print('priority     ' + ' '.join(f'{s:>12}' for s in STATES) + '        total')
        for priority in ('P0', 'P1', 'P2', 'preserved', 'bug'):
            counts = collections.Counter(r['state'] for r in rows if r['priority'] == priority)
            print(f'{priority:12} ' + ' '.join(f'{counts[s]:12}' for s in STATES) + f' {sum(counts.values()):12}')
        print(f'{len(items)} catalogue IDs; {len(rows)} ledger rows; {len(findings)} gaps. Citations do not establish full acceptance.')
        return 0 if args.report_only or not findings else 1
    except (OSError, ValueError, csv.Error) as error:
        print(f'ERROR: {error}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
