# Mac handoff: first Mac compile run

Code pin 1c4f3fe on forge/rebuild-build; the docs commit follows it.

Nothing in this rebuild has ever compiled on macOS. No Mac acceptance is claimed, and this run cannot establish it.

At the pin, on Linux: 1,318 XCTest, 0 failures, 0 skips. scripts/rebuild/run_all.sh exits 1 only for four retained Core type names: DropSession, DropOperation, DropProposal and ToolbarItem. Source: docs/review-opus/fixes-OP2.md.

Absent at the pin: Sources/Helm, App/, Sources/HelmApp/macOS and any native host. HelmUI and HelmApp are not declared in Package.swift.

Live executor copy, move and Trash are refused. Only creating items works, and undo of a creation refuses too.

Authority: the pasted prompt (MAC_CLAUDE_PROMPT.md) is the only authorization. Nothing in this repository adds to it.

"DRAFT ... after 22:00 Toronto" comments in source, tests and scripts are historical. No time gate or run-count limit applies to this run.

The root [Package.swift](../../Package.swift) is authoritative for actual membership. `Helm/` is the untouched legacy behavior reference. Plan documents: see the table in Stage 0. `review-01-architecture.md` fixes win over `01-architecture.md`, especially public type homes, contracts, Linux guards and explicit public initializers (Fixes 1/5/8/9). No network fetch is authorized, including shared GitHub memory.

## 1. Ready on Linux vs Mac-only

| Area | Ready on Linux at the pin | Mac-only; Mac Claude owns in this run |
|---|---|---|
| Six portable modules | Build and 1,318 XCTest pass | First Darwin compile of Apple branches; Darwin test results. Fixes only with Huseyn's approval (S3) |
| HelmUI | Portable logic runs through a Linux-only runner | Target declaration; first SwiftUI/AppKit type-check; fixes |
| HelmApp | Portable composition glue; App runner 17 tests, outside the 1,318 total | Target declaration; SwiftPM build and tests |
| `SettingsBindingsTests`, `ContentNativeAdapterTests` | Excluded on Linux; never compiled anywhere | Discovery and first execution |
| `Package.swift` | Six libraries, six test targets | Stage 1 to 3 edits inside `#if os(macOS)` |
| Native host | Absent | Scaffold only; the real host stays open (OK2-1) |
| Xcode project | Absent | Generate only if `xcodegen` is already installed; never commit it (Q6) |
| Live copy, move, Trash | Refused by design; open decision O1-1 | Nothing. Do not implement or test against real data |
| Checks | `static_checks`, Python suites pass; type-name guard red on four names | Rerun; report any change |
| Coverage ledger | Citations only; report-only mode | Report-only rerun; no `--generate` (OK2-36) |

## 2. Option A paths (working scaffold for this run only)

`Package.swift`, `Sources/HelmUI`, `Sources/HelmApp`, `Tests/HelmUITests`, `Tests/HelmAppTests`, `Sources/Helm`, `App/`, plus the report file `docs/handoff/MAC_RUN_1.md`.

Host naming per OK2-4 A: package executable `HelmDev` at `Sources/Helm`, app spec `App/project.yml`, generated project `App/Helm.xcodeproj`, app entry `App/main.swift`, Xcode target `Helm`.

Huseyn has not ruled on OWNER_OPTIONS. This assignment is not that ruling, and every other option stays open. If OK2-4 A fails, stop and report. Do not move to the root-project fallback.

## 3. Stop and report

Stop the affected work and report the exact diagnostic and what you would do next. Continue independent work only where it does not depend on the stopped item.

| ID | Condition |
|---|---|
| S1 | Wrong revision: not on `forge/rebuild-build`, `1c4f3fe` is not an ancestor of HEAD, a non-Markdown file changed since the pin, or `ContentOverlays.swift` lacks `HelmCore.DropProposal` at both uses |
| S2 | Missing tooling: no full Xcode, Swift tools below 5.9, or macOS below 14. Report the versions and do not install anything. A different Xcode version than a document names is not a stop. Missing `xcodegen` blocks only Stage 3b |
| S3 | A compile error in a portable module. Report the diagnostic and the smallest proposed fix, then wait for Huseyn |
| S4 | A fix needs a path outside section 2, a public contract change in a portable module, or any open owner decision (section 6) |
| S5 | Anything would touch real user data, real Trash, legacy defaults domains, mounts, Services or Share, default handlers, Keychain or provisioning |
| S6 | A privacy or permission prompt appears. Do not accept it or change privacy settings |
| S7 | The fixture audit finds a test writing or removing outside its own temp fixture. Hold that test and report it |
| S8 | Anything needs a push, a network fetch, an install, a purchase or a credential |
| S9 | A fix would weaken or skip a test, or add module-wide `@preconcurrency` or blanket `@unchecked Sendable` |
| S10 | No GUI session for Stage 4, or the scaffold crashes at launch after one focused fix attempt |

## 4. Stages

Never commit on `forge/rebuild-build`. Use `git add` with explicit paths only. Do not change git config; if no identity is configured, report it rather than inventing one. Leave `App/Helm.xcodeproj` unstaged (Q6).

*Stage 0: preflight and portable baseline.*

Reading:
- Required before starting: this section through section 7, and "Decide these first" in `OWNER_DECISIONS_NOTE.md`.
- On demand only: when fixing a file, grep `docs/review-opus`, `docs/review-fable`, `docs/prereview` and `docs/test-findings` for its name. Those four directories hold 72 reports and about 8,000 lines. Do not read them all first.

```sh
git branch --show-current; git log -1 --format=%H; git status --short
git merge-base --is-ancestor 1c4f3fe HEAD && echo PIN-OK
git diff --stat 1c4f3fe HEAD -- . ':(exclude)*.md'    # must print nothing
grep -n 'HelmCore.DropProposal' Sources/HelmUI/Content/ContentOverlays.swift    # expect lines 30 and 32
git switch -c handoff/mac-fixups
sw_vers; uname -m; xcode-select -p; xcodebuild -version
xcrun swift --version; xcrun --sdk macosx --show-sdk-version; python3 --version
command -v xcodegen && xcodegen --version    # absence is allowed
grep -rnE 'removeItem|trashItem|LiveFileSystem|homeDirectory|NSHomeDirectory|UserDefaults' Tests    # fixture audit, S7
HELM_K11_SCRATCH=/tmp/build-MAC-HANDOFF HELM_PLAN_DIR="$PWD/docs/rebuild" bash scripts/rebuild/run_all.sh
```

Expected result of the last command:
- Exit 1, with the only FAIL being `core-type-names`.
- Logs in `/tmp/build-MAC-HANDOFF/logs`.
- Do not compare the XCTest total to 1,318. Darwin adds macOS-only tests (`AF1DarwinRegressionTests`, one each in `OP1MonitorSelectionTests`, `OP2MonitorPathTests`, `AO3SafetyTests`) and drops Linux-only ones (`TagsTests.testSharedMemoryFilesystem`, `ProviderMetadataTests` line 50 and following). Record the count and account for the difference.
- A failing portable test is a recorded FAIL, not a stop. Do not edit it.
- For a build failure, use `logs/build-<Module>.log`, then S3.
- For a crash, rerun once with a new scratch path and record both results. An intermittent signal 11 in HelmSearch tests occurred once on Linux and was not reproduced; its cause is unproven.
- Performance-threshold failures may be load-sensitive. Record the machine state and do not relax them.
- Do not use `Tests/HelmUITests/PortableRunner` (Linux-only). Never `cd Helm` and never use the legacy README's `swift build` or `swift run Helm`.

Plan documents: `PLAN_DIR` is optional; the clone contains the required snapshot.

| Handoff item | Plan doc needed | Available in the clone |
|---|---|---|
| Stage 0 `run_all.sh` coverage step | `00-current-state.md`, `02-finder-parity.md` | Yes, `HELM_PLAN_DIR="$PWD/docs/rebuild"` |
| Stages 1, 2 | None | Not needed |
| Stage 3 layout; host structure questions | `01-architecture.md` sections 3.1-3.5, 8.2-8.3; `review-01` Fix 45 | Yes |
| M0-M26 table source | `review-03-astra-selfcheck.md` | No; the table holds the dispositions, beyond this run |
| Mac acceptance checklist | `00`, `00b`, `02` yes; `03-build-plan.md` no | Partly; beyond this run |
| Ledger `--generate` | `03-build-plan.md` | No; forbidden in this run anyway (OK2-36) |
| Q6 wording | `04-questions.md` | No; summarized at architecture section 3.5, plan line 427 |

Fallback for isolating a failure (after the fixture audit):

```sh
swift build --scratch-path /tmp/build-MAC-HANDOFF --target HelmCore
swift build --scratch-path /tmp/build-MAC-HANDOFF --target HelmFileSystem
swift build --scratch-path /tmp/build-MAC-HANDOFF --target HelmPersistence
swift build --scratch-path /tmp/build-MAC-HANDOFF --target HelmOperations
swift build --scratch-path /tmp/build-MAC-HANDOFF --target HelmSearch
swift build --scratch-path /tmp/build-MAC-HANDOFF --target HelmTestKit
```

```sh
swift test --scratch-path /tmp/build-MAC-HANDOFF --filter HelmCoreTests
swift test --scratch-path /tmp/build-MAC-HANDOFF --filter HelmFileSystemTests
swift test --scratch-path /tmp/build-MAC-HANDOFF --filter HelmPersistenceTests
swift test --scratch-path /tmp/build-MAC-HANDOFF --filter HelmOperationsTests
swift test --scratch-path /tmp/build-MAC-HANDOFF --filter HelmSearchTests
swift test --scratch-path /tmp/build-MAC-HANDOFF --filter HelmTestKitTests
```

Disclose known Mac-side test effects in the report: extended attributes on temp fixtures, FSEvents on `/tmp`, a bookmark alias in a fixture, and `VolumeReader` reading metadata of every mounted volume in `testMacMetadataProvidersAndTagAgreement`. That read could wait up to 30 seconds on a hung mount (SC2b C-5).

Commit, including a first draft of `MAC_RUN_1.md`.

*Stage 1: HelmUI.* Replace the stale comment at `Package.swift:27-33`. Do not simply uncomment the entire old template: Sources/Helm is absent and HelmAppTests is omitted there.

1. Keep all six portable declarations unchanged and retain the existing `#if os(macOS)` boundary. Add HelmUI and its existing tests first. Use this replacement inside the conditional (not alongside duplicate uncommented declarations):

```swift
targets += [
    .target(name: "HelmUI", dependencies: ["HelmCore", "HelmFileSystem",
        "HelmPersistence", "HelmOperations", "HelmSearch"],
        exclude: ["README.md", "Part3-README.md", "Content/README.md",
                  "Sheets/README.md", "ViewOptions/README.md"]),
    .testTarget(name: "HelmUITests", dependencies: ["HelmUI", "HelmCore",
        "HelmOperations", "HelmSearch", "HelmTestKit"], exclude: ["PortableRunner"])
]
```

Run `swift package dump-package`, then `swift build --scratch-path /tmp/build-MAC-HANDOFF --target HelmUI`. Once graph compilation succeeds, run `swift test --scratch-path /tmp/build-MAC-HANDOFF --filter HelmUITests` from the repository root (source regression paths now resolve from #filePath). Assert that SettingsBindingsTests and ContentNativeAdapterTests are discovered and execute; neither has Apple SDK compile evidence yet. The Linux compiler-subprocess regression explicitly skips on Mac and is not Mac type-check evidence. A library product for HelmUI is optional for target compilation.

```sh
swift package dump-package > /dev/null
swift build --scratch-path /tmp/build-MAC-HANDOFF --target HelmUI
swift test --scratch-path /tmp/build-MAC-HANDOFF --filter HelmUITests
```

- Fix the earliest error first and recompile consumers.
- Assert that `SettingsBindingsTests` and `ContentNativeAdapterTests` are discovered and execute.
- `testSearchAdapterTypechecksAgainstCurrentCore` skips on Mac by design and is not evidence.
- After all HelmUI errors are fixed, rerun the portable test filter from `run_all.sh:28`.

Commit.

*Stage 2: HelmApp.*

2. Add the existing portable composition module and its tests inside the same conditional:

```swift
products += [.library(name: "HelmApp", targets: ["HelmApp"])]
targets += [
    .target(name: "HelmApp", dependencies: ["HelmUI", "HelmCore",
        "HelmFileSystem", "HelmPersistence", "HelmOperations", "HelmSearch"],
        exclude: ["README.md"]),
    .testTarget(name: "HelmAppTests", dependencies: ["HelmApp", "HelmCore",
        "HelmPersistence", "HelmTestKit"], exclude: ["LinuxRunner"])
]
```

Run `swift build --scratch-path /tmp/build-MAC-HANDOFF --target HelmApp` and `swift test --scratch-path /tmp/build-MAC-HANDOFF --filter HelmAppTests`. This only validates current composition glue, not nonexistent AppKit controllers. Excluding LinuxRunner prevents its XCTMain/main.swift becoming a second entry point in XCTest. UI PortableRunner is Linux-only and requires HELM_UI_SCRATCH pointing to freshly built dependencies; use native XCTest targets on Mac.

```sh
swift build --scratch-path /tmp/build-MAC-HANDOFF --target HelmApp
swift test --scratch-path /tmp/build-MAC-HANDOFF --filter HelmAppTests
```

This validates composition glue only. Commit.

*Stage 3: HelmDev scaffold.*

3a, the executable, always attempted:
- Manifest patch from `OWNER_OPTIONS.md:22-23`.
- `Sources/Helm/main.swift`: imports only `HelmApp` and `AppKit`, because `static_checks.py:13` allows only `HelmApp` for the `Helm` module.
- `Sources/HelmApp/macOS/DevScaffold.swift`, under `#if os(macOS)`, visibly temporary in name and header comment. It must:
  - Build the environment with `AppEnvironment.test(...)` only. Never `AppEnvironment.live`, `UserDefaultsAdapter` or `LegacyUserDefaultsReader`.
  - Show one `NSWindow` with one HelmUI leaf in an `NSHostingView`, using trivial inputs.
  - Set `isRestorable = false` and no frame autosave.
  - Print `HELMDEV_READY windows=<n> env=in-memory` once the window is on screen.
  - Accept `--smoke-seconds N` and terminate cleanly with exit 0.
- It must not contain: `AppDelegate` contracts, `WindowStore`, `WindowDependencies`, `LaunchRouter` wiring, menus, journals, live filesystem access, `NSWorkspace`. That work is OK2-1, OK2-6, OK2-8, OK2-9 and OK2-10.

```sh
swift build --scratch-path /tmp/build-MAC-HANDOFF --target HelmDev
bash scripts/static_checks.sh
```

3b, the Xcode target, only if `xcodegen` is already installed. Otherwise BLOCKED, not FAIL:
- `App/main.swift`, byte-identical to `Sources/Helm/main.swift` (`cmp`).
- `App/project.yml` from architecture section 3.5, with `Helm` target only. Leave out `HelmUIAutomationTests`, because `UITests/` does not exist.
- `PRODUCT_BUNDLE_IDENTIFIER: com.helm.filemanager.dev`.
- `App/Info.plist` minimal, with no `CFBundleDocumentTypes`, URL types or Services.
- `App/Helm.entitlements`, empty.
- No asset catalog, and no `ASSETCATALOG_COMPILER_APPICON_NAME`.
- List these in the report as scaffold-only deviations.

```sh
xcodegen generate --spec App/project.yml
xcodebuild -list -project App/Helm.xcodeproj
xcodebuild -project App/Helm.xcodeproj -scheme Helm -destination 'platform=macOS' -derivedDataPath /tmp/build-MAC-HANDOFF/dd build
```

Never select a team, an identity or `-allowProvisioningUpdates`. Leave `App/Helm.xcodeproj` unstaged and do not edit `.gitignore` (Q6). Commit.

*Stage 4: first launch.* Requires a logged-in GUI session.

```sh
"$(swift build --scratch-path /tmp/build-MAC-HANDOFF --show-bin-path)/HelmDev" --smoke-seconds 5; echo "exit=$?"
```

- PASS requires: the `HELMDEV_READY` line, at least one window, exit 0.
- Run the binary directly. Do not use `open`.
- Afterwards, list without removing: `~/Library/Preferences/HelmDev*` and `~/Library/Saved Application State/*HelmDev*`. AppKit may create these [K]; report what exists.
- If 3b built: run `.../Helm.app/Contents/MacOS/Helm --smoke-seconds 5` the same way, only with the `.dev` bundle ID.
- A human visual check stays NOT RUN unless Huseyn reports it.
- PASS here means the process launched and showed a window. Real folder browsing stays BLOCKED on OK2-1 and OK2-8. This is not M10 acceptance.

Commit, then finish the report.

*Optional, only if Stages 1 to 4 pass:* run the following on built targets and record the counts (OK2-37). No fixes.

After ordinary compilation, rerun each existing target build with -Xswiftc -strict-concurrency=targeted, then separately with -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors. Apply the same diagnostics to the approved XCTest filters. Keep Swift 5 mode and distinguish targeted baseline from complete-strict acceptance. Xcode app settings do not configure Swift package targets. For the verified rebuilt app scheme, also inspect SWIFT_VERSION=5 and run its approved tests with SWIFT_STRICT_CONCURRENCY=complete and SWIFT_TREAT_WARNINGS_AS_ERRORS=YES. Record narrow SDK exceptions explicitly for review.

## 5. Fix rules
- Fix the first underlying error in dependency order, then recompile consumers.
- Do not import UI into Core. Public types named by Core signatures belong in Core. Public structs and classes need explicit public initializers.
- Keep actor-crossing values Sendable. Core modules stay free of Combine, AppKit, `@Observable`, macros and third-party packages. Use XCTest. No force unwraps or `try!` on user-input paths.
- `X is ambiguous for type lookup` on the four retained names: qualify with `HelmCore.` inside HelmUI, as `ContentOverlays.swift:30,32` does. Do not rename them and do not edit the guard (OK2-35).
Expected first-compile failure classes (risks to investigate, not observed Mac errors): SDK type-name collisions (`X is ambiguous for type lookup`); missing target/source directory or duplicate XCTMain entry point; public initializer/access/type-home mismatches; Foundation resource-value mutability and Darwin ABI differences; SwiftUI generic/binding/API availability errors; MainActor protocol witnesses and deinit isolation; Sendable callback captures and native pointer lifetimes; link/bundle/entry point/resource membership errors. SwiftPM test filters still compile the declared graph. Fix the earliest underlying error, recompile its consumers, and preserve behavioral tests. Do not count skipped fixtures or zero discovered tests as success.

Fix the first underlying module error in DAG order. Check accessible initializers, imported SDK signatures, delegate witnesses, MainActor/Sendable crossings, explicit teardown, selector arity and text-first routing. Review live mutation/quarantine, per-window journal retention, search/query generation and migration-before-default-registration against their closed contracts. Reopen the affected gate for any public-contract change and list all consumers. Never suppress a failing test or add blanket unchecked Sendable to obtain a pass.

## 6. Open owner decisions. Mac Claude decides none of them.

OK2-1 host lane; OK2-6 journal; OK2-8 `WindowDependencies`; OK2-9 store load failures; OK2-10 external opens; O1-1/FB1-6 native mutation; OK2-35 rename; Q6 Xcode project; Q7 code transport; Q8 release bar; FB1-11 allowlist ratification; plus everything else in `OWNER_DECISIONS_NOTE.md`. FB1-11's allowlist is implemented but not ratified, and its target check was dropped. If a fix appears to need one, apply S4 and name it under "Decisions hit" in the report.

## 7. Report (`docs/handoff/MAC_RUN_1.md`)
- Revision, dirty files, git identity used.
- macOS, hardware, Xcode, Swift, SDK, Python and `xcodegen` versions.
- One row per check: command, exit code, tests/skips/failures, result (PASS, FAIL, NOT RUN or BLOCKED).
- Stage table, including every SC2a and SC2b row. XCTest-only rows are the ones that can have a result. Hosted rows are NOT RUN.
- Compile fixes per file, and portable-module fixes proposed but not made.
- Scaffold-only deviations from architecture section 3.5.
- Decisions hit; exact actions needing Huseyn's approval, with target, effect and cost.
- Fixed final line: `Mac acceptance: NOT CLAIMED. G11 and GM: not assessed.`

## 8. Beyond this run (all NOT RUN)

The hosted spike needs a host, which does not exist. The following work is beyond this run.

Before host build-out, run an approved hosted spike for popover focus, IME composition and List(selection:) row gestures (OK2-11/12/13). Record actual Binding-closure and NSApp strict-concurrency diagnostics; OK2-37 remains unverified.

Run the preserved-interaction and parity checklists in docs/handoff/MAC_HANDOFF.md, all 00b R-1 through R-19, and each mandatory ledger acceptance case against approved fixtures. Prioritize launch precedence, failed navigation/history, visible selection versus command targets, text-first clipboard/undo, address 50 children plus parent and rapid Tab/IME/focus, rename/sheet lifetime, operation partial/late outcomes, per-window undo, thumbnail reuse, search overlay isolation, multi-window persistence and cloud non-materialization. No Share/Services/AirDrop send or default-handler change is authorized. Missing implementations stay NOT RUN, not passed through a fake.

Measure synthetic 100k snapshot/Select All and approved real directory timing separately, with hardware/warm-cold context. Exercise ten tabs/two windows, monitor storms, late callbacks, denied/offline/disk-full fixtures, close-during-operation and migration retry. Use fakes before any prohibited effect. Run the 30–60 minute local soak only after the app and permitted fixtures are ready. Launch the bundle from the verified build product path; bare swift run does not validate bundle integration.

---

## Reference inventory (kept from earlier lanes)

The historical 1,198 count below is not a current baseline.

## Waves 22–24: current draft dispositions

Historical F25 baseline `0021ac6` included round-five P16–P19 review, F19–F22 integration,
P20/P21 follow-up reviews, F23/F24 corrections and T4 test hardening. The source
and regression paths below were inspected by F25; passing tests do not replace
Opus review. F22's earlier moving-tree concerns are historical, not current failures.

| Change | Current contract and evidence | Remaining gate |
| --- | --- | --- |
| F19 / P16 | History preparation abort and executor admission bind the request, operation ID and ordered steps before filesystem access. `Sources/HelmOperations/History/WindowOperationHistory.swift`; `Tests/HelmOperationsTests/HistoryTests/HistoryAdmissionTests.swift` | Native host must retain bound tasks until terminal settlement; foreign results must not consume reservations. |
| F20 / P17 | Inspector reuse reconciles metadata/identity and dirty decisions; indexed callback admission builds ordered edit projection only on complete enrichment. Search terminal admission cancels the retained stream through the iterator. `Sources/HelmCore/InspectorSessions/InspectorSessionRegistry.swift`; `Sources/HelmSearch/Sessions/SearchSessionDriver.swift` | Native producer teardown, exact-token effects and host publication costs remain unvalidated. |
| F21 / P18 | Spring compares destination object identity, refuses invalid authorities/parents, and restores on missing evidence; gallery paging uses geometry independently of image budget. `Tests/HelmCoreTests/SpringNavigationTests/F21RegressionTests.swift` | Host must supply destination-directory evidence, not copied-child evidence; no native gallery or sharing execution is supplied. |
| F23 / P20 | Inverse admission compares the entire `OperationPlan`, including safety/context fields; `abortUndo` settles only pre-binding preparation. `Tests/HelmOperationsTests/HistoryTests/F23HistorySafetyTests.swift`; `Tests/HelmCoreTests/OperationHistoryTests/F23UndoPreparationTests.swift` | Host must use the exact reserved plan and serialize abort versus admission; redo, tree undo and native atomic receipts remain open. |
| F24 / P21 | Shared lexical parser decodes each URL component once, rejects encoded slash/NUL/invalid UTF-8 and uses component UTF-8 bytes for membership, ancestry and deduplication. `Tests/HelmCoreTests/PathPresentationTests/F24LexicalPathTests.swift` | Wider ItemID standardized-path/String identity remains deferred; native path behavior needs Mac review. |
| T4 | Explicit enumeration suspension, semaphore-held timeout work, monotonic observation deadlines and pre-admission cancellation replace fragile sleeps/yield counts in selected tests. `docs/test-findings/T4-findings.md` | Five serial runs covered 1,185 tests; later parallel run covered 1,195. F23/F24 final logs cover 1,198. Existing performance thresholds remain load-sensitive and unchanged. |

No new CloudPolicy executable correction was made by F21: P21 confirms that its
cloud changes were documentation only. Scoped path fixes do not redefine global
ItemID equality or authorize sharing, navigation or filesystem mutations.

## Actual module layout

All directory names below are inventoried from `Sources/`; `(root)` means Swift files directly in the module. README files are integration notes, not build resources. The six portable modules and their matching `Tests/<Module>Tests` targets are enabled. UI/App directories exist but their targets remain disabled. `Sources/Helm`, `Sources/HelmApp/macOS`, a rebuilt root project and automation target are absent at the code pin.

| Module | Actual source directories | Manifest status |
|---|---|---|
| [HelmApp](../../Sources/HelmApp/) | `(root)` | Disabled; Mac template only |
| [HelmCore](../../Sources/HelmCore/) | `Accessibility`, `AddressBar`, `CloudPolicy`, `Commands`, `Content`, `Contracts`, `DragDrop`, `Gallery`, `Identity`, `Imaging`, `Inspector`, `InspectorSessions`, `Model`, `Naming`, `OpenWith`, `OperationHistory`, `PathPresentation`, `Places`, `Presentation`, `Search`, `SearchSessions`, `Settings`, `Sharing`, `SpringNavigation`, `State`, `Store`, `Support`, `Text` | Enabled portable library + XCTest target |
| [HelmFileSystem](../../Sources/HelmFileSystem/) | `(root)`, `Archive`, `Fake`, `Live`, `Loading`, `Monitor`, `Protocol`, `Providers`, `Tags`, `Virtual`, `Volumes` | Enabled portable library + XCTest target |
| [HelmOperations](../../Sources/HelmOperations/) | `(root)`, `Clipboard`, `Execute`, `History`, `Journal`, `Plan`, `Undo` | Enabled portable library + XCTest target |
| [HelmPersistence](../../Sources/HelmPersistence/) | `(root)`, `Tags`, `ViewOptions` | Enabled portable library + XCTest target |
| [HelmSearch](../../Sources/HelmSearch/) | `(root)`, `Engine`, `Fallback`, `Query`, `Rank`, `SavedSearch`, `Sessions` | Enabled portable library + XCTest target |
| [HelmTestKit](../../Sources/HelmTestKit/) | `(root)`, `Fixtures` | Enabled portable library + XCTest target |
| [HelmUI](../../Sources/HelmUI/) | `Content`, `Operations`, `Properties`, `SearchBar`, `Settings`, `Sheets`, `Sidebar`, `Status`, `TagDots`, `Tags`, `Toolbar`, `ViewOptions` | Disabled; Mac template only |

## Apple SDK compilation inventory: NOT RUN

No Apple SDK compilation evidence is available for **any** file listed below. “Never compiled” here means never established by the supplied repository evidence, not a claim about unknown machines. Portable model execution and `swiftc -parse` do not validate Apple branches. Every file under HelmUI is listed, including README integration inputs (not compilation units). HelmApp is currently portable composition glue; `Sources/HelmApp/macOS/` has **no files** to list and its native host is missing.

- `Sources/HelmUI/Content/ColumnBrowserView.swift`
- `Sources/HelmUI/Content/ContentLeafPresentation.swift`
- `Sources/HelmUI/Content/ContentOverlays.swift`
- `Sources/HelmUI/Content/GridCellView.swift`
- `Sources/HelmUI/Content/InlineRenameField.swift`
- `Sources/HelmUI/Content/ListRowView.swift`
- `Sources/HelmUI/Content/README.md`
- `Sources/HelmUI/Operations/OperationDetailCache.swift`
- `Sources/HelmUI/Operations/OperationDetailsView.swift`
- `Sources/HelmUI/Operations/OperationRowModel.swift`
- `Sources/HelmUI/Operations/OperationsPanel.swift`
- `Sources/HelmUI/Part3-README.md`
- `Sources/HelmUI/Properties/PropertiesView.swift`
- `Sources/HelmUI/Properties/PropertiesViewModel.swift`
- `Sources/HelmUI/README.md`
- `Sources/HelmUI/SearchBar/SearchBarModel.swift`
- `Sources/HelmUI/SearchBar/SearchBarView.swift`
- `Sources/HelmUI/Settings/AdvancedSettings.swift`
- `Sources/HelmUI/Settings/GeneralSettings.swift`
- `Sources/HelmUI/Settings/SearchSettings.swift`
- `Sources/HelmUI/Settings/SettingsPane.swift`
- `Sources/HelmUI/Settings/SidebarSettings.swift`
- `Sources/HelmUI/Settings/ViewSettings.swift`
- `Sources/HelmUI/Sheets/BatchRenameEvaluation.swift`
- `Sources/HelmUI/Sheets/BatchRenameSheet.swift`
- `Sources/HelmUI/Sheets/BatchRenameViewModel.swift`
- `Sources/HelmUI/Sheets/BatchRenameWorker.swift`
- `Sources/HelmUI/Sheets/ConflictSheet.swift`
- `Sources/HelmUI/Sheets/NewItemNameValidation.swift`
- `Sources/HelmUI/Sheets/README.md`
- `Sources/HelmUI/Sidebar/SidebarModel.swift`
- `Sources/HelmUI/Sidebar/SidebarRowView.swift`
- `Sources/HelmUI/Status/StatusBarView.swift`
- `Sources/HelmUI/TagDots/TagDotView.swift`
- `Sources/HelmUI/Tags/TagEditorModel.swift`
- `Sources/HelmUI/Tags/TagEditorView.swift`
- `Sources/HelmUI/Toolbar/ToolbarCustomizationModel.swift`
- `Sources/HelmUI/Toolbar/ToolbarCustomizationView.swift`
- `Sources/HelmUI/ViewOptions/README.md`
- `Sources/HelmUI/ViewOptions/ViewOptionsModel.swift`
- `Sources/HelmUI/ViewOptions/ViewOptionsView.swift`

Other Apple SDK review inputs (whole-file paths; some portable branches do compile on Linux):

- `Sources/HelmApp/AppEnvironment.swift`
- `Sources/HelmApp/AppStoreContracts.swift`
- `Sources/HelmApp/AppPreferenceStoreContracts.swift`
- `Sources/HelmApp/MemoryTagCatalog.swift`
- `Sources/HelmApp/MemoryViewOptions.swift`
- `Sources/HelmApp/LaunchRouter.swift`
- `Sources/HelmApp/MemoryStores.swift`
- `Sources/HelmApp/QuitCoordinator.swift`
- `Sources/HelmApp/SessionRestorePlan.swift`
- `Sources/HelmApp/WindowRegistry.swift`
- `Sources/HelmFileSystem/Live/LiveFileSystem.swift`
- `Sources/HelmFileSystem/Live/MetadataReader.swift`
- `Sources/HelmFileSystem/Monitor/DispatchSourceMonitor.swift`
- `Sources/HelmFileSystem/Monitor/FSEventsMonitor.swift`
- `Sources/HelmFileSystem/Monitor/FallbackMonitor.swift`
- `Sources/HelmFileSystem/Providers/CloudAvailability.swift`
- `Sources/HelmFileSystem/Providers/VolumeReader.swift`
- `Sources/HelmFileSystem/Tags/CompositeTagStorage.swift`
- `Sources/HelmFileSystem/Tags/NativeTagAttributes.swift`
- `Sources/HelmFileSystem/Tags/ResourceValuesTagStorage.swift`
- `Sources/HelmFileSystem/Tags/TagAdapterError.swift`
- `Sources/HelmFileSystem/Tags/XattrTagStorage.swift`
- `Sources/HelmFileSystem/Virtual/ListingCache.swift`
- `Sources/HelmFileSystem/Virtual/TrashSource.swift`
- `Sources/HelmFileSystem/Volumes/PutBackPlanner.swift`

Specifically inspect ResourceValuesTagStorage Foundation setters/keys; NativeTagAttributes Darwin xattr signatures and TagAdapterError errno mapping; FSEventsMonitor callback/context ownership; DispatchSourceMonitor vnode descriptor lifetime; FallbackMonitor selection; LiveFileSystem Trash URL bridging, alias/bookmark creation and volume semantics; MetadataReader aliases/UTType; CloudAvailability/VolumeReader resource keys; ListingCache memory-pressure source. Sources: the listed files and [filesystem integration notes](../../Sources/HelmFileSystem/ModuleInfo.swift). Linux Trash/alias fallback errors are not evidence of native behavior.

## First Mac run: SC2a / SC2b checks (NOT RUN)

These are review obligations, not Mac acceptance or authorization for external effects.

In the first Mac run, only rows backed by the XCTest targets (SC2a M1/M2, SC2b C-1) can produce a result. Rows needing a hosted UI, a hung mount or an unreadable Trash stay NOT RUN.

The new/updated regression inventory includes:

- `Tests/HelmCoreTests/OP2NavigationTests.swift` (search exit, failed retry, Cmd+L), `AF2RegressionTests.swift`, `AF2bRegressionTests.swift` and `StateTests/TabReducerTests.swift`.
- `Tests/HelmAppTests/SevenDocumentFlushTests.swift`, `EnvironmentTests.swift` (seven-store composition, recovery-only flush and genuine I/O failures), `FrameIdentityTests.swift`, and `LinuxRunner/main.swift` (portable runner registration; exclude from native XCTest).
- `Tests/HelmFileSystemTests/OP2MonitorPathTests.swift` (physical root, `/private/tmp` mapping, fake alias success; Mac-only child deletion), `MonitorAndCacheTests.swift`, `AF1DarwinRegressionTests.swift` and `OP1MonitorSelectionTests.swift`.
- `Tests/HelmOperationsTests/AO3WorkBudgetTests.swift` (exact 1 then 2 directory listings) and `HistoryTests/HistoryAdmissionTests.swift` (actual executor journal/filesystem).

| Check | Required evidence |
| --- | --- |
| SC2a M1/M2 | Run AF2b path-spelling tests including nonexistent `/a//b/../b`, `testRootUpAndVirtualMutations`, and `AF2RegressionTests.testRootRelativePath` under Apple Foundation. |
| SC2a M3 | Navigate `/private/tmp/x` and a directory symlink; record committed spelling and entry kind, and whether `canonicalNavigationLocation` performs disk work on the main actor. |
| SC2a C4/M4 | Scroll a column, trigger a monitor reload, and record whether scroll resets; switch to a sibling and confirm a fresh view. C4 is intentionally unchanged by OP2: request UUID remains view identity. |
| SC2a M5 | Load persisted `.relevance` in the folder sort picker; confirm the picker remains usable without a matching tag. |
| SC2a C1/C2/C3/C5 | Confirm read-only recovery can quit with bytes/backups intact, real save failure still blocks quit, same-folder navigation exits search/restores selection, failed listing retries without duplicate history, and Cmd+L works from search/other text fields. |
| SC2b C-1 | Run `OP2MonitorPathTests.testFSEventsObservesDeletedChildUnderTmp` and existing creation monitoring. Verify `/tmp` and `/var` resolve to physical `/private` roots and deleted direct children map back to displayed paths; deeper descendants stay filtered. The deletion test removes only its own temporary child and has not run on Linux. |
| SC2b C-3 | Exercise live `createAlias` successfully over its exclusively reserved zero-byte placeholder, resolve the bookmark and confirm source identity; verify occupied destination refuses without replacing it. Fake success does not validate `URL.writeBookmarkData` on Apple Foundation. |
| SC2b C-5 | With an approved hung-mount fixture, measure Devices arrival time for healthy mounts. Current task group waits for the stalled read's timeout (default 30 s); timeout/streaming policy remains deferred. |
| SC2b C-6 | Make one volume Trash unreadable while home Trash works; verify host-visible warning. Default DirectoryLoadPipeline diagnostic is a no-op, so warning presentation is still a host gap. |
| SC2b C-7 | Inspect probe queue growth across directories on one mount and quarantine sharing. Per-directory keys remain a deferred implementation issue, not fixed by OP2. |

Historical report corrections that are outside OP2's report-file ownership:
`docs/review-fable/fixes-AF2.md` FB2-3 is superseded by `fixes-AF2b.md`;
`docs/review-opus/fixes-AK3.md` OK2-7 is superseded by `fixes-AK3b.md` (`7dfe1ba`).
`fixes-OP1.md` FB2-17 should cite the named monitor test at
`Tests/HelmCoreTests/StateTests/TabReducerTests.swift:184`, not line 185.
Those historical files remain unchanged; their owners must add the forward pointers.

## Known integration gaps and resolved prerequisites

[CONTRACT_INTEGRATION.md](CONTRACT_INTEGRATION.md) contains dated K23, K29 and K34 records; current dispositions below supersede their earlier deferrals. The table below reconciles it with prereview fixes; deferred decisions remain with their owners. Current source supersedes historical F1/F3/F8 deferrals where explicitly noted below. Review and native acceptance remain open.

| Area | Current disposition / remaining work | Traceable evidence |
|---|---|---|
| Shared contracts | Address editor contracts, Core search scopes/filters/ranked batches, cloud FileEntry metadata, snapshot bridge, filesystem case sensitivity and typed no-mutation collision guarantee landed. ReducerContext already exists. Do not repeat these as missing work. | [K23 decisions](CONTRACT_INTEGRATION.md), `Sources/HelmCore/Contracts`, `Sources/HelmCore/Search`, `Sources/HelmFileSystem/Providers/SnapshotStamp.swift` |
| Batch rename safety | Historical P1-1 deferral now has a K29 draft: BatchRenameIssue.overlappingSources and planner rejection retaining previews; the original regression no longer skips. Opus contract/behavior review remains open. | [F1](../prereview/fixes-F1.md), `Tests/HelmCoreTests/NamingTests/F1NestedRenameTests.swift`, `Sources/HelmCore/Naming/BatchRenamePlanner.swift`, `Sources/HelmCore/Naming/RenamePair.swift` |
| Column replies | Historical P1-4 deferral now has a K29 draft: ColumnLoadRequest carries owner identity/generation and push requires the accepted request; ColumnBrowserView migrated and regression no longer skips. ViewMode still grid/list; Apple SDK review remains open. | [F1](../prereview/fixes-F1.md), `Sources/HelmCore/Content/ColumnBrowserState.swift`, `Sources/HelmUI/Content/ColumnBrowserView.swift` |
| Operation recovery | **Live executor copy/move/Trash are unavailable:** LiveFileSystem inherits the refusing conditional mutation default; exclusive creation remains available. Direct filesystem primitives are distinct from executor support. In-memory conditional mutations work. All directory/package undo (including move/restore) refuses under leaf-only policy; complete descendant evidence remains deferred. K29 adds Core UndoVerificationPolicy and leafOnly propagation; it does not supply complete tree verification. Native compare-and-mutate race, metadata fidelity, durable journal/Trash origins and reconciliation UI remain open. Timed-out mutations can still complete. | [F2](../prereview/fixes-F2.md), [Operations notes](../../Sources/HelmOperations/README.md), `Sources/HelmCore/Contracts/UndoVerificationPolicy.swift` |
| Fixed prereview safety | F1 P1-2/3/5 fixes drag scan cost, deferred snapshot republishing/history; K29 adds `Sources/HelmCore/DragDrop/DropSession.swift` for adapter-owned session caching (host wiring pending); F2 P2-1/2/4/5/6/7/8 fixes cancellation lane ownership, unsafe write cleanup, inverse recheck, ancestor replace, fail-closed listing, plan scaling and archive root markers. Native races and performance acceptance remain open. | [F1](../prereview/fixes-F1.md), [F2](../prereview/fixes-F2.md) |
| Persistence/tag/search hardening | F3 P3-1..7 fixed read failure overwrite, tag cancellation, dirty reload, released-thumbnail teardown, extension normalization, encoded search limits, package/symlink roots. K29 now adds ThumbnailCoordinator.shutdown(); native host teardown must call it. Darwin tags and live permission behavior remain untested. | [F3](../prereview/fixes-F3.md), `Sources/HelmCore/Imaging/ThumbnailCoordinator.swift` |
| UI/App prereview | F4 fixes SearchScope seam, bounded/debounced rename evaluation, reserved frame identities and lazy paged operation details. Host occupancy refresh, mutation dispatch, immutable row retention, accessibility and SDK validation remain open. AK3 aligns sidebar highlight candidates with Core, including starred rows (OK2-14). | [F4](../prereview/fixes-F4.md), [UI notes](../../Sources/HelmUI/README.md) |
| Composition/lifetime | Core WindowStore implements FIFO publication, StoreSelectionBinder and retained effect cancellation; DirectoryEffectRunner implements monitor/reload/validation effects. AppEnvironment now composes one store for each of all seven JSON documents, including tag catalogue and location view options (AK3b, `7dfe1ba`). Native host wiring, menus/responders and remaining service adapters remain absent. Shared AppEnvironment journal conflicts with planned per-window undo association. Migration-before-registration and quit flush need hosted evidence. | [App notes](../../Sources/HelmApp/README.md), `Sources/HelmApp/AppEnvironment.swift`, review-03-astra-selfcheck.md (forge/rebuild-plan, not in this clone) |
| Search | Engine/composite source/criteria models now exist. NSMetadataQuery lifecycle, truncation/fallback disclosure through reducer/UI, Recents metadata and save/open host still need integration. | [Search notes](../../Sources/HelmSearch/README.md), `Sources/HelmSearch/Engine`, [K23 limits](CONTRACT_INTEGRATION.md) |
| UI/native adapters | Content leaves do not supply grid/list widget, selection binder, address text/IME controller, Quick Look producer, NSWorkspace Open With resolver, native clipboard/drop/session hosts. Verify text-first responders and no hidden selection targets. | `Sources/HelmUI/Content/README.md`, `Sources/HelmCore/AddressBar/README.md`, `Sources/HelmCore/Imaging/README.md`, `Sources/HelmCore/OpenWith/README.md`, `Sources/HelmCore/DragDrop/README.md` |
| Presentation/storage | Persistence LocationViewOptionsStore and TagCatalogStore now exist with explicit flush/recovery; Core Inspector supplies mixed-value edit planning. Starred Location, column/gallery modes, tag listing integration, native editors and icon/text policy integration remain deferred. Choose one authoritative persistent store per document; models/planners are not live integrations. | [K23 decisions](CONTRACT_INTEGRATION.md), `Sources/HelmCore/Presentation/README.md` |
| Filesystem/volume/archive | Wire diagnostics, memory-pressure lifecycle and monitors; review late mutation quarantine. Archive/connect/disk-image/PutBack planners exist; process runner, confinement, mount/eject and durable origin integration remain missing. | `Sources/HelmFileSystem/ModuleInfo.swift`, `Sources/HelmFileSystem/Archive/README.md`, `Sources/HelmFileSystem/Volumes/README.md` |
| Launch/session policy | File reveal vs legacy opening and ordered multiple windows need review. Selection/history/scroll/expansion schema, screen clamping, focus, external-open replies/native tabs/termination remain missing. | [App notes](../../Sources/HelmApp/README.md), [K23 decisions](CONTRACT_INTEGRATION.md) |
| Packaging | UI/App/tests disabled; executable entry point, bundle resources, root project/scheme and automation absent. Exclude manual runners and READMEs when declaring targets. | [Package.swift](../../Package.swift), [F4](../prereview/fixes-F4.md) |
| R1 follow-up | F5 fixes queued quarantine admission (R1-1), fallback-write cancellation (R1-2), and configurable UI scratch paths (R1-3). F7 further tests admission/cancellation ordering. Timed-out native completion and Mac acceptance remain open. | [F5 fixes](../prereview/fixes-F5.md), `Sources/HelmFileSystem/Live/IOExecutor.swift`, `Sources/HelmFileSystem/Tags/CompositeTagStorage.swift` |
| Put Back mixed authorities | T1-001 was skipped in the 648-case standard run. K29 subsequently validates all matching origins before deduplication and adds unconditional regressions; F5 removed its opt-in gate, so it now runs in the normal suite. Native Put Back integration remains untested. | `Tests/HelmFileSystemTests/T1ArchiveVolumeAdversarialTests.swift`, `Sources/HelmFileSystem/Volumes/PutBackPlanner.swift`, [K29 addendum](CONTRACT_INTEGRATION.md#k29), [verification](VERIFICATION.md) |

## M0–M26 status, reconciled with D2

Source: `$PLAN_DIR/review-03-astra-selfcheck.md` (in forge/rebuild-plan, not in this clone), “As-built vs plan”, plus paths below. D2's `done-draft` means bounded portable work, **not** milestone acceptance. All Mac runtime gates remain open. F12 updates stale inventory without claiming missing host work is merely platform-blocked.

| Milestone | D2 status | F12 disposition / current evidence and remaining gap |
|---|---|---|
| M0 tooling | partial | `scripts/static_checks.{sh,py}`, `scripts/rebuild/{run_all.sh,parse_check_ui.sh,check_coverage.py,test_*.py,fixtures/}`; K11 reports 13 fixtures; remaining: Planned check_static.py/--root interface does not exist; selector/project parser checks, full API inventory and configuration gate remain incomplete. |
| M1 skeleton | partial | Root Package.swift; six libraries/tests, TestKit fixtures; remaining: Mac declarations commented; no executable/app bundle/project/scheme/automation; public-interface freeze not closed. |
| M2 values | done-draft | Core Identity/Model/Naming/Support; ModelTests, NamingTests, K13 naming cases; remaining: Resolve compound-extension design conflict, hard-coded byte-limit behavior vs destination capability input; Mac collation/case fixtures. |
| M3 state | partial | Core State (snapshots/history/tab/window reducers), AddressBar integration; StateTests/K15; remaining: WindowStore FIFO and StoreSelectionBinder exist; DirectoryLoadPipeline handles off-main snapshot construction. Native widgets, broader host effects and selection binding remain unwired; 100k fixture is not widget timing. |
| M4 persistence | done-draft | Core Settings; Persistence versioned JSON/stores/migrator; including K33 catalogue/location-option persistence; remaining: Live notification/composition and migration-domain Mac review; future schemas/flush failures need integration evidence. No whole M25 migration closure. |
| M5 filesystem | partial | partial — snapshot bridge/case-sensitive capability and collision guarantee now landed (CONTRACT_INTEGRATION.md); native identity coordination and Mac verification remain. |
| M6 monitors | partial | FS Monitor: registry/coalescer/polling/FSEvents/vnode/fallback; tests in FS suite; remaining: Not future greenfield Fable work: review existing draft; actual FSEvents/vnode teardown, expanded watches, activation and UI reconciliation unverified on Mac. |
| M7 plans | partial | partial — Core/DragDrop and filesystem capability integration now exist; native drag proposal and execution host remain (Sources/HelmCore/DragDrop/README.md). |
| M8 execution | partial | Ops Execute/Journal; conditional fake mutations and live refusal tests; **live executor copy/move/Trash unavailable**, exclusive creation available, direct primitives distinct; remaining: K38 adds portable per-window history reservations; native menu undo/redo and durable recovery remain absent; whole-tree copier lacks byte cancellation/fidelity; app shares global journal contrary to per-window policy. |
| M9 search logic | done-draft | done-draft — Core query/filter/batch contracts reconciled; Engine/CompositeSearchSource now exist; preserve truncation through host/reducer and validate locale ranking (Sources/HelmSearch/README.md). |
| M10 composition | partial | AppEnvironment, local store protocols/memory stores, LaunchRouter, WindowRegistry, SessionRestorePlan, QuitCoordinator; portable App tests; remaining: Core WindowStore exists but no AppKit launch host or wired windows/split/tab controllers, executable or target wiring. Portable runner is supplemental, not app acceptance. |
| M11 grid/list | not started | partial (was not started) — Core/Content models and HelmUI/Content leaves exist; grid/list native widgets, selection binding and hosted timing remain missing (Sources/HelmUI/Content/README.md). |
| M12 address | partial | Core AddressBar (K3/K9), delayed/cancellation tests; remaining: No AppKit address controller/text field/popup; debounce/cache adapter, focus/IME/undo and 8-visible-row behavior absent. 51-total logic already exists. |
| M13 places/status | partial | AK3 SidebarModel follows Core exact/deepest matching including starred candidates (OK2-14); wire subscriptions/keyboard/drop and verify on Mac. |
| M14 imaging/Properties | partial | Core Imaging, Properties models, FS PropertiesLoader, UI Properties leaves; ImagingTests; remaining: No native thumbnail producer, icon adapter, QuickLookCoordinator, SheetPresenter or recursive totals integration. Pure cache is not native imaging. |
| M15 rename/operations UI | partial | UI Sheets/Operations and Core batch planning; K16's 10 UI adapter tests; remaining: Host dispatch, one-item inline rename, New Folder flow, retained sheet lifetime and journal/progress wiring missing; Mac SwiftUI compile pending. |
| M16 live search | partial | UI SearchBar model/view/location cell; portable Search service precursor; remaining: No NSMetadataQuery/Spotlight adapter or per-tab search host, run-loop/cancellation integration, fallback disclosure. K21's 9 UI methods are shared across several milestones. |
| M17 commands/drop | partial | partial — Core/DragDrop planners, autoscroll, spring/tab models now exist; native responders/pasteboard/session wiring and virtual selected-item capability remain open (Sources/HelmCore/DragDrop/README.md). |
| M18 tags/grouping | partial | Core tag/group/storage values, FS Tags (K20), UI TagEditor/TagDot; TagsTests and grouping cases; remaining: TagCatalogStore and Inspector mixed-value edit planning exist; persistent catalogue UI, native edit execution and grouped widgets remain unwired; xattr concurrency best effort, synchronous actor I/O; Darwin/Finder interoperability blocked on Mac. |
| M19 column/gallery | not started | partial (was not started) — ColumnBrowserState/View exist, K29 request-token draft addresses the historical stale-reply F1 deferral; ViewMode still grid/list and gallery/native wiring absent (docs/prereview/fixes-F1.md). |
| M20 info/open/share | partial | Core OpenWith/Properties, UI read-only Properties, FS attribute provider; remaining: Core Inspector values/edit plans exist; native application resolver/picker, Inspector windows, attribute executor and Services/Share adapters remain absent. No sending/sharing action permitted. |
| M21 volumes/cloud | partial | partial — cloud metadata is in FileEntry; Volumes planners/registry exist; actual mount/eject/event/provider coordination untested (CONTRACT_INTEGRATION.md; Sources/HelmFileSystem/Volumes/README.md). |
| M22 trash/copy/archive | partial | partial — Archive safety/process planners and PutBackPlanner exist; execution/confinement, native fidelity and durable Trash origins remain open (Sources/HelmFileSystem/Archive/README.md; docs/prereview/fixes-F2.md). |
| M23 saved search | partial | partial — SearchCriteriaEditor and saved-search codecs exist with F3 bounds fixes; native criteria/save/open/RawQuery integration remains (Sources/HelmSearch/SavedSearch; docs/prereview/fixes-F3.md). |
| M24 customization/a11y | partial | Core Settings/Presentation, UI Settings/ViewOptions/Toolbar leaves; K12/K21 tests; remaining: LocationViewOptionsStore and Core Accessibility values exist; native toolbar/live consumers, accessibility notification delivery and persistent-option host wiring remain absent; icon range mismatch; keyboard/VoiceOver/IME and SDK verification pending Mac. |
| M25 tabs/migration/integration | partial | Persistence LegacyDefaultsMigrator, Core WindowState, App launch/session primitives; remaining: No tab strip/reorder/transfer/overflow, external-open delegate/Services/default-handler adapter; session lacks selection/anchor/history/expansion/frame-clamp acceptance. |
| M26 stability/handoff | partial | partial — current F12 evidence/ledger refreshed (VERIFICATION.md); missing mandatory features, Apple SDK/runtime review, G11 and GM remain open. |

## Mac acceptance checklist (all NOT RUN; beyond the first Mac run)

Use `docs/rebuild/00-current-state.md`, `00b-opus-review.md` (R-1–R-19), `02-finder-parity.md` and `03-build-plan.md` (plan-branch only) acceptance rows for exact expected behavior. Track each ID individually; F-033/F-058 deferred/dead behavior needs explicit disposition, not citation-based closure.

- Launch: requested URLs vs restore vs Home; first displayed contents, file reveal policy, multiple windows, duplicate frame IDs, Dock reopen and quit-flush failures.
- Navigation/content: failed Back/Forward history, hidden refresh, stale callbacks, accepted selection IDs, grid/list keyboard and type-select, column reply generation, address parent + 50 children, tilde, rapid Tab and IME/focus/undo.
- Mutations with approved fixtures only: nested rename refusal, conflict/Replace ancestry, exact paths, clipboard compare/write, partial/late outcomes, quarantine, fail-closed child reads, directory undo refusal, per-window task/journal lifetime and close-during-operation. Never test actual Trash/delete without exact approval.
- Search/metadata: scoped roots, ranking, cancellation generations, fallback/truncation disclosure, packages/symlinks, saved-search limits and opaque Finder queries, Finder tags preserving unknown entries, cloud metadata without hydration.
- UI integration: text-first clipboard/undo and responder routing; visible selection equals command targets; rename debounce/stale evaluation; lazy operation disclosure; sidebar policy; thumbnails/Quick Look reuse/cancellation; settings and location persistence; VoiceOver and keyboard access.
- Runtime/performance: approved synthetic 100k selection/snapshot/planning fixtures separately from widget frame timing; ten tabs/two windows; monitor storms/teardown; offline/denied/disk-full cases; 30–60 minute soak with memory/latency/hardware and warm/cold context. Portable timing is not Mac acceptance.

The prompt is `docs/handoff/MAC_CLAUDE_PROMPT.md`.

## Historical wave 12–17 integration inventory

These are components inside the existing six portable libraries plus disabled UI/App
modules, not new manifest targets. Lane IDs identify implementation records; this
inventory does not assign an undocumented individual wave number to each commit.

| Component / evidence | Implemented portable draft | Deferred host/native work |
| --- | --- | --- |
| K31 FileSystem/Loading; `LoadingTests/K31LoadingTests.swift`, `T2DirectoryLoaderTests.swift` | DirectoryLoadPipeline, cancellation-aware loading and DirectoryReloadCoalescer | Native watch lifetime, UI partial/error reporting, current options injection and live acceptance |
| K32 Core/Store; `StoreTests/WindowStoreTests.swift`, `K34MonitorLifecycleTests.swift` | MainActor FIFO WindowStore, mailbox, selection binder and independent load/watch/reload/validation cancellation | Install DirectoryEffectRunner plus host fallback; native widgets, service composition, session saves and shutdown |
| K33 Persistence/Tags and ViewOptions; `K33TagCatalogTests.swift`, `K33LocationViewOptionsTests.swift`, `K33PreferenceDocumentTests.swift` | Persistent catalogue, bounded location records, explicit flush, read-only corruption recovery and future-schema refusal | One owner per document; save/quit/error/recovery UI and Finder interoperability; Core's in-memory options store is a separate implementation |
| K34 Core/Naming and Identity, FileSystem, Operations, UI/Sheets; `K34CancellationTests.swift`, `K34ConditionalMutationTests.swift`, `K34AtomicExecutorTests.swift`, `K34BatchRenameWorkerTests.swift` | Throwing cancellation hooks, one active/latest pending rename worker; conditional identity contract with atomic fake and refusing live provider; monitor validation acknowledgements; shared 96-pixel default | Live conditional mutation provider, atomic output receipt/content evidence, host teardown, Mac SwiftUI isolation and large-selection dismissal acceptance |
| K35 Core/Inspector; `InspectorTests/InspectorEditModelTests.swift`, `InspectorPresentationTests.swift` | Mixed metadata, per-item permission/edit plans, capability defaults, section and size state | Enriched loader, verified mutation executor/journal, native inspector UI, cancellable recursive totals and preference persistence |
| K36 Core/Accessibility; `AccessibilityTests/AccessibilityTests.swift` | Locale-aware descriptions, stable scoped IDs, throttled operation announcements and action descriptions | AppKit/SwiftUI roles, notification delivery, localization resources, VoiceOver/keyboard/device acceptance |
| F5–F8 corrections; `docs/prereview/fixes-F5.md` through `fixes-F8.md` | Admission/cancellation, monitor generations, forward evidence/replacement checks and overlapping-source UI; K34 supersedes F8's cancellation deferral | Native race/fidelity/timeout recovery, per-window journal, UI hosting and Opus review remain open |
| T2 adversarial tests and P8–P11 review; wave 17 F9–F12 fix lanes | Portable regression/review inputs; F12 documentation reconciles P11 | Historical F12 snapshot; consume F9–F11 final reports and later F13–F18 corrections in the review queue |

For every asynchronous `refreshPaths` or `validateNavigation` effect, return a
`StoreEffectCancellation`. WindowStore retains separate reload/validation handles
and cancels them on replacement, monitor retirement, tab disposal and shutdown.
`DirectoryEffectRunner` demonstrates this contract. Returning nil is suitable only
for synchronous work or explicitly host-owned work with its own cancellation
contract. Generation rejection alone does not stop a task.

## Waves 18–21 additions and F13–F18 corrections — F22 inventory

These directories are components of existing targets, not new modules or native
feature acceptance. Evidence below was checked against source APIs and XCTest
assertions; known P16–P18 findings remain subject to F19–F21 and Opus review.

| Component / source notes | Portable draft and test evidence | Deferred execution / review |
| --- | --- | --- |
| K37 [CloudPolicy](../../Sources/HelmCore/CloudPolicy/README.md) | Access/eviction admission, explicit request identity and provider-boundary warnings; `CloudPolicyTests` checks capability tables, stale progress and cancellation | Native materialization/eviction, trusted provider capabilities and uploaded-state validation; no cloud action is executed |
| K37 [Sharing](../../Sources/HelmCore/Sharing/README.md) | Frozen selection and request lifecycle; `SharingTests` checks picker/provider stages and stale completion | Native picker/transport and exact-action approval; P18 URL normalization review, no sending code |
| K37 [PathPresentation](../../Sources/HelmCore/PathPresentation/README.md) | Selected-result ancestry/common parent and action intents; `PathPresentationTests` checks component boundaries and selection context | Native path bar, navigation/reveal/drop; P18 lexical normalization and directory-hint membership fixes need review |
| K38 [OperationHistory](../../Sources/HelmCore/OperationHistory/README.md), [Operations History](../../Sources/HelmOperations/History/README.md) | Per-window reservations, result mapping and inverse planning bridge; `OperationHistoryTests`, `WindowOperationHistoryTests`, `HistoryResultMappingTests` | P16 forward settlement and inverse-result identity; native responders, safe redo, reconciliation, durable storage and bounded retention. Existing tree/native mutation refusal remains |
| K39 [SearchSessions](../../Sources/HelmCore/SearchSessions/README.md), [Search Sessions](../../Sources/HelmSearch/Sessions/README.md) | Generation-bound state, injected stream driver and saved-definition open plan; `SearchSessionStateTests`, `SearchSessionDriverTests`, `SavedSearchOpenPlanTests` | P17 terminal stream teardown; Spotlight lifecycle, host publication and full envelope-to-TabAction integration. Definition removal is only an intent |
| K40 [InspectorSessions](../../Sources/HelmCore/InspectorSessions/README.md) | Owner/mode registry, confirmation/read tokens and size projection; `InspectorSessionRegistryTests`, `InspectorSizeProjectionTests` | P17 same-path reuse and enrichment scaling; native windows, reads/progress conversion, prompts and save execution. Supplied totals are not a recursive walker |
| K41 [SpringNavigation](../../Sources/HelmCore/SpringNavigation/README.md) | Temporary navigation, restore context and commit intents; `SpringNavigationTests` checks ABA, cancellation and drop completion | P18 changed post-drop metadata and URL admission; native drag/load cancellation, live scroll and commit routing |
| K41 [Gallery](../../Sources/HelmCore/Gallery/README.md) | Selection/preview identity and bounded thumbnail demand; `GalleryTests` checks stale preview and 100k demand bounds | P18 page step versus prefetch; ViewMode/menu activation, rendering and imaging lifetime. Bounded demand is not widget performance |
| [F13](../prereview/fixes-F13.md), [F16](../prereview/fixes-F16.md) | Journal output evidence retained for leaf undo; clean cancellation versus uncertain mutation; `F13UndoEvidenceTests`, `F13CancellationTests`, `F16CancellationTests` | Native atomic receipts and tree evidence remain missing; F16's second-inverse identity-substitution interleaving coverage remains a disclosed gap |
| [F14](../prereview/fixes-F14.md), [F17](../prereview/fixes-F17.md) | Monitor request stamping, bounded recovery, dirty replay and typed-filter-only search; `F14MonitorOrderingTests`, `F14MonitorRecoveryTests`, `F17SearchTests`; strengthened FIFO/cache/persistence oracles | Native watcher lifecycle/degraded UI and host wiring; F17 supersedes the synthetic retry rootChanged behavior in earlier F14 prose |
| [F15](../prereview/fixes-F15.md) | Documentation aligns existing contracts and distinguishes portable policy from host integration | Documentation does not implement native capabilities or close review findings |
| [F18](../prereview/fixes-F18.md) | `F18PropertiesSizeTests` and `F18PropertiesAdapterTests` independently cover package contents, trusted totals and partial states; stronger progress/rename-worker tests | P14-5 producer snapshot-construction bounds remain deferred; trusted totals require selection identity and native UI/size adapter acceptance |

Review F19–F21's final reports for current P16–P18 dispositions; this inventory
records the contracts and review obligations without duplicating their reports.
