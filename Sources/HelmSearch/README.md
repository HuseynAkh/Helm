<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# HelmSearch integration

Draft pending Opus compile-correctness and behaviour review after 22:00 Toronto,
2026-11-04. Linux-only validation does not establish macOS adapter correctness.

The module performs no writes, network requests, content reads, or predicate execution.
SearchRequest wraps the immutable specification input; HelmCore continues to own
SearchQuery and SearchResult. SearchDomain preserves currentFolder/home/thisMac/recents
symbolically. Core currently calls these userFolders/computer and has no recents case
or advanced filters. Needed changes elsewhere: extend Core query/scope and SearchEvent
with filters and visible truncation before wiring this through the shared SearchService.
EnumerationSearchService deliberately returns SearchRankedBatch directly to retain that
information. The caller supplies query rankingText, matching scope, limit, Home, bookmarks,
active directory, and cached preferred roots in SearchRankingContext.

F-045 weights follow old Helm/Helm/Services/SpotlightSearchService.swift:317–385:
exact +1200 (318), prefix +800 (320), substring +500 (322), tokens +100,
preferred +380 and depth max(0,150-depth*30) (337), Home +220, bookmark +300,
active directory +200, directory +80, document +140, hidden -280, system -650 (369),
recency +90/+55/+25, current-folder +40. The brief's exact +500 conflicts with
source and audit F-045; source wins. Word-boundary classification is distinct but
shares substring's frozen score. Document UTType conformance is supplied by adapters;
the portable extension fallback matches legacy lines 412–421. Preferred-root discovery
is injected (custom visible Home folders), never performed by ranking or on the main thread.

Candidate cap preserves max(limit*3,450) at legacy 197, newest-first/natural-name
preorder at 52–55, and final limit at 220. Older exact matches can remain outside the
cap (B-026); candidateLimitReached and truncated expose it. Equal score ties use newer
metadata, numeric POSIX name collation, then standardized path. POSIX collation removes
ambient-locale variability; it may differ from legacy localizedStandardCompare.
Missing dates should be mapped to distantPast by the adapter. Package metadata is
represented by FileEntry.kind; fallback never descends packages or symlinks.

Grammar: whitespace-separated AND clauses, double-quoted phrases, backslash escapes;
kind: uses FileEntryKind names plus folder; ext: is an exact extension; before:/after:
use strict UTC YYYY-MM-DD (exclusive/inclusive); modified: selects that UTC day;
size:<N and size:>N use nonnegative bytes; tag: is an exact tag placeholder.
Unknown prefixes and wildcard/predicate punctuation stay literal filename text.
There is no OR, regex or arbitrary predicate grammar. Limits are 4096 UTF-8 bytes,
128 text tokens and 256 total clauses. Spotlight must use bound literal comparisons,
never interpolate these values into predicate source or use LIKE for filename clauses.

Fallback policy does not infer indexing state from empty results. ThisMac requires
explicit allowed roots; Home/current folder derive only their stated root. Recents
requires an injected metadata source and is explicitly unsupported by the walker;
tags require metadata absent in K5 and report unsupported. Errors/cancellation throw,
not a misleading empty result. Depth and visited-entry bounds report truncation;
no permission-denied scope is silently expanded. The walker caps visited metadata,
then applies the same ranker. Caller controls deliberate fallback presentation (M16).

Helm JSON is schema v1 and validates grammar on load/save. Finder interchange supports
RawQuery plus SearchCriteria.FXScopeArrayOfPaths only. RawQuery is opaque storage, never
translated or executed. Unknown top-level/nested keys or symbolic Finder scopes make
imports read-only with reasons. Original plist bytes are retained, so unknown values
round-trip exactly; edits are refused. Full Finder editor-state fidelity and raw-query
translation are outside this slice. Codec functions return Data; no file is written.
Finder fixtures and Spotlight lifecycle still require macOS review (M16/M23).
