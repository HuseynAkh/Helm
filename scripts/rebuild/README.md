<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# K11 Linux tooling

Run `bash scripts/rebuild/run_all.sh` from any directory. It activates the installed
toolchain, builds the six portable targets explicitly, runs all six XCTest targets,
runs rebuild and static-check Python unit tests, K1 static checks, SDK-name guards,
UI syntax checks and coverage report-only.
Logs and Swift artifacts remain in `/tmp/build-K11`; override with
`HELM_K11_SCRATCH`. Override external plan paths with `HELM_PLAN_DIR`, then `PLAN_DIR` as fallback.
A missing plan directory fails explicitly before builds.
The script returns nonzero on any failed command or zero discovered XCTest cases.
The full SDK-name guard currently fails for four retained Core names pending an
owner-approved rename. It scans all six portable libraries plus UI/App, and checks
unqualified retained names in every SwiftUI-importing HelmUI file. New collisions
are failures too; no blanket warning exception hides them.
It does not install dependencies, access the network, commit or modify the ledger.
Inspect test effects before running against a changed checkout; existing suites use
fakes and temporary fixtures. No real user-data tests are authorized by this script.

Coverage commands (plan paths are external inputs; a snapshot for the Mac run is in docs/rebuild, see its README):

```sh
python3 scripts/rebuild/check_coverage.py \
  --parity /workspace/forge/helm-plan/docs/rebuild/02-finder-parity.md \
  --current-state /workspace/forge/helm-plan/docs/rebuild/00-current-state.md
```

Add `--generate --build-plan PATH` to deliberately replace the initial ledger;
add `--test-log /tmp/build-K11/logs/tests.log` only for a complete passing run from
the same checkout. Generation is explicit so later human acceptance notes are not
silently overwritten. The CSV header must remain exactly the specified seven columns;
the draft label lives in this README and each generated row's notes.

Definitions come from the first Markdown table cell, not arbitrary cross-references.
Appendix B maps every F and P0/P1 acceptance owner; P2 and bugs without a mapping
remain planned with no invented milestone. Module means final acceptance owner,
not necessarily the module containing a precursor implementation. P2 module hints
come from the parity catalogue. Unknown/blank IDs, duplicate rows, missing rows,
invalid states, priority mismatches, missing P0/P1 owners and empty test evidence
fail strict checking. `--report-only` tolerates those gaps, but unreadable/malformed
inputs still fail. Summary counts include planned work: they are not percentages
of completed Finder parity.

Citation scanning is lexical: Swift comments and test identifiers, including
same-prefix numeric ranges and `test_F_001` names. A passing test *file* may cite
several features; `linux-tested` requires passing cases for each XCTest class in the file
in a complete successful run; classes with skipped cases are excluded. It does not assert every cited acceptance case was
exercised. Test names and source/test paths are retained for reviewer inspection.
A test citation without run evidence remains drafted. A log is evidence supplied by
the caller, not cryptographic proof of current sources; regenerate after changes.
No automatic `mac-only`/`deferred` claim is inferred from a filename or missing code.

`bash scripts/rebuild/parse_check_ui.sh [ROOT]` parses each Swift file in HelmUI,
HelmApp and Helm using `swiftc -parse`. Zero existing files is explicitly NOT RUN,
not UI success. Parsing cannot validate SDK symbols, imports, actor isolation,
linking or runtime behavior. K1's lexical static checker remains authoritative for
its own checks; parser-based project/selector validation from M0 remains open.

Run tooling fixtures with `python3 -m unittest discover -s scripts/rebuild -p
 'test_*.py' -v` (one line). Python uses only the standard library.

Needed changes elsewhere: manifest owner should exclude module README.md files;
UI/App owners must use the staged patches in the handoff, not uncomment the old template.
See `docs/handoff/MAC_HANDOFF.md` for the aggregated contract gaps. No portable
Swift implementation or legacy app was changed. Opus and Mac validation remain open.
