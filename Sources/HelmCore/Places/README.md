<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# Places integration

F-027/F-029: starred folders now participate in exact and deepest-ancestor
highlighting. Existing favorites, bookmarks, devices and Trash retain priority
when a starred folder duplicates an exact path. Component boundaries still
prevent sibling-prefix matches. Highlight follows the committed destination.

No public API changes or spec deviations. K13's regression is enabled; K17 adds
exact-priority and nested-star coverage. macOS integration and Opus review remain
pending. The manifest owner may exclude this README from source discovery.
