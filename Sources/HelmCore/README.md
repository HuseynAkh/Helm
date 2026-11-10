<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# K23 shared contract integration

AddressEditorState/Action are the sole editor contracts. SearchScope, SearchClause,
SearchRequest, SearchSpecification and SearchRankedBatch now belong to HelmCore;
import HelmCore when consuming them. SearchEvent.results carries the full batch,
including truncation. Legacy userFolders/computer/trash scope cases remain supported;
home/thisMac/recents retain their symbolic saved-search encoding.

FileEntry.cloudAvailability defaults to unknown at the end of its initializer.
Old Codable payloads lacking that field decode to unknown. Cloud inspection remains
metadata-only and optional: a cloud-key failure cannot hide an otherwise readable entry.

SnapshotStamp's load-action bridge preserves request generation. The tab reducer alone
allocates accepted presentation IDs, after rejecting stale loads. Filesystem capability
queries default conservatively for existing conformers; explicit planning inputs win.
Only collision errors that guarantee no mutation permit executor retries.

Open questions/deviations: column/gallery and Starred Location remain deferred. macOS
resource keys and UI/App targets require Xcode and Opus review. Full inventory, deferred
integration requests and verification: docs/handoff/CONTRACT_INTEGRATION.md.

## K29 deferred pre-review contracts

BatchRenameIssue.overlappingSources blocks all standardized ancestor/descendant
selections under the supplied case semantics, with previews retained (F-055/B-047).
ColumnNavigation.load now carries ColumnLoadRequest: retain the entire value and
return it to push(_:request:). A request is single-use and bound to its column UUID;
new navigation, ancestor reload, pop and truncation invalidate earlier requests.
There is deliberately no path-only acceptance overload (B-009).

FileDropSession owns cached source validation for one drag. Keep it across destination
and modifier updates; call replaceSources on payload/metadata changes and end on
termination. End releases the paths and refuses later proposals. DropPlanner's
stateless API remains available; neither API caches live filesystem permission.

Await ThumbnailCoordinator.shutdown() on owner teardown. Shutdown is terminal and
idempotent, cancels flights, finishes streams, clears cache, and returns empty
streams for future subscriptions. Late cooperative or uncooperative producer
completions cannot publish. The existing host has no thumbnail coordinator or
native file-drag owner yet; those adapters must adopt these APIs when implemented.

UndoVerificationPolicy.leafOnly records the conservative P2-3 deviation: root
metadata never authorizes directory/package undo, even if unchanged. Operations
records the post-mutation kind, validates kinds and tokens again immediately before
inverses, and remaps them through internal moves. Complete no-follow descendant
content/identity manifests and atomic native compare-and-mutate remain open;
verificationUnavailable must be surfaced for reconciliation, without automatic retry.
All new contracts remain drafts for Opus and macOS/Xcode verification.

## Waves 12–18 components

[Store](Store/README.md) supplies the FIFO WindowStore and selection binder, with
owned cancellation and shared monitor reply ordering. [Inspector](Inspector/README.md)
supplies pure attribute/permission edit plans; [Accessibility](Accessibility/README.md)
supplies formatting, row speech, identifiers and throttled operation announcements.
[Naming](Naming/README.md) documents cooperative batch-rename cancellation.
These components require native hosts; their existence does not close UI parity.

Core owns FileObjectIdentity, FileMutationPrecondition and ConditionalMutationError,
including cancelledBeforeMutation's zero-effects guarantee. Operations records undo
ownership evidence and refuses missing identity or tree undo. FileSystem conditional
support is provider-dependent; native live executor copy/move/Trash still refuse.
Persistence's K33 tag catalogue/location-options stores are distinct from Core's
in-memory values. See the module READMEs and docs/prereview/fixes-F15.md for current
integration limits and verification of the 1001-test portable suite.
