# K1 draft handoff

Draft pending Opus compile/behaviour review after 22:00 America/Toronto on 2026-11-04.
No commit, push, network access or external action was performed.

The root manifest builds six portable libraries and six XCTest targets. The macOS
UI/App/executable/test declarations remain a commented template for the UI lane.
Other production targets currently contain only their requested module markers.

Shared types follow review fixes 1, 4, 5, 7, 8, 9, 16, 39, 47 and 55. The architecture
was revised during implementation; the concrete SearchScope/SearchResult,
CompletionRequest, SidebarMode, LoadOptions and synchronous HelmClock were aligned.
Recent preserves 180 displayed entries and 300 stored records; decoding accepts
legacy records without kind. Kind sorting uses the supplied localized description.
Natural collation depends on platform ICU; deterministic raw-path tie breaking and
strict descending comparisons fix B-035. Relevance ranks are ascending ordinals.

Integration still required, without editing another lane's owned directories:
- ReducerContext cannot be declared with its specified settings member until the
  Settings lane supplies SettingsSnapshot. That context belongs with the Tab lane.
- AddressBarState/AddressBarAction are the requested minimal values, currently using
  FileEntry rows. The AddressBar lane should align them to CompletionRow and its full
  action vocabulary when that type exists. K1 kept those contracts under Contracts/.
- FakeClock uses an NSLock around every access and @unchecked Sendable to offer the
  synchronous Swift 5.9 clock contract; review this localized synchronization seam.

Static checking is lexical, not a Swift parser. It strips comments/literals, checks
imports/conditional branches, top-level duplicate names across modules, explicit
public struct initializers, forbidden APIs, and balanced delimiters. Its focused
Python tests exercise rejected and accepted inputs. Swift compilation is authoritative.
The old Helm/ app remains untouched. macOS/Xcode compilation is unverified.
