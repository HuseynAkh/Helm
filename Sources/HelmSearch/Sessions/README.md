<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# Search session bridge

K39 / P15 N2. SearchSessionDriver consumes an injected event closure or existing
SearchService. It compiles the current AND grammar before opening a stream; invalid
criteria and syntactically empty clauses never become broad searches. Cancellation
invalidates request identity first and cancels the consuming task. Producers must
cooperate with stream termination to stop native work; shutdown does not promise
an uncooperative producer has stopped. The task captures the driver weakly.

Read `await driver.state` for snapshots; automatic host publication and TabAction
integration remain serial follow-up. Existing SearchService lacks availability and
fallback metadata beyond notIndexed, so its adapter does not invent those facts.
Inject envelope events for explicit disclosure. No native query adapter is added.

SavedSearchOpenPlan decodes injected bytes only. Editable Helm definitions retain
scope/filters; Finder RawQuery stays opaque even when its codec considers it editable.
Malformed/future/empty definitions have no search request. Definition URL is retained
separately; definitionRemovalIntent is a URL-only draft for an independently approved
host action and cannot include search result URLs. No files are read, deleted, sent,
or shared. UI editor/open routing, approval and persistence remain host obligations.

All changes need Opus compile/behaviour review after 22:00 Toronto and macOS 14/Xcode
verification. Existing TabSearch, State, Presentation, manifest and scripts are untouched.
