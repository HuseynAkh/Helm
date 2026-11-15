# K40 regression tests

XCTest value-only fixtures cover F-050 presentation, confirmation, owner lifetime,
B-009 stale callbacks, dirty drafts, and B-066 unknown/partial/overflow totals.
Run with the K40 scratch directory and filter
`InspectorSessionRegistryTests|InspectorSizeProjectionTests`.
No file services, window host, or native attribute writes are exercised.
