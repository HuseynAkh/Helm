<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# K34 contract integration

BatchRenamePlanner retains both nonthrowing entry points. The overloads with
cancellationCheck throw the hook's error without publishing a partial plan.
Checks cover input generation, overlap preparation and sort boundaries, directory
occupancy, targets, changed items and temporary-name probes. The nonthrowing
compatibility path supplies an empty hook; validation errors remain plan issues.
UniqueNamer accepts a throwing occupancy callback so cancellation reaches its loop.

BatchRenameSheet uses a MainActor worker with one detached calculation and one
latest pending request. Replacement cancels active work, pending replacements
resume with cancellation, and disappearance/cancel retires both. The outer task's
cancellation handler forwards cancellation by request identity. Cancelled planning
never stores a partial evaluation. Native SwiftUI compilation needs macOS review.

Other K34 contracts and deviations are recorded under K34 in
`docs/handoff/CONTRACT_INTEGRATION.md`. Native conditional filesystem mutation
remains unavailable; the portable live provider refuses rather than substituting
stat-then-mutate. No product decision about enabling unsafe mutation is implied.
