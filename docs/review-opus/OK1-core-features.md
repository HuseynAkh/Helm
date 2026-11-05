# OK1: Core features and search review

**Review of Astra draft, 2026-11-04 after 22:00 Toronto**

## 1. Result

**Not ready to accept.** The value models are mostly sound and the prior fixes in scope hold, with one exception (P3-7). Two defects block acceptance: one is a compile error on macOS, the other makes ordinary local files unusable once its policy is wired. Search also has no working end-to-end path on a Mac.

| Severity | Count | IDs |
|---|---|---|
| Blocker | 2 | OK1-1, OK1-2 |
| Major | 10 | OK1-3 to OK1-12 |
| Minor | 22 | OK1-13 to OK1-34 |

No prior finding was rejected. Of the prior findings in scope, one is Fixed-with-new-issue (P3-7) and one parity item is Not-fixed (P-054). The rest are Confirmed-fixed, with limits noted in section 7.

## 2. Scope, method and limits

**Scope:** `Sources/HelmCore/{DragDrop,Gallery,Imaging,Inspector,InspectorSessions,OpenWith,PathPresentation,Search,SearchSessions,SpringNavigation,Sharing,CloudPolicy,Accessibility}` and `Sources/HelmSearch`, 53 source files. Operation history (K38) is excluded. `O1-operation-safety.md` was not read.

**Packets:** `CONTRACT_INTEGRATION.md` maps K37, K39, K40 and K41 to modules (lines 361-373), but my search did not find a mapping for K24-K26, K35 or K36. This report is therefore organised by module, which covers the whole named scope.

**Evidence labels:**
- **[S]:** read in source.
- **[K]:** my knowledge of the SDK or platform, not compiled here.
- **[Mac]:** needs a run on a Mac to settle.

**Limits:**
- **Nothing was compiled or run.** There was no shell in this session. Every compile claim below comes from reading the code.
- **The branch moved during the review.**
  - `forge/rebuild-build` read `6f71195a` when I wrote this, and `078c5dc` and `d74fe11` earlier in the session. `REVIEW_QUEUE.md` names `0021ac6` as the code baseline.
  - I read the ref file directly because `git log` was unavailable. I do not know what `6f71195a` contains.
  - I saw `MetadataReader.swift:34` change while reviewing, so another lane is editing this tree.
- **Line numbers have two sources.**
  - Re-read in the final pass: SearchEngine, CompositeSearchSource, SearchQueryParser, SearchSessionDriver, SearchContracts, SavedSearchOpenPlan, SpringNavigationSession, DropPlanner, DropValues, DropSession, GalleryState, GalleryViewport, IconRequest, ThumbnailCoordinator (lines 25-99), LexicalLocalPath, CloudActionPlan, CloudAvailability, MetadataReader, RowDescription (lines 1-40), SharingRequest, and the test files listed as read in section 6.
  - Other citations come from notes made earlier in the review. Re-check those lines before applying a fix.
- **Files with no recorded review notes:** SearchCriteriaEditor, EditPlan, InspectorSections, InspectorValue, InspectorSizeState, SearchRankedBatch, SpringNavigationValues, ModuleInfo. I make no positive claim about them.
- **Tests not read or only partly read** are listed in section 6.

## 3. Review by module

| Module | Compile (by reading) | Behaviour | Findings |
|---|---|---|---|
| DragDrop | `DropProposal` and `DropOperation` collide with SwiftUI | Overlap check is correct. Admission gaps remain | OK1-1, OK1-9, OK1-14, OK1-15, OK1-25 |
| SpringNavigation | No issue found | Identity logic is good. Source mask and URL comparison are wrong | OK1-9, OK1-10, OK1-16 |
| Gallery | No issue found | Paging is fixed. Filmstrip demand churns | OK1-8, OK1-22 |
| Imaging | Actor `deinit` is at most a warning in Swift 5 mode [K] | Teardown is fixed. No in-flight limit | OK1-11, OK1-12, OK1-17 |
| CloudPolicy | No issue found | Contract is wrong for ordinary files | OK1-2, OK1-19 |
| PathPresentation, Sharing | `SharingSessionState.swift:66` is a low type-check-time risk on 5.9 | Lexical admission is good | OK1-26 |
| OpenWith | No issue found | Identity and lookup cost | OK1-21 |
| Inspector, InspectorSessions | No issue found | No hard defect. Early edits are dropped silently | OK1-27 |
| Accessibility | No issue found | English phrases are a documented limit (`T3-findings.md:32-33`) | OK1-33 |
| Search, SearchSessions, HelmSearch | No issue found | No end-to-end path. Several silent or fatal failure modes | OK1-3 to OK1-7, OK1-13, OK1-18, OK1-20, OK1-23, OK1-24 |

**Compile checks that came back clean:**
- A search of all of `Sources` found no `throws(`, `nonisolated(unsafe)`, `@retroactive`, `import Synchronization`, `Mutex<`, `sending`, `repeat each`, `@preconcurrency` or `.formatted(`. Nothing of that kind needs a newer compiler or OS than Swift 5.9 and macOS 14.
- The Foundation APIs I checked in scope exist on macOS 14, including `AsyncStream.makeStream` [K].
- `CloudAvailability.swift:26` uses `case .current?` on a struct-typed status. I expect it to compile through the expression-pattern fallback [K], but check it at the first Mac type-check. The file is outside scope.

**Cross-cutting gap:** nothing outside the value models consumes these packets yet. A search of HelmUI, HelmApp, HelmFileSystem, HelmOperations and HelmPersistence found no drag adapter, no Quick Look or thumbnail producer, and no real `SearchService` or `MetadataSearchSource`. The only hits were `DropProposal` display code in `HelmUI/Content`. `CloudActionPlan` has no production caller either. The handoff documents acknowledge this, but it means none of this behaviour has been tested end to end, even in fakes.

## 4. Findings: Blocker

### OK1-1: `DropProposal` is ambiguous in HelmUI on macOS

- **Where:** `Sources/HelmCore/DragDrop/DropValues.swift:13,56`, `Sources/HelmUI/Content/ContentOverlays.swift:2-5,30,32`.
- **Failure:** `ContentOverlays.swift` imports both SwiftUI and HelmCore and uses `DropProposal` unqualified. SwiftUI exports `DropProposal` and `DropOperation` [K]. The first macOS build of HelmUI should fail with `'DropProposal' is ambiguous for type lookup in this context`.
- **Why Linux missed it:** the file sits inside `#if canImport(AppKit)`, and HelmUI is commented out of `Package.swift:26-34`.
- **Related:**
  - `HelmCore.ToolbarItem` is the same kind of name. The HelmUI uses I found are qualified (`ToolbarCustomizationModel.swift:6`), so the problem was known for that type but missed here.
  - `DropSession` (`DropSession.swift:7`) may collide with a newer SwiftUI `DropSession` on the macOS 26 SDK. That is my recollection and needs checking [Mac].
  - `scripts/` has no check for these names, despite review-01 Fix 16.
- **Fix:**
  1. Minimum: write `HelmCore.DropProposal` at `ContentOverlays.swift:30,32`.
  2. To comply with Fix 16: rename to `FileDropProposal`, `FileDropOperation` and `FileDropSession` across Core, HelmUI and tests.
  3. Add a static check that fails on public Core types named after SwiftUI, AppKit or Foundation types.
- **Mark:** SIMPLE.

### OK1-2: `.unknown` means both "metadata unread" and "ordinary local file"

- **Where:** `Sources/HelmFileSystem/Providers/CloudAvailability.swift:23`, `Live/MetadataReader.swift:45`, `Sources/HelmCore/CloudPolicy/CloudActionPlan.swift:28-33`, `CloudPolicy/README.md:6-9`, `CONTRACT_INTEGRATION.md:114`.
- **Failure:** for `~/Documents/a.jpg` on a normal APFS volume, `isUbiquitousItem` is false, so the reader returns `.unknown`. `CloudActionPlan.build` then gives:
  - `.suppressThumbnail` for thumbnails.
  - `.unsupported` for explicit open and explicit preview.

  A host that follows the documented plan shows no thumbnails and cannot open or preview any file outside iCloud. This breaks F-007, F-048 and F-049.
- **Status:** latent. `CloudActionPlan` has no production caller today, so nothing fails at runtime yet. It blocks the wiring stage. `CloudPolicyTests.swift:18,20,37-44` enshrines the behaviour.
- **Fix:**
  1. Add `CloudAvailability.notCloud`, keeping the existing legacy decode fallback.
  2. Return it at `CloudAvailability.swift:23` when the read succeeded and the item is not ubiquitous. Keep `.unknown` for metadata that could not be read.
  3. In `CloudActionPlan`, treat `.notCloud` as `.useLocalContent` for thumbnails and explicit access. Eviction stays `.local` only.
  4. In `RowDescription.swift:27-32`, say nothing for `.notCloud`.
  5. Update every exhaustive switch and the CloudPolicy tests.
- **Do not** map these files to `.local`: `RowDescription.swift:28` would then announce "available offline" on every row.
- **Owner decision:** whether explicit open on a true `.unknown` should stay refused. My recommendation is to let the host attempt it, because refusing to open a file over a failed metadata read is the worse outcome.
- **Mark:** JUDGEMENT.

## 5. Findings: Major and Minor

### Major

#### OK1-3: No working search path; the seams do not fit together

- **Where:** `01-architecture.md:274-277`, `CompositeSearchSource.swift:22-26,64-97`, `SearchEngine.swift:57-59`, `SearchContracts.swift:34-46`, `SearchSessionDriver.swift:8,13-29`, `CONTRACT_INTEGRATION.md:109-111,363`.
- **Failure:**
  - The planned `Spotlight/SpotlightQueryBuilder.swift`, `Spotlight/SpotlightSearchService.swift`, `Rank/RankingWeights.swift`, `Rank/PreferredRoots.swift` and `SearchConfiguration.swift` do not exist.
  - Four shapes need adapting to one another: the `SearchService` event stream, the one-shot `MetadataSearchSource.snapshot`, the `CompositeSearchSource` single result, and the `SearchEngine` stream.
  - Legacy search receives live `NSMetadataQueryDidUpdate` updates (`SpotlightSearchService.swift:82`). The finite snapshot seam cannot carry those.
  - `SearchState` (`SearchContracts.swift:34-42`) has no truncation or disclosure fields, so B-026 disclosure is lost at tab state.
- **Fix:**
  1. Replace the snapshot with `updates(for:) -> AsyncThrowingStream<SearchMetadataSnapshot, Error>`.
  2. Make the composite emit a stream of `CompositeSearchResult`, adapted by `SearchSessionDriver`.
  3. Add truncation and disclosure to tab state.
  4. Build the Spotlight files, or amend the layout to match what is built.
- **Mark:** JUDGEMENT.

#### OK1-4: F-044 scope loses bookmarks and removable volumes

- **Where:** `SearchEngine.swift:18`, `CompositeSearchSource.swift:77-82`, `CONTRACT_INTEGRATION.md:112-113`. Legacy: `00-current-state.md:152`, `SpotlightSearchService.swift:154-162`.
- **Failure:** a user bookmarks `/Volumes/Work/Project` and searches the default scope. Legacy searched it. Now `.home` and `.userFolders` resolve to `[home]`, and the composite filter drops those results even when Spotlight returns them. The handoff records this as intended, but it is a parity loss.
- **Fix:**
  1. Give `SearchRootResolver` injected bookmark and removable-volume roots, and return the union for `.home` and `.userFolders`.
  2. Update `CONTRACT_INTEGRATION.md:112-113`.
  3. Add a test with a bookmark outside Home.
- **Mark:** SIMPLE.

#### OK1-5: Some searches return an empty result that looks complete (new issue from P3-7)

- **Where:** `SearchEngine.swift:102,113`, `EnumerationSearchService.swift:36`, `CompositeSearchSource.swift:78-81`, `MetadataReader.swift:17-24`. Enshrined at `SearchEngineTests.swift:112-113,157-159`.
- **Failure:** in each case below the user sees "no results" with `truncated == false` and no diagnostic.
  - **Symlink root:** the current folder is `/tmp` on macOS, or a user-made symlink. Its kind is `.symlinkToDirectory`, so line 102 skips it silently.
  - **Package root:** the tab is inside a package via Show Package Contents. Line 102 skips it silently.
  - **Spotlight path mismatch:** Spotlight returns real paths such as `~/real/x`, while the lexical root is `~/link`. The filter at `CompositeSearchSource.swift:80` drops them all, and with `.available` there is no fallback.
  - **Non-child drop:** line 113 drops any child whose parent path does not match the root. If `enumerator(at:)` returns `/private/...` paths that `standardizedFileURL` does not fold back, every child is dropped [Mac].
- **Fix:**
  1. **SIMPLE part:** at lines 102 and 113, emit a new `SearchDiagnostic.rootNotSearchable(URL)` or a dropped-entry diagnostic and set `truncated = true`.
  2. **JUDGEMENT part:** decide whether an explicit user-chosen root may be followed at depth 0 only. My recommendation is yes for the current folder, which still respects P3-7 by never following links deeper in the walk. Compare Spotlight results against both the lexical and the resolved root.
- **Mark:** JUDGEMENT, with a SIMPLE first step.

#### OK1-6: One vanished directory discards the whole search

- **Where:** `SearchEngine.swift:124-127`, `EnumerationSearchService.swift:34`, `LiveFileSystem.swift:44-45`.
- **Failure:** partway through walking Home, a build directory is deleted, or a Trash root is on an unmounted volume. `entry(at:)` or `opendir` raises `.notFound`, `candidates` rethrows, and all results gathered so far are lost.
- **Fix:**

  ```swift
  } catch {
      try Task.checkCancellation()
      switch FileSystemError.mapping(error) {
      case .permissionDenied:
          diagnostic(.unreadable(directory)); truncated = true
      case .notFound where depth > 0 || roots.count > 1:
          diagnostic(.unreadable(directory)); truncated = true
      default:
          throw error
      }
  }
  ```

  Add tests for a subdirectory that vanishes and for a missing root among several. The existing root-level assertion at `SearchEngineTests.swift:73-75` stays valid.
- **Mark:** SIMPLE.

#### OK1-7: Query grammar regresses literal search and errors while typing

- **Where:** `SearchQueryParser.swift:11-21,28-46`, `SearchSessionDriver.swift:43,65`. Legacy: `00-current-state.md:152`.
- **Failure:** legacy treated the whole string as a literal filename match. Now:
  - Typing `"foo` raises `unterminatedQuote`, and a trailing `\` raises `danglingEscape`.
  - Partial filters such as `kind:` or `size:` raise `invalidFilter` while the user is still typing.
  - The tokenizer discards quote and escape state, so `"kind:x"` and `kind\:x` still parse as filters. The README says these are literal text.
  - A file named `before:today.txt` cannot be found by name, because the query fails instead.
  - The driver shows the raw Swift error text to the user (`String(describing:)`).
- **Fix:**
  1. **SIMPLE:** have the tokenizer return `(text, isLiteral)`, marking any token containing a quoted or escaped character. `compile` then sends literal tokens straight to `.name`.
  2. **JUDGEMENT:** set the incomplete-input policy. My recommendation is that an unterminated quote runs to the end of the text, an empty `key:` is a name, and an unknown filter value is a name rather than an error. Map errors to user-facing strings in the driver.
- **Mark:** SIMPLE and JUDGEMENT.

#### OK1-8: Filmstrip demand churns on every selection change

- **Where:** `GalleryState.swift:28-30,42-50,58-62`, `GalleryViewport.swift:44-51`, Gallery README.
- **Failure:**
  - Every filmstrip request carries `generation`, and `invalidate()` regenerates it on each select, move and snapshot replacement. The README tells hosts to diff requests and cancel subscriptions.
  - Holding an arrow key therefore makes every visible request look new on each repeat. Cancelling first restarts producers, so thumbnails may not finish during key repeat. Subscribing first still churns every subscription on each press.
  - A monitor event calling `replaceSnapshot` has the same effect and also clears `completedPreview`.
  - Filmstrip cells and the large preview share one `dimensions`, default 640×480.
- **Fix:**
  1. Return `GalleryFilmstripRequest(key:changeToken:)` from `filmstripRequests`, with no generation. Keep `generation` on `previewRequest` only.
  2. Add separate `filmstripDimensions`.
  3. In `replaceSnapshot`, invalidate only if the selected entry's change token changed.
  4. Add a test that filmstrip requests are identical across `move` when the viewport is unchanged.
- **Mark:** SIMPLE.

#### OK1-9: Spring drop ignores the source's allowed operations and advertises alias

- **Where:** `SpringNavigationSession.swift:64-69`, `DropSession.swift:24-25`, `DropPlanner.swift:8`, `ContentLeafPresentation.swift:25`, DragDrop README.
- **Failure:**
  - `acceptDrop` has no `allowedOperations` parameter, so a Command-drop is accepted as `.move` even when the drag source only permits copy.
  - Control-drop becomes `.alias`, and the UI badge says "Create Alias". `FileSystem.createAlias` exists, but my search found no alias support in HelmOperations. The README says to add a Command before advertising it.
- **Fix:**
  1. Add a required `allowedOperations: Set<DropOperation>` to `acceptDrop` and pass it through.
  2. Remove `.alias` from the defaults at `DropPlanner.swift:8` and `DropSession.swift:25` until a Command exists.
  3. Update the callers in tests and add a mask test.
- **Mark:** SIMPLE.

#### OK1-10: Spring drop compares raw URLs

- **Where:** `SpringNavigationSession.swift:67`.
- **Failure:** the same defect class as P18-4. If the target is `file:///dest/` and the destination is `file:///dest`, or one uses `file://localhost/`, `URL ==` can be false and a valid drop on the hovered folder is silently refused. `F21RegressionTests.swift:104` passes the same URL on both sides, so it cannot catch this.
- **Fix:**

  ```swift
  guard case .directory(let destinationURL) = destination.location,
        let destinationPath = LexicalLocalPath(destinationURL),
        destinationPath.key == path.key else { return nil }
  ```

  Add a test with mismatched hint and localhost spellings.
- **Mark:** SIMPLE.

#### OK1-11: Default icon policy gives apps and links generic icons

- **Where:** `IconRequest.swift:13-14,20-35`, `PreviewAndIconTests.swift:36-54`. Legacy: `00-current-state.md:155`.
- **Failure:** legacy cached icons per path. Now every `.app` gets the same `.contentType` key, symlinks to directories become plain `.folder` with no link badge, and custom folder icons are lost. The comment at line 13 says file-specific lookup is opt-in, but nothing decides when to opt in, so the wrong result is the default.
- **Fix:**
  1. **SIMPLE:** add `IconPolicy.recommended(for:)` returning `.fileSpecific` for `.package`, `.alias`, the symlink kinds and `.danglingSymlink`, make it the default, and add tests for those kinds.
  2. **JUDGEMENT:** custom folder icons need a cheap metadata signal. Choose one, or accept the loss.
- **Mark:** SIMPLE and JUDGEMENT.

#### OK1-12: No limit on in-flight thumbnail work

- **Where:** `ThumbnailCoordinator.swift:58-72`, `P3.md:82`, parity P-054.
- **Failure:** the coordinator starts every distinct key immediately. A grid with 500 visible and prefetched cells starts 500 producers at once. The cache cost limit does not bound these.
- **Fix:** add `maxConcurrent` with a default of 4, a pending queue that starts work on completion or cancel, and removal without starting when a queued key is cancelled. Queue priority, such as visible cells first, is the design choice. Add a test using a gated producer.
- **Mark:** JUDGEMENT.

### Minor

| ID | Where | Problem | Fix | Mark |
|---|---|---|---|---|
| OK1-13 | `SearchRanker.swift:19-22`, `00-current-state.md:153` | Preferred roots are the fixed list only. Legacy added every visible Home folder, so `~/Clients` loses the boost. Dropping enumeration during ranking was the right B-026 fix, but nothing supplies the list now. The effect is ranking only and the seam exists. | Add `Rank/PreferredRoots.swift` to discover the list off the main actor, and have the host pass it in. | SIMPLE |
| OK1-14 | `DropPlanner.swift:27` | Items already in Trash can be proposed for `.moveToTrash`. The same-parent check only runs for `.directory`. | Add a source-in-Trash fact to `DraggedItem` and reject as a no-op. | SIMPLE |
| OK1-15 | `DropPlanner.swift:47-49`, `DropPlannerTests.swift:53` | One source already in the target rejects the whole batch. Finder, as I recall it, moves the others [K]. | Decide whether to keep the B-040 reading or move the rest. | JUDGEMENT |
| OK1-16 | `SpringNavigationSession.swift:33-35,48`, `SpringNavigationTests.swift:24` | No API captures per-level selection or scroll, so retreating restores an empty state. `leaveHover` emits no cancel, so a pending load keeps running. | Add `updateCurrentContext(selection:scroll:)` and a `.cancelLoad(request)` effect. | SIMPLE |
| OK1-17 | `ThumbnailCoordinator.swift:47-49,90-99` (recency around lines 122, 150) | `onTermination` spawns a Task on every finish, including cache hits, and each cancel scans all flights. Recency updates are O(n). | Act only on `.cancelled`. Index token to key. Use an O(1) recency structure. | SIMPLE |
| OK1-18 | `SearchEngine.swift:97,109` | `popLast` makes the walk depth-first, so one deep subtree can use the whole visit budget. The sort comparator standardizes URLs on every comparison. | Walk breadth-first with an index. Compute sort keys once. | SIMPLE |
| OK1-19 | `CloudActionPlan.swift:48-52`, `SavedSearchOpenPlan.swift:17,35` | Local-URL admission is duplicated and inconsistent. `SavedSearchOpenPlan` is case-sensitive on `localhost` and accepts query, fragment and user parts. Neither uses the F24 parser. | Make `LexicalLocalPath` public and route both through it. | SIMPLE |
| OK1-20 | `SearchEngine.swift:17,20,94-95`, `MetadataReader.swift:14`, SavedSearchDocument | Scope URLs from a definition file are not validated. `currentFolder("https://x/Users/me/secret")` walks the local path `/Users/me/secret`. | Reject non-local roots in `SearchQueryParser.compile` with a new parse error. | SIMPLE |
| OK1-21 | `ApplicationResolving.swift:8-9`, `OpenWithModel.swift:40-50` | App identity is a standardized URL, so a trailing-slash difference can empty the intersection. Each selected item makes two sequential lookups, which is slow on large selections. | Key on the lexical path or bundle ID. Group lookups by content type. | SIMPLE |
| OK1-22 | `GalleryState.swift:20,29` | Gallery uses all sorted entries, including expanded children past `rootCount`. | Decide the policy. If root items only, use `rootCount`. | JUDGEMENT |
| OK1-23 | `EnumerationSearchService.swift` | The service and `SearchFallbackPolicy` have no production callers, only tests (`SearchTests.swift:91,105-106,123`, `K13FallbackTests.swift:20-61`, `F3SearchTests.swift:55`, `ContractIntegrationTests.swift:33`, `K13SearchTests.swift:70`). It also lacks SearchEngine's error tolerance, so those tests inflate apparent coverage. | Delete both and port the useful tests to `SearchEngine`. | SIMPLE |
| OK1-24 | `Core/Search/SearchSpecification.swift:39`, `SearchSessionState.swift:35` | A `Locale` is created per clause per entry. `start` clears results, so they flicker on refresh. | Reuse one `Locale`. Keep the old results until the first new batch. | SIMPLE |
| OK1-25 | `DragSourceModel.swift:38`, `DropPlanner.swift:32,48`, `DropSession.swift:39,42`, `DropPlannerTests.swift:45` | Drop paths still use `standardizedFileURL`, which collapses `..` lexically. That can differ from the real location through a symlink. | Resolve with the deferred ItemID owner decision (`REVIEW_QUEUE.md:43-45`). | JUDGEMENT |
| OK1-26 | `SharingSessionState.swift` | The architecture prefers `standardShareMenuItem` for F-063, but only picker presentation is modelled. | Decide at native adapter time and add the effect if needed. | JUDGEMENT |
| OK1-27 | `InspectorSessionRegistry.swift:44-47` | Edits before enrichment finishes are dropped silently. The host must disable the fields. | Return a rejection effect so the drop is visible. | SIMPLE |
| OK1-28 | `SearchSessionDriverTests.swift:10-18,33-36,87-125` | `settled()` returns silently at its deadline. A "source not invoked" check can pass after return. The stale-terminal test does not force the interleaving. | Fail at the deadline. Gate the source so the order is forced. | SIMPLE |
| OK1-29 | `F1DropWorkTests.swift:34-44` | The 10k case only prints a diagnostic and asserts no bound. The real bound is at lines 7-15. | Assert a comparison bound or delete the case. | SIMPLE |
| OK1-30 | `ThumbnailCoordinatorTests.swift:101-103` | Asserts a weak reference is nil immediately. Task retention timing may differ on Darwin [Mac]. | Poll to a deadline and fail with a message. | SIMPLE |
| OK1-31 | `CloudPolicyTests.swift:18,20,37-44`, `SearchEngineTests.swift:112-113,157-159`, `SpringNavigationTests.swift:24`, `DropPlannerTests.swift:45,53` | These tests enshrine behaviour this report calls defective, so they will fail when it is fixed. | Change them in the same lane as OK1-2, OK1-5, OK1-16, OK1-25 and OK1-15. Do not treat these failures as regressions. | SIMPLE |
| OK1-32 | `PreviewAndIconTests.swift:36-54`, `CriteriaHardeningTests.swift:68-71`, `GalleryTests`, `SpringNavigationTests`, `SearchEngineTests` | Missing tests: package, alias and symlink icons; compile-level literal handling; filmstrip stability; spring source mask; subdirectory `notFound`; `/private` roots. | Add each with its related fix. | SIMPLE |
| OK1-33 | `AccessibilityTests.swift:22-23,155,163,209`, `T3AccessibilityTests.swift:81-86` | Exact digit and separator expectations for bare `ar` and `fr_FR` depend on ICU data. Apple's defaults may differ from Linux [Mac]. | Use an explicit `ar@numbers=arab` locale, or compare against a formatter built from the same locale. | SIMPLE |
| OK1-34 | `SharingTests.swift:14`, `F21RegressionTests.swift:107,109`, `F24LexicalPathTests.swift:40,64` | These depend on URL spelling and equality. Darwin Foundation may behave differently from Linux. APFS also treats NFC and NFD names as the same file, which the F24 byte keys deliberately do not [K]. | Run on a Mac first. Change only on evidence, and record the APFS case in the ItemID decision. | JUDGEMENT |

## 6. Test quality

**Portability and skips:** the scoped test files I searched have no `XCTSkip`, no Linux conditionals and no sleeps. That does not make them Mac-proven. See OK1-30, OK1-33 and OK1-34.

**What holds up well:**
- `F21RegressionTests` and `F24LexicalPathTests` have strong oracles at real boundaries, including real symlinks.
- `InspectorReuseRegressionTests` checks stale reads, replacement identity and decision tokens.
- `SavedSearchOpenPlanTests` covers refusal paths.
- `CloudPolicyTests` is exhaustive, but it exhaustively encodes the OK1-2 contract.

**What to distrust:**
- **Enshrined defects:** OK1-31.
- **Weak oracles:** OK1-28, OK1-29.
- **Tests of dead code:** OK1-23.
- **Happy-path identity:** tests pass the same URL value on both sides of a comparison, which is how OK1-10 went unnoticed.
- **The 1,198 and 1,213 test totals:** these say nothing about native behaviour in this scope. Everything here runs against fakes and value models.

**Read in full:** F24LexicalPathTests, F21RegressionTests, AccessibilityTests, T3AccessibilityTests, DragInteractionTests, SearchEngineTests, CloudPolicyTests, SavedSearchOpenPlanTests, OpenWithModelTests. From earlier notes: GalleryTests, SpringNavigationTests, ThumbnailCoordinatorTests, PreviewAndIconTests, SearchSessionDriverTests, DropPlannerTests, F1DropWorkTests.

**Partly read:** SharingTests (first 70 lines), InspectorReuseRegressionTests (first 80), InspectorEditModelTests (first 60).

**Not read:** PathPresentationTests, InspectorSessionRegistryTests, InspectorSizeProjectionTests, InspectorPresentationTests, T3InspectorTests, K13SearchTests, K13FallbackTests.

## 7. Prior findings: dispositions

| Finding | Disposition | Evidence |
|---|---|---|
| P1-2 / F1 | Confirmed-fixed | `DropPlanner.swift:55-64`, `DropSession.swift:32-46`. The adjacent-pair check is correct: anything sorted between an ancestor and its descendant also has that ancestor as a prefix. |
| P3-4 / F3 | Confirmed-fixed | `ThumbnailCoordinator.swift:36-42,79-88`. |
| P-054 throttle (`P3.md:82`) | Not-fixed | `ThumbnailCoordinator.swift:58-72`. See OK1-12. |
| P3-5 | Confirmed-fixed | `SearchQueryParser.swift:37,55-59`. |
| P3-6 | Confirmed-fixed | `SavedSearchDocument.swift:21-24,42-47`. |
| P3-7 | Fixed-with-new-issue | `EnumerationSearchService.swift:36`, `SearchEngine.swift:102`. Roots are no longer entered, but the result is a silent empty. See OK1-5. |
| P4-1 / F4 | Confirmed-fixed, macOS compile pending | `SearchBarModel.swift:45`, `R1.md:92`. |
| P5-4 / F6 | Not assessed: fix is in `State/TabReducer.swift`, outside this scope | `fixes-F6.md:14`. `SearchSessionDriver.swift:71-74` is consistent with it. |
| P10-1 / F11 | Confirmed-fixed from source; regression test not re-read | `InspectorEditModel.swift:11-23,37,61-65`. |
| P10-2 / F11 | Confirmed-fixed from source; regression test not re-read | `PermissionsModel.swift:45`. |
| P10-3 | Confirmed-fixed | `RowDescription.swift:21`, `AccessibilityTests.swift:109-117`. |
| P15-1 | Confirmed-fixed | `TabSearch.swift:6`, `SearchSessionState.swift:36`. |
| P15-2 | Not assessed: PropertiesModel is outside this scope | `InspectorSizeProjection.swift` is consistent with the fix. |
| P17-1 / F20 | Confirmed-fixed | `InspectorSessionRegistry.swift:78-84,93-109`, `InspectorReuseRegressionTests.swift:7-45`. |
| P17-2 / F20 | Confirmed-fixed | `InspectorSessionContracts.swift:62,72,82-84`, `InspectorSessionRegistry.swift:52-59`. |
| P17-3 / F20 | Confirmed-fixed for injected streams; native teardown unverified | `SearchSessionDriver.swift:47-67,78-86`. I traced the paths and found no hang, because the task is always cancelled before the iterator wait. |
| P18-1 / F21 | Confirmed-fixed at the value boundary; live identity read is in place | `SpringNavigationSession.swift:74-85,95-99`, `MetadataReader.swift:46,49-53`. |
| P18-2 / F21, F24 | Confirmed-fixed | `SpringNavigationSession.swift:24,28,66`, `LexicalLocalPath.swift:13-18`. |
| P18-3 / F21 | Confirmed-fixed in scoped code | `LexicalLocalPath.swift`, `SharingRequest.swift:14`. ItemID and DropPlanner normalization remain under OK1-25. |
| P18-4 / F21 | Confirmed-fixed at that site | `PathPresentation.swift:45-48`, `F21RegressionTests.swift:45-52`. The same class of bug exists separately at `SpringNavigationSession.swift:67`. See OK1-10. |
| P18-5 / F21 | Confirmed-fixed | `GalleryViewport.swift:20-28`, `GalleryState.swift:39`, `F21RegressionTests.swift:53-67`. |
| P21-1 / F24 | Confirmed-fixed | `LexicalLocalPath.swift:12-26`, `PathPresentation.swift:17,27,47`, `SharingRequest.swift:11`, `F24LexicalPathTests.swift:12-33`. |
| P21-2 / F24 | Confirmed-fixed; see the APFS note at OK1-34 | `LexicalLocalPath.swift:8`, `SharingRequest.swift:8,15`, `SpringNavigationSession.swift:98`, `F24LexicalPathTests.swift:61-94`. |

**Other prior findings:** P3-1 to P3-3 are outside this scope. No finding in scope was classed Rejected-finding.

**Legacy behaviour:**

| ID | Status | Finding |
|---|---|---|
| F-007, F-049 | Broken by contract once wired | OK1-2 |
| F-043 | Preserved in the value model | None |
| F-044 | Scope lost; literal matching regressed | OK1-4, OK1-7 |
| F-045 | Weights match by reading; preferred roots narrowed | OK1-13 |
| F-046 | Live updates and Spotlight absent | OK1-3 |
| F-047 | Per-path icons only by opt-in | OK1-11 |
| F-048 | Bounded demand present; thumbnails blocked by OK1-2; concurrency unbounded | OK1-2, OK1-8, OK1-12 |
| F-063 | Selection and identity good; menu-item flow open | OK1-26 |
| F-067 | Planner good; spring path gaps | OK1-9, OK1-10, OK1-14, OK1-15 |
| B-026 | Fixed in the engine; disclosure lost at tab state | OK1-3 |
| B-040 | Preserved; batch policy open | OK1-15 |
| B-055 | Fixed | None |
| B-099 | Disclosure types exist; silent-empty cases contradict the intent | OK1-5 |

My notes hold no positive verification for F-050, F-062, B-056 or B-066, so I make no claim about them here.

## 8. Suggested order

1. **Now, SIMPLE lane:** OK1-1, OK1-6, OK1-8, OK1-9, OK1-10, then the SIMPLE parts of OK1-5, OK1-7 and OK1-11.
2. **Owner decisions needed:** OK1-2 (cloud contract), OK1-3 (search seam shape), OK1-5 (explicit roots), OK1-12 (thumbnail queue policy).
3. **First Mac run:** build HelmUI to confirm OK1-1, then settle the [Mac] items: `standardizedFileURL` on `/private` paths and what `enumerator(at:)` returns (OK1-5), the ICU expectations (OK1-33), the URL assertions (OK1-34), and the `DropSession` name on the current SDK.

## 9. Verdict and riskiest places

**Verdict: not ready.** Fix the two Blockers before any host wiring starts. Treat search as unbuilt on macOS, not as nearly done. Nothing in this scope is accepted as working on a Mac, because nothing has been compiled or run there.

**The five riskiest places:**

1. **`CloudActionPlan` with `CloudAvailabilityReader`.** The contract would disable thumbnails, open and preview for every ordinary file. The tests lock that in, so a host author following the docs would build it faithfully.
2. **HelmUI use of `DropProposal` (`ContentOverlays.swift:30,32`).** This is a known compile failure hidden by `#if canImport(AppKit)`. Other unverified UI code may fail the same way once the target is enabled.
3. **Search composition (`CompositeSearchSource.swift:77-97`, `SearchEngine.swift:102,113,124-127`).** There is no Spotlight adapter. Scope filtering, symlink roots and fatal `notFound` handling can each produce a wrong or empty answer that looks like a real one.
4. **`SearchSessionDriver` with a native query.** Termination is proven only for injected streams. Real `NSMetadataQuery` teardown, live updates and main-thread requirements are untested and may force the seam to change.
5. **Spring and drop admission (`SpringNavigationSession.swift:64-69`, `DropPlanner.swift:8,27,47-49`).** This is the path closest to moving user files. Ignoring the source mask, advertising alias without an executor, and comparing raw URLs all sit on it. The executor's own revalidation is the remaining safeguard.

Runner-up: Gallery and thumbnail demand (`GalleryState.swift:58-62`, `ThumbnailCoordinator.swift:58-72`), which could become a visible performance problem on the first real image folder.
