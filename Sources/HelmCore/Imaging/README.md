<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# F3 thumbnail lifetime integration

Releasing the final ThumbnailCoordinator reference synchronously cancels every
producer task and finishes subscriber streams (F-048, B-055/B-056). Producers must
cooperate with task cancellation; subscribers must not retain the coordinator
through a host-created ownership cycle. Completed writes/renders cannot be undone.

No public API was added. A deterministic public shutdown operation and its awaited
host call are deferred because F3 may not change public contracts or HelmUI/App.
Until then, owners should cancel retained request tokens before releasing the actor.
The existing generator concurrency policy is unchanged. macOS generator cancellation
and Swift 5.9/Xcode compilation remain pending Opus review.
