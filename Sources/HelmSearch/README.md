<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# HelmSearch integration (K26)

All changes are drafts pending Opus compile/behaviour review after 22:00 Toronto,
2026-11-04. The module performs metadata reads only: no content reads, writes,
network requests, predicate execution or platform UI imports.

`SearchEngine` accepts a FileSystem, SearchScopeResolving and HelmClock. The supplied
SearchRootResolver maps Home/current folder/Trash explicitly, requires allowed roots
for computer scopes, and rejects Recents enumeration. Roots and directory entries
are standardized and sorted before visit budgets apply. Each directory is collected
before sorting; memory therefore includes one complete directory listing as well as
at most visitLimit candidates. A future bounded listing adapter may be useful for
extremely wide directories. The visit limit bounds examined entries, not underlying
filesystem listing IO. Duplicate roots/entries cannot consume the budget twice.

Traversal never follows symlink entries, including explicit symlink roots. Packages
are listed as results but not descended by default; SearchWalkOptions can explicitly
permit their contents. Hidden directories are pruned unless requested. Permission
failures skip that folder, issue SearchDiagnostic.unreadable and mark results partial;
other failures throw from collect. No scope is expanded after failure.

`search` returns AsyncStream<SearchRankedBatch>. It waits for global ranking, then
emits cumulative prefixes of the final result in requested batch sizes. The last
snapshot is complete when the stream finishes; these are replacement snapshots,
not append-only batches. Empty successful searches emit one empty snapshot. This
avoids enumeration-timing-dependent intermediate ranks. Plain AsyncStream cannot
carry failures, so consumers MUST supply diagnostics and distinguish failed/cancelled
from an empty successful search. Consumers needing throwing semantics use collect.
Consumer cancellation cancels its own worker; cancellation checks surround every
filesystem suspension and visit. FileSystem implementations must cooperate with
cancellation and cancel their stream producers on termination. Blocking kernel IO
cannot be forcibly interrupted by this portable module. Separate searches have no
shared cancellation state (B-021).

`MetadataSearchSource` is a finite value snapshot seam for a future NSMetadataQuery
adapter, with an injectable fake. The adapter must extract value records, release
its query on cancellation, and enforce package policy. CompositeSearchSource also
rechecks filename/kind/date/size/tag/hidden filters and root boundaries, merges with
explicitly justified enumeration, then ranks once. Metadata wins duplicate paths.
Fallback disclosure identifies unavailable, known-unindexed or user-requested
fallback. Empty indexed results alone never trigger enumeration (B-099). Tags and
Recents remain metadata-only; requested fallback reports unsupportedCriteria and
partial results rather than broadening them. Metadata errors propagate; adapters
must explicitly report availability when fallback is appropriate.

F-045 ranking retains exact +1200, prefix +800, substring/word-boundary +500,
token +100, preferred +380 and depth bonus, Home +220, bookmark +300, active +200,
directory +80, document +140, hidden -280, system -650, recency +90/+55/+25,
current-folder +40. Name folding now uses case/diacritic-insensitive POSIX rules,
aligning Unicode matching and ranking. Paths retain their existing ranking policy.
The candidate cap is max(limit*3,450), newest-first before scoring. An older exact
match can remain outside the cap (B-026); truncation remains visible. Tie breaks use
newer metadata, numeric POSIX name collation, then standardized path. The original
EnumerationSearchService API and its throwing-permission behavior are preserved.

Grammar is bounded at 4096 UTF-8 bytes, 128 tokens, 256 total clauses; 10k-character
queries reject explicitly. Double quotes and backslashes group/escape literal text.
Clauses are ANDed; OR/NOT, contents:, wildcard and predicate punctuation are literal
filename text, never executable operators or content searches. Known kind names are
case-insensitive; dates are strict UTC days; size comparisons are exclusive and
nonnegative. Injected filter rows receive validation too.

SearchCriteriaEditor edits typed AND rows while preserving document text, name,
scope and hidden policy, and uses SavedSearchDocument schema-v1 codecs. Finder
imports in the editor are always read-only: RawQuery is opaque and exact original
plist bytes re-export unchanged. The older low-level Finder codec's supported-subset
replacement API remains for compatibility; the editor never calls it. Unknown Finder
keys retain the codec's read-only reasons. No subprocess or predicate interpreter is
used. Editing query text/scope/name can be done by constructing a new editor from an
updated SavedSearchDocument; row append/replace/remove reject stale indices safely.

Needed changes elsewhere / open questions: no Core changes are required for this
portable slice. Host integration should retain batch truncation and diagnostics,
map fallback disclosure to visible UI, and supply allowed roots. Core SearchService
uses a different event stream; its composition adapter belongs to the host lane.
Actual NSMetadataQuery lifecycle, live updates and Finder interoperability require
macOS/Opus review (M16/M23). Consider an explicit completion/error event in Core for
consumers that need richer lifecycle than the requested plain batch AsyncStream.

F3 pre-review fixes: typed and textual extension literals share final normalization
and validation. Both JSON and constructed/replaced Finder documents reject encoded
output over 1 MiB, matching decode limits. Original fallback traversal inspects every
pending directory and refuses package/symlink roots while preserving throwing I/O
errors. This does not eliminate filesystem TOCTOU changes between inspection and
listing; descriptor-relative traversal would require a different filesystem contract.
