<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# F3 thumbnail lifetime integration

Releasing the final ThumbnailCoordinator reference synchronously cancels every
producer task and finishes subscriber streams (F-048, B-055/B-056). Producers must
cooperate with task cancellation; subscribers must not retain the coordinator
through a host-created ownership cycle. Completed writes/renders cannot be undone.

K29 adds terminal, idempotent shutdown(): await it before owner teardown. It removes
all flights, cancels producers, finishes subscribers and clears cached images.
Later subscriptions finish immediately without a delivery; late producer callbacks
cannot repopulate the cache. Shutdown does not wait for uncooperative native work.
No thumbnail-owning HelmUI/App host exists yet; its eventual teardown must await
this API. The existing generator concurrency policy is unchanged. macOS generator
cancellation and Swift 5.9/Xcode compilation remain pending Opus review.
