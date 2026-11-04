<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# K13 audit hardening integration notes

K13 adds adversarial XCTest cases across Search, Core Naming/Text/Presentation/Places/Settings,
and Persistence. Every test cites the protected F/B behavior. Tests use in-memory filesystem
fixtures or unique temporary directories; no network, real user defaults, or external services.

Run with Linux Swift 6.0.3 after sourcing `/workspace/toolchains/env.sh`:

```
swift test --scratch-path /tmp/build-K13 --filter 'HelmCoreTests|HelmSearchTests|HelmPersistenceTests|HelmFileSystemTests|HelmOperationsTests|HelmTestKitTests'
```

`K13*` classes isolate this lane's new cases. The full filter includes all six portable test
targets, including tests owned by other lanes. Modules must be built with explicit targets.

Known source defects and quarantined regression names live in
`docs/test-findings/K13-findings.md`. Remove a BUG-K13 skip only after the source owner fixes
the issue and the unchanged regression passes. Needed change: starred-folder highlight
candidates in Core Places (BUG-K13-1).

Deviation: the requested source-directory README is placed here because K13 owns no source
files. macOS 14/Xcode execution and Opus review remain pending. Locale-independent helpers
use explicit expected English text or injected metadata; sidebar localized collation is
only asserted for stable equal-name ties, not a universal cross-locale sort order.

Coverage inventory: Naming 12, Text 10, Places 7, Settings 6, Presentation 14,
Search/parser/ranking/codecs 20, Search fallback 4, Persistence 11: 84 new tests.
One regression is skipped for the documented source defect; all remaining new tests pass.
The manifest emits an unhandled README warning; excluding documentation from targets
would require a manifest-owner change and is outside K13 ownership.
