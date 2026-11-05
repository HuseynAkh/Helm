# Owner options — no assignment or implementation authorization

DRAFT: pending review, 2026-11-05

OWNER ASSIGNMENT PENDING (see OWNER_OPTIONS.md)

These are options for Huseyn, not instructions to any lane. All host, manifest and contract work remains blocked until the exact ownership and policy are approved. The reviewed revision will be `<HEAD at handoff>`; the orchestrator fills it after review.

## Path ownership (OK2-2)

**A (recommended):** assign one Mac integration owner `Package.swift`, `Sources/HelmUI`, `Sources/HelmApp`, `Tests/HelmUITests` and `Tests/HelmAppTests` for staged compilation after other lanes finish. This keeps target membership and compiler fixes together. **B:** assign the manifest to an integrator and each source/test pair to separate named owners; this permits parallel work but requires explicit handoffs and no overlapping edits. **C:** retain the present unassigned status; portable inventory can run, but native target activation stays blocked. AK3's limited SIMPLE-fix permission is not the Mac ownership assignment.

## Native launch lane (OK2-1)

**A (recommended):** assign a dedicated host lane after contract decisions: entry point/AppDelegate, environment-to-window wiring, one WindowStore/DirectoryEffectRunner per window, split/sidebar/list, then menus/responders and remaining widgets. This produces the first launchable folder view with reviewable steps. **B:** have the Mac integration owner build the host after compile triage, reducing handoffs but lengthening that lane. **C:** defer host work and retain a library-only prototype; every M10–M25 hosted gate remains NOT RUN. No option authorizes touching legacy Helm/.

## Host name and location (OK2-4)

**A (recommended, architecture §§3.4–3.5):** use package executable `HelmDev` at `Sources/Helm`, app spec `App/project.yml`, generated project `App/Helm.xcodeproj`, app entry `App/main.swift`, and Xcode app target `Helm`. The optional development entry must match the app entry. This avoids a package/app module collision. Proposed patch, ONLY after assignment and source creation:

```swift
products += [.executable(name: "HelmDev", targets: ["HelmDev"])]
targets += [.executableTarget(name: "HelmDev", dependencies: ["HelmApp"], path: "Sources/Helm")]
```

Proposed validation: `swift build --scratch-path /tmp/build-MAC-HANDOFF --target HelmDev`, `xcodegen generate --spec App/project.yml`, then `xcodebuild -list -project App/Helm.xcodeproj`. `scripts/static_checks.py` derives the module key from the source directory (`Sources/Helm` → `Helm`); its existing `Helm: {HelmApp}` DAG mapping therefore still fits this proposed explicit path. No static-check or manifest change is made by AK3.

**B:** use the documented root-project fallback only if the assigned owner demonstrates that A fails; retain `HelmDev` and explicitly revise project paths/checks together. **C:** postpone both executable and project; native compilation may proceed through Stages 1–2 but launch acceptance cannot.

## Journal composition (OK2-6)

**A (recommended):** settle O1's ticket/event/journal contract, then assign one app-lifetime coordinator with per-window histories and active-window menu routing; this prevents cross-window undo. **B:** inject distinct journals per window behind an agreed composition interface, accepting extra lifecycle coordination. **C:** retain the current shared journal only as a disclosed prototype limitation and block multi-window undo acceptance. AK3 changes none of these contracts.

## WindowDependencies and store protocols (OK2-8)

**A (recommended):** assign HelmPersistence protocol ownership and agree a protocol-based WindowDependencies contract before host wiring; this supports memory fakes without downcasts but needs cross-module review. **B:** adopt concrete persistence stores and explicitly redesign test injection, reducing abstraction at the cost of fake flexibility. **C:** defer composition and keep the incompatible signatures documented; no native host can claim integration. Missing services must be inventoried with the chosen owner, not improvised in HelmUI.

## Store load failures (OK2-9)

**A (recommended):** agree non-throwing store construction followed by explicit load, returning per-document failures and read-only failed stores while browsing remains available; this requires persistence API changes and visible recovery UI. **B:** retain fail-fast startup with an explicit recovery screen and documented loss of browsing until repair. **C:** defer the policy and retain the existing throwing composition as a known launch blocker. Migration failure remains a separate decision; no option authorizes overwriting an unsupported document.

## External opens (OK2-10)

**A (recommended):** follow the architecture after launch: folders navigate the key window and files launch through the external-open service, while cold requests create the first window; change routing contracts and tests together after approval. **B:** approve the current new-window/reveal behavior as a deliberate product difference and revise architecture/acceptance. **C:** postpone the decision and preserve current tests without claiming F-002 parity. Any real external launch still requires Huseyn's exact-action authorization.

## Additional blocked dependencies

OK2-7 needs a HelmPersistence owner for `StoreLocation` URLs before AK3 can compose and flush seven documents. OK2-35's retained Core-type rename likewise requires explicit ownership outside AK3; the broadened guard intentionally stays red for those names. OK2-18/32/37 are tagged JUDGEMENT without a separately tagged SIMPLE portion, so their behavior/runner changes remain deferred; the handoff requires native discovery and diagnostics rather than asserting unobserved results.
