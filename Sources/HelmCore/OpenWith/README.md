<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
K19 M20/F-062: ApplicationResolving supplies installed app choices and the default per item (including
folders). OpenWithModel intersects by standardized application URL, preserves first-item provider order,
deduplicates, promotes a shared eligible default, and exposes the first ten menu entries plus Other….
Different defaults yield no default marker; a missing resolver entry yields an empty intersection.
Lookup errors propagate rather than presenting an incorrect partial intersection. UI adapters must
cancel/stamp selection changes to reject late resolver results. InMemoryApplicationResolver performs no I/O.

AlwaysOpenWithRequest is intent only and includes every selected ID. It does not change Launch Services,
open files, send, share or mutate defaults. A future platform command must validate association scope
and obtain exact-action approval. Other… picker results need platform compatibility validation before
constructing a new model/request; unlisted applications are deliberately rejected by alwaysOpenWith.

Needed changes elsewhere: NSWorkspace resolver, picker, default setter, main-actor error presentation
(B-070) and successful-open Recent recording. No Share/Services external actions are implemented.
These adapters need Mac verification and Opus review after 22:00 Toronto, 2026-11-04.
