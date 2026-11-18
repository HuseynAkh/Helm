# F5 integration notes

IOExecutor preserves bounded, per-volume blocking work for B-107. Its executor lock
serializes request registration, queued-to-running admission, and timeout quarantine.
A timeout that shuts a lane rejects every registered request on it that has not started;
a read that shuts only its folder rejects only what waits to read there, and every
change (see "A stalled read shuts its folder, not its lane" below). Already-running
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
A lane shut only by a timed-out read, or with a read stalled in one folder, is left alone
and doesn't make the answer false: a read changes nothing, and waiting for it would hold up
every other lane. The stall clears by itself when the read returns. Until then a change on
that lane still fails as timed out, so a caller that keeps a stall flag of its own can see
one more timed-out failure there after a true.

`CanonicalPath` is the one place that asks for an item's real path. `realPath` answers nil
when any part of the path is missing.

## A stalled read shuts its folder, not its lane

Without Full Disk Access, a read can wait on a macOS privacy question that nobody has
answered, and the watchdog times it out after 30 s. `runRead` and `runReadWithProgress`
take an optional `path`, the folder listed or the item read, which `LiveFileSystem` passes
for every read it makes (`readPath`, spelled by `PathSpelling.standardPath`). When a read
with a path times out, only that path is shut: a later read of it or inside it, folder by
folder and without regard to case as the Mac's disk compares names, fails at once as timed
out, and reads queued for it are turned away. Every other read on the lane carries on.

The whole lane still shuts, as before, when the disk itself looks stuck: reads stalled in
two places at once, neither inside the other (stalls inside one another count as one
place); a stalled read that named no path; or stalled reads holding every one of the
lane's workers, which would otherwise leave queued reads waiting with no time limit. A
stall clears when its timed-out read returns, and a lane shut by reads opens once the last
of them is back.

Changes keep the conservative rule. A timed-out change shuts every lane it touches until
`clearQuarantine` or `reopenAll` reconciles it. A change can't say where it lands, so
while any read on its lane is stalled it is refused as timed out, as it was when that read
shut the whole lane. Callers that pass no path, such as the volume, storage and agent disk
readers with executors of their own, behave exactly as before.

`PrivacyAreas.askingRoots` still get lanes of their own: a read waiting there holds one of
that lane's workers rather than one of the disk's, and two such folders waiting at once
can't shut the disk's lane between them.
