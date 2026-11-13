<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# F5 integration notes

IOExecutor preserves bounded, per-volume blocking work for B-107. Its executor lock
serializes request registration, queued-to-running admission, and timeout quarantine.
A timeout rejects every registered request that has not started. Already-running
requests retain their actual result unless their own deadline expires. Cancellation
before continuation installation is retained; cancellation after begin cannot erase
a successful primitive. Lock order is executor then result state; cancellation takes
only the result-state lock. Continuations resume after releasing the result-state lock.

A timed-out native call can still finish. The caller must reconcile uncertain mutations;
quarantine lasts for this executor's lifetime. Native macOS execution and Opus review
remain open. No attempt is made to interrupt a kernel call or recreate a hung queue.
The internal result state is test-visible for deterministic cancellation-before-install
coverage; public API is unchanged.

Related F5 changes: composite tag writes check cancellation before primary/fallback
entry, but preserve a successful write; the existing all-origin Put Back validation
now runs its T1 regression without an environment gate. Planner and journal internal
work diagnostics exercise production paths without elapsed-time assertions.

Portable UI tests require an explicitly built scratch directory:
`HELM_UI_SCRATCH=/tmp/build-F5 python3 -B Tests/HelmUITests/PortableRunner/run.py`.
The runner validates dependency modules/objects and uses the same root for compile,
link, runtime lookup, and subprocess typechecking. No manifest or script changes.

Deviations and verification details are recorded in `docs/prereview/fixes-F5.md`.

## F7 multi-volume admission

Native copy, move, replacement, metadata transfer and alias creation register all
source/destination/backup volumes with one IOExecutor admission lock. Worker queue
selection stays independent of the safety footprint. Timeout quarantines every
registered volume; admission checks every volume before registration and again
before body entry. Unrelated volumes remain available. The existing single-volume
public run API remains source-compatible; the multi-volume overload is internal.
Symbolic-link creation only writes its link directory and does not access its target.

Share this LiveFileSystem/IOExecutor across windows. Quarantine remains per executor,
not a process-global mount registry; do not recreate it to bypass reconciliation.
Native macOS cross-volume completion and alias writes still require acceptance.

K34: entry metadata now includes optional no-follow device/inode identity.
mutationPrecondition returns identity/kind/change evidence; inode reuse means this
observation is not an authorization token. LiveFileSystem deliberately inherits
FileSystem's unsupported conditional-mutation default: portable POSIX supplies no
atomic compare-source-identity + exclusive destination mutation. Native direct
primitive APIs remain available for explicit callers, but OperationExecutor now
refuses copy/move/Trash through this provider with verificationUnavailable. A
reviewed native provider is needed to enable these operations safely. Do not
implement the conditional API as a metadata read followed by a pathname mutation.

## Downloads off, and reopening after a stall

`DatalessGuard.off { }` marks a task. Every body that task hands to IOExecutor then runs
with the macOS thread setting that refuses to fetch a file, or load a folder's names, kept
in a cloud. The mark is read on the caller's task before the body is queued, because the
queue's thread can't see it, and the thread's own setting is put back when the body
returns. A read that would have needed a download fails with
`FileSystemError.notDownloaded` (EDEADLK) and nothing is fetched. A task started inside the
mark carries it, so a listing does too; a detached task doesn't. Tests show the setting on
a queue thread and that it is put back. None can hold a file that is in a cloud only, so
the refusal itself is still to be seen on a Mac with a cloud folder.

A listing or a size stream (`enumerate`, `sizeOfTree`) must be made inside `off`. Its reads
run on a task that starts when the stream is made, not when it is read, so the stream
carries the mark of the task that made it. One made before `off` and read inside it runs
with downloads on; one made inside keeps them off wherever it is read.

`IOExecutor.reopenAll()` reopens every lane a timed-out mutation shut, and
`LiveFileSystem.reopenAfterStall()` calls it. Such a lane stays shut while a timed-out call
on it is still out, and the answer is then false. Call it only once the person has
acknowledged the stalled change: that is the reconciliation `clearQuarantine` asks for.

True means every lane a stalled change shut is open again. It doesn't mean nothing is out.
A lane shut only by a timed-out read is left alone and doesn't make the answer false: a
read changes nothing, and waiting for it would hold up every other lane. That lane reopens
by itself when the read returns. Until then a change on it still fails as timed out, so a
caller that keeps a stall flag of its own can see one more timed-out failure there after a
true.

`CanonicalPath` is the one place that asks for an item's real path. `realPath` answers nil
when any part of the path is missing.
