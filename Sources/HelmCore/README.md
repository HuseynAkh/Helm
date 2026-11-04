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
