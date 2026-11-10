# F9 — P8 finding dispositions

DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04

Both findings are real and require the public-contract integration explicitly
excluded from this lane. No production contract or source is changed. The failing
XCTest probes below assert the desired safe behavior, rather than asserting the
bug as correct behavior. They are isolated from the production suite, retained
here for the integration owner, and run from `/tmp/F9-probes` against this local
package. They are not disabled production tests; no existing test is changed,
deleted, weakened or skipped.

| ID | Disposition | Files requiring integration | Test | Residual risk |
| --- | --- | --- | --- | --- |
| P8-1 | DEFERRED — public contract change | Operations Execute/OperationResult.swift, Execute/ForwardEvidence.swift, Execute/OperationExecutor.swift, Plan contracts and Undo/UndoPlanner.swift | `DeferredTests.testP8IdentityReplacementMustSurviveUndo` | Same-token/kind replacement is accepted by automatic leaf undo; native conditional mutations remain refused, but the fake and future supporting providers are exposed. |
| P8-2 | DEFERRED — public contract change outside ownership | Core Identity/FileMutationPrecondition.swift; FileSystem Fake/InMemoryFileSystem.swift; Operations Execute/OperationExecutor.swift | `DeferredTests.testP8PreAdmissionCancellationMustNotQuarantine` | Known clean cancellation at conditional admission permanently quarantines the executor. Ordinary uncertain cancellation must continue to quarantine. |

## Required integration

**P8-1:** Add optional recorded `FileMutationPrecondition` to successful
`ItemOutcome` and expected evidence to `OperationPlan`, with explicit public
initializer parameters/defaults. Both are public API changes even though their
files are within Operations. Reuse the existing Core-owned evidence type.
Capture output identity/kind/token together; carry them across the journal
boundary; seed inverse evidence exclusively from that record. Missing identity
must refuse undo, never adopt the current pathname occupant. Move/Trash must
remap evidence through temporary and backup paths. Preserve leaf-only tree
refusal. Add substitutions before inverse construction and before execution for
create/copy, moved leaves, Replace installed and backup leaves, plus absent
identity and multi-step remapping controls. The separate mutation-to-observation
window still requires an atomic completion receipt and is not solved by this
change. Blanket disabling leaf undo would change established behavior and break
valid-undo tests; it is not substituted for the prohibited contract work.

**P8-2:** Core's `ConditionalMutationError` currently has only `unsupported` and
`sourceChanged`. Add `cancelledBeforeMutation` (or an equivalently explicit
no-effects cancellation case) through the Core owner. Providers may emit it only
before any effects. Fake admission should emit that case instead of plain
`CancellationError`; executor maps it to `.cancelled`, no reconciliation and no
quarantine. Keep cancellation checks/read-only validation outside
`StepExecutionFailure`; wrap only actual mutation calls, preserving the actual
destination for uncertain failures. Preserve ordinary in-flight cancellation and
timeout quarantine, and successful started-work journaling. Do not reinterpret
all `CancellationError` values as clean or misuse `unsupported` to hide
cancellation. Add actor-hop/gated admission and read-only preflight regressions
alongside existing started-copy/timeout controls. The full finding remains
DEFERRED because the required typed guarantee is outside ownership and changes
its public contract.

## Reproduction source

The fixture copies only the old modification date to a separate fake node;
remove/recreate allocates a new UUID, then restoring that date yields exactly the
same token and kind. All mutations below operate on `InMemoryFileSystem`, not on
user files. The cancellation copier cancels its own task immediately before the
fake actor admission call, forwarding the original evidence unchanged.

```swift
// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import XCTest
import Foundation
import HelmCore
import HelmFileSystem
import HelmOperations

final class DeferredTests: XCTestCase {
    func testP8IdentityReplacementMustSurviveUndo() async throws {
        let fs = InMemoryFileSystem()
        let output = URL(fileURLWithPath: "/output")
        let saved = URL(fileURLWithPath: "/saved-metadata")
        let executor = OperationExecutor(fileSystem: fs)
        let result = await executor.execute(OperationPlan(command: .recovery, steps: [PlannedStep(kind: .createFile, destination: output, contents: Data([1]))]))
        XCTAssertNil(result.error)
        let before = try await fs.entry(at: output)
        try await fs.createFileExclusively(at: saved, contents: Data([1]))
        try await fs.applyDirectoryMetadata(from: output, to: saved)
        try await fs.removeItem(at: output)
        try await fs.createFileExclusively(at: output, contents: Data([2]))
        try await fs.applyDirectoryMetadata(from: saved, to: output)
        let replacement = try await fs.entry(at: output)
        XCTAssertEqual(before.changeToken, replacement.changeToken)
        XCTAssertNotEqual(before.objectIdentity, replacement.objectIdentity)
        let stored = await executor.journal.entry(result.id)
        let inverse = UndoPlanner.inverse(of: try XCTUnwrap(stored), recordedOrigins: [:])
        let undo = await executor.execute(inverse)
        let exists = await fs.exists(output)
        XCTAssertEqual(undo.succeededCount, 0, "P8-1: undo must refuse a different object")
        XCTAssertTrue(exists, "P8-1: replacement must survive")
    }
    func testP8PreAdmissionCancellationMustNotQuarantine() async throws {
        let fs = InMemoryFileSystem()
        let source = URL(fileURLWithPath: "/source"), output = URL(fileURLWithPath: "/output")
        try await fs.createFileExclusively(at: source, contents: Data([1]))
        let executor = OperationExecutor(fileSystem: fs, copier: CancelBeforeAdmission(fs: fs))
        let task = Task { await executor.execute(OperationPlan(command: .recovery, steps: [PlannedStep(kind: .copy, source: source, destination: output)])) }
        let result = await task.value
        XCTAssertEqual(result.error, .cancelled)
        let exists = await fs.exists(output)
        XCTAssertFalse(exists)
        XCTAssertFalse(try XCTUnwrap(result.outcomes.first).requiresReconciliation, "P8-2: admission performed no mutation")
        let next = await executor.execute(OperationPlan(command: .recovery, steps: [PlannedStep(kind: .createFile, destination: URL(fileURLWithPath: "/next"))]))
        XCTAssertNil(next.error, "P8-2: clean executor must remain usable")
    }
}
private struct CancelBeforeAdmission: FileCopier {
    let fs: InMemoryFileSystem
    func copy(from source: URL, to destination: URL) async throws { XCTFail("Unconditional mutation") }
    func copy(from source: URL, to destination: URL, requiring evidence: FileMutationPrecondition) async throws {
        withUnsafeCurrentTask { $0?.cancel() }
        _ = try await fs.mutate(.copy(to: destination), source: source, requiring: evidence)
    }
}

```

## Verification

- Linux Swift 6.0.3; Swift 5 language mode; sourced `/workspace/toolchains/env.sh`.
- `swift build --scratch-path /tmp/build-F9 --target HelmOperations`: PASS.
- Isolated red tests: `swift test --package-path /tmp/F9-probes --scratch-path /tmp/build-F9/probes --filter DeferredTests`: **2 tests, 4 expected assertion failures**, zero unexpected failures. Log `/tmp/F9-probes.log`. P8-1 failed refusal and replacement-survival assertions; token equality and identity inequality passed. P8-2 failed no-reconciliation and subsequent-operation assertions; cancellation mapping and zero output passed. These intentionally failing reproductions do not claim the bugs are fixed.
- Initial full suite hit concurrent F10's missing `MonitorSnapshotWorker`; waited 60 seconds and retried. No other lane's files were edited.
- Full portable suite retry: **889 tests, 0 failures, 0 skips**, `/tmp/F9-full-retry.log`. Command: `swift test --scratch-path /tmp/build-F9 --filter 'Helm(Core|FileSystem|Persistence|Operations|Search|TestKit)Tests'`.
- `HELM_K11_SCRATCH=/tmp/build-F9 bash scripts/rebuild/run_all.sh`: **PASS**, six portable builds, **889 tests / 0 failures / 0 skips**, Python checks, static checks, UI syntax parse and report-only coverage; **0 failed checks**. Summary `/tmp/F9-run-all.log`, detailed logs `/tmp/build-F9/logs/`.
- Standalone `bash scripts/static_checks.sh`: **222 Swift files, 0 errors**, `/tmp/F9-static.log`. Scoped `git diff --check` passes.
- Production verification is green; the two isolated safety regressions remain red and DEFERRED, as required by the public-contract restriction.

Recreate the isolated probe package with the source above under
`Tests/F9Probes/DeferredTests.swift` and this manifest (local dependency only):

```swift
// swift-tools-version: 5.9
// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import PackageDescription
let package = Package(name: "F9Probes", dependencies: [.package(path: "/workspace/forge/helm-build")], targets: [.testTarget(name: "F9Probes", dependencies: [.product(name: "HelmOperations", package: "helm-build"), .product(name: "HelmFileSystem", package: "helm-build"), .product(name: "HelmCore", package: "helm-build")])])
```

Only `docs/prereview/fixes-F9.md` is added to the worktree by F9. No network,
shared-memory fetch, external action, commit, push, manifest/script edit, or old
app edit occurred. macOS 14/Xcode compilation and Opus behavior review remain
outstanding. This report is a scope-constrained deferral, not a safety clearance.

