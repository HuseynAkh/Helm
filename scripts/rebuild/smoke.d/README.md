# Extra smoke steps

`host_smoke.sh` adds these to its run, so separate pieces of work can each keep their own steps:

- `*.txt` — steps that run before the first run's final `quit`, in file-name order.
- `*.restore.txt` — steps that run after the relaunch.
- `*.fixture.sh` — run before the steps with `$fix` (the fixture root) and `$root` set, to add fixture files.
- `*.cleanup.sh` — run after both runs, with the same variables, to undo anything a fixture script changed.

Steps use the same verbs and placeholders (`@FIX@`, `@SHOTS@`) as `host_smoke_steps.txt`. Verbs of their own go in `Sources/HelmApp/macOS/HostSmokeDriver+<Area>.swift`.
No file here has a `quit` step: the first run's only `quit` is the last line of `host_smoke_steps.txt`, and the run
stops if any other step quits. Each run must also get to its last step, so a launch that stops early fails.

To try a few steps on their own, `HELM_SMOKE_ONLY=my-steps.txt bash scripts/rebuild/host_smoke.sh` runs only those
steps from a fresh launch against the same fixture home, then quits. `HELM_SMOKE_ONLY_RESTORE=more.txt` adds a
relaunch run with its own steps.

Every run blocks the network. `host_smoke.sh` starts HelmDev under `sandbox-exec` with `scripts/rebuild/deny-network.sb`,
which kills it on any try at a connection, a host name lookup or a background download. The run then fails with
exit 137. So a passing run also shows that Helm's own process stayed off the network. Work that other processes do
for Helm, such as Quick Look previews and thumbnails, is outside the block. `HELM_SMOKE_NETWORK=allow` runs without
the block, for example to tell a network kill from another crash. Without `sandbox-exec`, the run prints a warning and
goes on without it. If `sandbox-exec` can't apply the profile, the run stops.

`HELM_SMOKE_BIN=/path/to/Helm.app/Contents/MacOS/Helm` runs the steps against that build instead of building HelmDev,
for example a Release build made by Xcode. AppKit can behave differently by the SDK a build links against: swift build
links HelmDev as SDK 14, and Xcode links Helm.app against the newest SDK.
