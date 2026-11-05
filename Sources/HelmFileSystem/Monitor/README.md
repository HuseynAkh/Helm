<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# Monitor integration through wave 18

FallbackMonitor selects FSEvents when available on macOS, then vnode observation,
then portable polling (F-008, B-014/B-015/B-073). It coalesces forwarded events;
when its selected source ends it stops and finishes its own stream, allowing
DirectoryEffectRunner to observe termination and attempt bounded recovery.
Stop is terminal: replacement uses a fresh monitor, not a restarted finished stream.

Darwin DispatchSourceMonitor emits rootChanged for rename/delete/revoke and
rescan for other watched flags; callback identity rejects retired sources.
FSEvents uses WatchRoot and emits rootChanged for root invalidation. A root event
requests revalidation, not a guessed new path. Successful validation through
WindowStore rebinds a fresh watch generation. Startup acknowledgement requests
reconciliation, including after inactivity; polling's baseline alone cannot
recover changes made while unwatched.

[Loading](../Loading/README.md) describes cancellation ownership, shared reload/
validation request ordering, three-attempt recovery and surfaced degradation.
F14MonitorRecoveryTests exercises injected startup failure, exhaustion, finite
streams and store recovery. MonitorAndCacheTests covers polling/coalescing and fallback start/stop.
These portable tests do not execute native FSEvents/vnode branches. macOS 14/Xcode
compilation, real root replacement/unmount behavior and host error presentation
remain pending Opus/native acceptance.
