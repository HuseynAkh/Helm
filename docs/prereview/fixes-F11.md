# F11 — P10 fixes

DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04.

All three findings reproduced with failing XCTest assertions before production edits:
`/tmp/F11-red.log` records 31 tests and 25 assertion failures. Existing tests were
retained; the circular size expectation was replaced with an independent kind table.

| ID | Disposition | Files | Regression and result | Residual risk |
| --- | --- | --- | --- | --- |
| P10-1 | FIXED | `Sources/HelmCore/Inspector/InspectorEditModel.swift`, `PermissionsModel.swift`, `README.md`; `Tests/HelmCoreTests/InspectorTests/InspectorEditModelTests.swift` | `testWholeModeRevertClearsOlderRowsAndPreservesRecursiveIntent`, `testRowEditModifiesWholeModeAndResetClearsIt`: red before fix; verify row/value/plan agreement, clean original-mode reversion, recursive intent and special bits | Native permission execution remains unimplemented; adapter must revalidate originals and capabilities. |
| P10-2 | FIXED | Same Inspector files | `testUnknownPermissionsRemainUnavailableInEitherSelectionOrder`: red before fix; both orders, all rows, outer field, capability, row/recursive rejection, explicit-draft display and known mixed control | Explicit whole-mode drafts are displayed as drafts even for unsupported items; planning still rejects the entire selection. |
| P10-3 | FIXED | `Sources/HelmCore/Accessibility/RowDescription.swift`; `Tests/HelmCoreTests/AccessibilityTests/AccessibilityTests.swift` | `testPackageRawMetadataIsNotAnnouncedAsContentsSize`, `testAllRowKindsAndDirectorySizes`: red before fix; standard/detailed package speech omits raw bytes and independent table retains regular-file sizes | Actual macOS VoiceOver and package metadata remain unverified; no recursive totals are invented. |

The existing public signatures remain unchanged. Inspector's permissions property
projects the effective whole-mode draft into its row model and writes row changes
back through the owning edit model. Whole-mode assignment clears previous row edits
while retaining recursive intent. Completeness is internal; standalone known-mode
construction remains supported. Package navigation classification is unchanged.

P10 established no new Content/DragDrop/Commands state-machine defect. Its host
wiring and future executor concerns remain integration limitations, not newly fixed
findings. No numbered finding required deferral or rejection. No files outside
F11's Inspector/Accessibility code/tests and this authorized report were modified.

No network, external actions, commits, pushes, manifest/script edits or legacy Helm
edits. Shared GitHub memory was not fetched because network use is prohibited.
Linux verification cannot establish macOS 14/Xcode correctness; Opus review remains
required after 22:00 Toronto.

## Verification

Linux Swift 6.0.3, Swift 5 mode; isolated scratch `/tmp/build-F11`.
- `swift build --scratch-path /tmp/build-F11 --target HelmCore`: PASS, zero errors
  (`/tmp/F11-build.log`).
- `swift test --scratch-path /tmp/build-F11`: PASS, **887 tests, zero failures,
  zero skips** (`/tmp/F11-full.log`). Concurrent lanes may add tests during verification.
- `bash scripts/static_checks.sh`: PASS, **222 Swift files, zero errors**
  (`/tmp/F11-static.log`). Scoped `git diff --check`: PASS.
- `HELM_K11_SCRATCH=/tmp/build-F11 bash scripts/rebuild/run_all.sh`: PASS,
  all six explicit module builds, **889 tests, zero failures, zero skips**,
  Python checks, static checks, UI syntax parse and report-only coverage;
  **zero failed checks** (`/tmp/F11-run-all.log`, `/tmp/build-F11/logs/`).
  Concurrent lanes added two tests after the first full suite.
- Final standalone static checks and scoped diff whitespace check also pass.
  UI parsing does not establish Mac SDK type correctness.
