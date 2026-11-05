#!/usr/bin/env python3
"""DRAFT: OK1-1 / architecture Fix 16. Reject known SDK name collisions.

Portable curated guard for module-level names, not a complete Apple SDK symbol index. Extend SDK_NAMES
when reviewing a new SDK. Existing collisions intentionally fail (no allowlist).
Also verifies the minimum HelmUI qualification fix; --self-test needs no SDK.
"""
import argparse
from pathlib import Path
import re
import sys

SDK_NAMES = frozenset("""
DropProposal DropOperation DropSession ToolbarItem ToolbarItemGroup GridItem
SortDescriptor NSSortDescriptor Predicate ComparisonPredicate SortComparator
View Image Color Font Text Label Button Menu List Table OutlineGroup Group
Section NavigationLink NavigationStack Window WindowGroup Scene App Binding State
Environment ObservableObject Published FocusState GeometryProxy Alignment
UnitPoint EdgeInsets AnyView AnyLayout Layout Transaction Animation Transition
TimelineView ProgressView ShareLink Transferable FileDocument ReferenceFileDocument
URL URLComponents URLRequest URLResponse Data Date DateComponents DateInterval
Calendar Locale TimeZone UUID IndexPath IndexSet NSRange CGSize CGPoint CGRect
AffineTransform AttributedString AttributeContainer PersonNameComponents
Progress Operation OperationQueue Notification NotificationCenter FileManager
FileHandle FileWrapper Bundle Process Scanner Formatter NumberFormatter DateFormatter
Measurement Unit Dimension Stream InputStream OutputStream Timer RunLoop
NSView NSWindow NSImage NSColor NSFont NSEvent NSApplication NSWorkspace
NSDraggingInfo NSDragOperation NSItemProvider NSPasteboard NSSharingService
""".split())

# Mask comments and literals before scanning declarations, retaining line numbers.
TRIVIA = re.compile(r'/\*.*?\*/|//[^\n]*|""".*?"""|"(?:\\.|[^"\\])*"', re.S)
DECLARATION = re.compile(r'\bpublic\s+(?:(?:final|indirect|nonisolated)\s+)*(?:struct|class|enum|protocol|typealias|actor)\s+`?(\w+)`?')


def code_only(source):
    return TRIVIA.sub(lambda match: re.sub(r'[^\n]', ' ', match.group()), source)


def collisions(source):
    code = code_only(source)
    result = []
    for match in DECLARATION.finditer(code):
        prefix = code[:match.start()]
        # Nested types require their enclosing name and do not collide on import.
        if prefix.count('{') != prefix.count('}'):
            continue
        if match.group(1) in SDK_NAMES:
            result.append((code.count('\n', 0, match.start()) + 1, match.group(1)))
    return result


def unqualified_drop_proposals(source):
    code = code_only(source)
    return [code.count('\n', 0, match.start()) + 1
            for match in re.finditer(r'(?<![\w.])DropProposal\b', code)]


def self_test():
    assert collisions('public struct DropProposal {}') == [(1, 'DropProposal')]
    assert collisions('public final class NSView {}') == [(1, 'NSView')]
    assert collisions('public\ntypealias `SortDescriptor` = Int') == [(1, 'SortDescriptor')]
    assert collisions('public enum FileDropOperation {}') == []
    assert collisions('// public struct Image {}\nlet x = "public class URL {}"') == []
    assert unqualified_drop_proposals('var p: DropProposal?') == [1]
    assert unqualified_drop_proposals('var p: HelmCore.DropProposal?') == []
    assert collisions('public enum Host { public struct State {} }') == []
    print('PASS: 8 static guard fixtures')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('--ui-only', action='store_true')
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    failures = []
    libraries = ('HelmCore', 'HelmFileSystem', 'HelmPersistence', 'HelmOperations', 'HelmSearch', 'HelmTestKit', 'HelmUI', 'HelmApp')
    if not args.ui_only:
        for module in libraries:
            folder = args.root / 'Sources' / module
            if not folder.is_dir():
                failures.append(f'Missing library source directory: {folder}')
            for path in sorted(folder.rglob('*.swift')):
                for line, name in collisions(path.read_text()):
                    failures.append(f'{path.relative_to(args.root)}:{line}: public {name} collides with an SDK type')
    ui = args.root / 'Sources/HelmUI'
    if not ui.is_dir():
        failures.append(f'Missing UI source directory: {ui}')
    for path in sorted(ui.rglob('*.swift')):
        code = code_only(path.read_text())
        if not re.search(r'\bimport\s+SwiftUI\b', code):
            continue
        for match in re.finditer(r'(?<![\w.])(?:DropProposal|DropOperation|DropSession|ToolbarItem)\b', code):
            line = code.count('\n', 0, match.start()) + 1
            failures.append(f'{path.relative_to(args.root)}:{line}: qualify retained SDK name {match.group()} (e.g. HelmCore.{match.group()})')
    for failure in failures:
        print(failure, file=sys.stderr)
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
