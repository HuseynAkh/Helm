<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# Helm rebuild status

The rebuild lives at the repository root in `Package.swift`, `Sources/`, `Tests/`
and `scripts/`. It is a draft pending Opus compile-correctness and behavior review
after 22:00 Toronto on 2026-11-04. The existing app under `Helm/` is the unchanged
behavior reference. The legacy description below is not a rebuild capability claim.

The root package enables six portable libraries and XCTest targets. UI/App source
exists, but Mac targets, native host and executable remain unconfigured. Live
executor copy/move/Trash currently refuse conditional mutations; exclusive creation
remains available. In-memory operation tests do not establish live feature parity.

First read the [Opus/Fable review queue](docs/handoff/REVIEW_QUEUE.md), including P1–P19, R1 and fixes-F1–F21.

Wave 21 baseline: **1,159 portable tests**, verified in the K41 execution log. See [verification](docs/handoff/VERIFICATION.md)
for exact fresh counts and [Mac handoff](docs/handoff/MAC_HANDOFF.md) for implemented
components, deferred work and SDK priorities. The 565-row ledger records citations,
not feature acceptance. No Mac runtime acceptance or release is claimed.

From the repository root, use explicit portable targets and a private scratch path:

```sh
source /workspace/toolchains/env.sh  # Linux workspace toolchain
swift build --scratch-path /tmp/build-HELM-REVIEW --target HelmCore
swift test --scratch-path /tmp/build-HELM-REVIEW --filter 'Helm(Core|FileSystem|Persistence|Operations|Search|TestKit)Tests'
HELM_K11_SCRATCH=/tmp/build-HELM-REVIEW bash scripts/rebuild/run_all.sh
HELM_UI_SCRATCH=/tmp/build-HELM-REVIEW python3 -B Tests/HelmUITests/PortableRunner/run.py
```

The supplemental runner is Linux-only portable UI/App logic; it does not type-check
SwiftUI/AppKit. Use the staged Mac instructions in the handoff for SDK validation.
No publishing, sending, sharing changes, paid renders, commits or pushes are part
of this handoff.

---

## Legacy app README (historical)

# Helm — A Nautilus-Inspired File Manager for macOS

Helm brings the clean, focused file management experience of [GNOME Files](https://apps.gnome.org/Nautilus/) (Nautilus) to macOS. Built natively with AppKit and SwiftUI, it aims to be a fast, keyboard-driven alternative to Finder — without the clutter.

## Features

- **Dual-pane layout** — Sidebar with Places and Folder Tree views alongside a spacious content area
- **Grid and List views** — Switch between icon grid and detailed list with expandable folders
- **Tabbed browsing** — Open multiple directories in tabs within a single window
- **Breadcrumb navigation** — Click path segments to jump up the hierarchy, or type a path directly
- **Spotlight-powered search** — Fast file search with intelligent ranking that prioritizes your most-used directories
- **File thumbnails** — Actual image, PDF, and video previews instead of generic icons
- **Keyboard-first design** — Full keyboard shortcut coverage for navigation, file operations, and view controls
- **Starred files** — Bookmark your most important files and folders for quick access
- **Quick Look integration** — Preview files without leaving the app
- **Batch rename** — Rename multiple files at once with pattern-based rules

## Requirements

- macOS 14.0 (Sonoma) or later
- Apple Silicon or Intel Mac
- Swift 5.9+ / Xcode Command Line Tools

## Getting Started

### Build

```bash
cd Helm
swift build
```

### Run

```bash
swift run Helm
```

### Generate Xcode Project (optional)

If you have [XcodeGen](https://github.com/yonaskolb/XcodeGen) installed:

```bash
cd Helm
xcodegen generate
open Helm.xcodeproj
```

## Keyboard Shortcuts

| Action            | Shortcut            |
| ----------------- | ------------------- |
| New Window        | `Cmd + N`         |
| New Tab           | `Cmd + T`         |
| Close Tab         | `Cmd + W`         |
| New Folder        | `Cmd + Shift + N` |
| Find              | `Cmd + F`         |
| Go to Folder      | `Cmd + L`         |
| Back              | `Cmd + [`         |
| Forward           | `Cmd + ]`         |
| Enclosing Folder  | `Cmd + Up`        |
| Home              | `Cmd + Shift + H` |
| Grid View         | `Cmd + 1`         |
| List View         | `Cmd + 2`         |
| Show Hidden Files | `Cmd + .`         |
| Rename            | `Return`          |
| Move to Trash     | `Cmd + Delete`    |
| Quick Look        | `Space`           |
| Properties        | `Cmd + I`         |
| Refresh           | `Cmd + R`         |
| Toggle Sidebar    | `Ctrl + Cmd + S`  |
| Toggle Star       | `Cmd + D`         |

## Project Structure

```
Helm/
├── Helm/
│   ├── App/                  # Entry point, AppDelegate, Info.plist
│   ├── Controllers/          # View controllers (Content, Sidebar, Tabs)
│   ├── Models/               # Data models (FileItem, Tab, Place)
│   ├── Services/             # System services (FileSystem, Monitor, Search, Thumbnails)
│   ├── Utilities/            # Settings, extensions, helpers
│   ├── ViewModels/           # Observable view models (Directory, Search, Sidebar)
│   ├── Views/
│   │   ├── AppKit/           # Native AppKit views (Grid, List, Breadcrumb, TabBar)
│   │   └── SwiftUI/          # SwiftUI views (Sidebar, Preferences, Properties)
│   ├── Windows/              # Window and split view controllers
│   └── Resources/            # Asset catalogs
├── HelmTests/                # Unit tests
├── HelmUITests/              # UI tests
└── Package.swift             # Swift Package Manager manifest
```

## Inspiration

Helm is inspired by [GNOME Files](https://apps.gnome.org/Nautilus/) (historically known as Nautilus), the default file manager for the GNOME desktop environment on Linux. Nautilus has long been appreciated for its clean, opinionated approach to file management — favoring simplicity and spatial awareness over overwhelming feature density. Helm attempts to translate that philosophy to macOS, using native frameworks to feel right at home on Apple hardware.

## Built With

- **Swift** — AppKit for window management, collection/table views, and toolbar; SwiftUI for sidebar, preferences, and dialogs
- **Swift Package Manager** — Build system and dependency management
- **QuickLook Thumbnailing** — Native thumbnail generation for file previews
- **Spotlight (NSMetadataQuery)** — Fast indexed file search

---

<p align="center">
  Engineered with <a href="https://claude.ai/code">Claude Code</a> (Opus 4.6) and <a href="https://chatgpt.com">Codex</a> (5.3)
</p>
