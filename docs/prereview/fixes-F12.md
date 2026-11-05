<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# F12 — P11 documentation reconciliation

Documentation-only lane. The explicit request for this report is the sole addition
outside `docs/handoff/*`; Sources, Tests, Package.swift, scripts and legacy Helm
remain untouched by F12. The top-level README now separates rebuild status from its historical legacy description. No network or external action,
commit or push was performed. All findings were rechecked against current source
and existing XCTest assertions before editing. No findings were rejected.

A failing XCTest was not added: the findings concern prose and this lane may not
edit Tests. Existing regressions validate the behavior being documented; no test
was weakened, skipped or deleted. This is a documented deviation from the generic
failure-first instruction, not a claim to have reproduced a source defect.

| ID | Disposition | Files / evidence | Test / residual risk |
| --- | --- | --- | --- |
| P11-1 | FIXED handoff; DEFERRED module README | MAC_HANDOFF operation recovery/M8 now disclose live executor refusal, exclusive creation and direct primitive distinction; FileSystem protocol default throws unsupported, OperationExecutor calls conditional APIs | K34ConditionalMutationTests.testLiveAtomicMutationRefusesAndRetainsSource and K34AtomicExecutorTests.testUnadoptedCopierRefusesWithoutCallingLegacyMutation; native conditional provider remains missing |
| P11-2 | DEFERRED module README; FIXED handoff guidance | MAC_HANDOFF and CONTRACT_INTEGRATION require reload/validation cancellation handles, matching WindowStore and DirectoryEffectRunner | K34MonitorLifecycleTests.testValidationHandlesCancelledByRefreshAndShutdown; native host still must return handles |
| P11-3 | FIXED handoff; DEFERRED module READMEs | README, MAC_HANDOFF inventory/M3/M4/M10/M18/M20/M24 and CONTRACT_INTEGRATION reconcile Store, Loading, Tags/ViewOptions, Inspector, Accessibility, K34 cancellation and R1 fixes | K33 round-trip/recovery tests, Store tests, K34 cancellation/worker tests; native wiring remains open |
| P11-4 | FIXED handoff history/recipe; DEFERRED UI README | VERIFICATION and Mac prompt correct hardcoded-path claims; runner and F4RegressionTests both read HELM_UI_SCRATCH | Configured portable runner and its configuration tests; Mac SwiftUI/AppKit excluded from Linux execution |
| P11-C / Mac SDK priorities | DEFERRED native validation; FIXED checklist | VERIFICATION lists every P11 UI/App SDK site and manifest prerequisite | No confirmed Mac compile failure was reported by P11; SDK compile and hosted acceptance still required |
| F12-ledger | FIXED after fresh passing suite | coverage-ledger.csv regenerated/audited against the 565 supplied catalogue definitions | Citation evidence only; file/class attribution never establishes per-feature assertions or Mac parity |

## README edits to apply later

These exact replacements are for source owners; F12 does not edit module READMEs.

1. `Sources/HelmOperations/README.md`: replace “Ordinary directory Move and
   Trash remain supported; directory root evidence does not prove unchanged descendants.” with:

   > Directory Move and Trash are provider-dependent: InMemoryFileSystem supports the conditional boundary; LiveFileSystem inherits refusal, so live executor copy/move/Trash are unavailable. Exclusive creation remains available. Direct primitives are distinct from executor support. Directory root evidence does not prove unchanged descendants; see the K34 conditional contract below.

   Replace the paragraph starting “Needed changes elsewhere: HelmCore identity/entry types” through “no atomic identity or content guarantee is claimed.” with:

   > K34 supersedes the missing-contract prerequisite: Core identity values and conditional FileSystem/FileCopier APIs now exist. A reviewed native conditional mutation provider and atomic output evidence remain needed. Root identity/token evidence is not complete content or descendant proof; post-mutation observation races remain open.

2. `Sources/HelmCore/Store/README.md`: replace the required-handle sentence with:

   > Return an idempotent StoreEffectCancellation for asynchronous load, monitor, search, completion-request, refreshPaths and validateNavigation work. Reload and validation handles have independent ownership and retire on replacement, monitor retirement, tab disposal and shutdown; see HelmFileSystem/Loading/DirectoryEffectRunner.swift.

   Replace “Runners own one-shot work (Recent, validation, refreshPaths, openFile, persistence)
   and should return nil for those descriptors.” with:

   > Return nil only for synchronous work or explicitly host-owned work with its own cancellation contract. Recent, openFile and persistence tasks require explicit host lifetime management when asynchronous. Validation and refreshPaths tasks return cancellation handles retained by WindowStore.

3. `Sources/HelmUI/README.md`: replace the paragraph beginning “P7-2 remains
   deferred” through “completed fix.” with:

   > K34 supersedes the F8 P7-2 deferral. Core Naming provides throwing cooperative cancellation hooks. BatchRenameWorker keeps one active calculation and only the latest pending revision; replacement, Cancel and disappearance cancel obsolete work. Cancelled evaluations do not populate the cache. Portable cancellation regressions pass; macOS SwiftUI isolation, hosted dismissal and large-selection responsiveness still require acceptance.

   Replace the two runner commands with:

   ```sh
   HELM_K11_SCRATCH=/tmp/build-UI-REVIEW bash scripts/rebuild/run_all.sh
   HELM_UI_SCRATCH=/tmp/build-UI-REVIEW python3 -B Tests/HelmUITests/PortableRunner/run.py
   ```

   Replace “P4's compile regression also invokes swiftc against /tmp/build-F4/debug/Modules.” with:

   > The runner and P4 compile regression both require HELM_UI_SCRATCH and use its freshly built debug/Modules. The configured runner exercises portable UI/App logic; SettingsBindingsTests and ContentNativeAdapterTests still require the Mac SDK.

   Prefix the older “Verification and open questions” section with:

   > Historical K12 slice results follow. Subsequent configured portable UI/App execution is recorded in docs/handoff/VERIFICATION.md; these old unexecuted-test statements do not describe the current portable harness.

4. `Sources/HelmCore/AddressBar/README.md`: replace the initial minimal-contract
   replacement bullet and the closing K9 “remain unchanged” integration request with:

   > K23 already replaced the minimal AddressBar contracts with AddressEditorState/AddressEditorAction in HelmCore; Contracts/AddressContracts.swift retains CompletionRequest. CompletionRequest is shared. Do not introduce duplicate types; native address controller, completion debounce and IME/focus wiring remain host work.

5. `Sources/HelmFileSystem/README.md`: replace “Needed changes elsewhere: K1 needs”
   through “existing FileEntry contract.” with:

   > K23 completed Core-owned FileEntry cloud availability, metadata listing integration, snapshot stamping bridge and AddressEditor contract replacement. Metadata availability is unknown when unreported; Linux remains unknown. The reducer still allocates accepted snapshot IDs. Starred Location remains deferred to an owner decision; native cloud resource keys and provider behavior require Mac verification.

6. `Sources/HelmCore/Presentation/README.md`: replace “FS must implement TagStorage; persistence must
   own location-keyed view-option records. No changes to their files were made.” with:

   > HelmFileSystem/Tags already supplies filesystem TagStorage adapters; native Finder interoperability remains unverified. K33 supplies HelmPersistence.LocationViewOptionsStore and TagCatalogStore. Core ViewOptionsStore remains an in-memory implementation. Choose one authoritative persistent owner per document, await initialization and explicit flush, and wire recovery/errors. Native option/tag UI and catalogue/listing integration remain pending.

## Verification

Fresh F12 commands, counts, logs and ledger audit are recorded in
[VERIFICATION.md](../handoff/VERIFICATION.md). Historical K23/K29/K30/K34 counts were
preserved as dated evidence rather than relabelled as new runs. Concurrent F9–F11
changes require their owners' reports and a frozen-tree Mac review.

Final F12 verification: initial full suite **877/0 failures/0 skips**; subsequent
`run_all.sh` **889/0 failures/0 skips**, all six module builds and all checks pass.
Configured portable UI/App **53/0 failures/0 skips**; runner configuration **2 PASS**;
Python tooling **13 PASS**; static **222 files/0 errors**; UI parse **43/0 failures**.
Ledger **565 rows/0 gaps**, 411 planned / 88 drafted / 66 linux-tested; all 291
named evidence tests appear passed in the final run. Scoped diff checks pass.
No Mac SDK execution, host acceptance or Opus sign-off is claimed.
