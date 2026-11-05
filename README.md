# Helm rebuild status

The rebuild lives at the repository root in `Package.swift`, `Sources/`, `Tests/`
and `scripts/`. It is a draft: nothing has compiled on macOS. The existing app under `Helm/` is the unchanged
behavior reference. The legacy description below is not a rebuild capability claim.

The root package enables six portable libraries and XCTest targets. UI/App source
exists, but Mac targets, native host and executable remain unconfigured. Live
executor copy/move/Trash currently refuse conditional mutations; exclusive creation
remains available. In-memory operation tests do not establish live feature parity.

On a Mac, start at [the Mac handoff](docs/handoff/MAC_HANDOFF.md); the prompt is [MAC_CLAUDE_PROMPT.md](docs/handoff/MAC_CLAUDE_PROMPT.md).

Code pin `1c4f3fe` on `forge/rebuild-build`; the docs commit follows it. At the pin, on Linux: **1,318 XCTest, 0 failures, 0 skips**. `scripts/rebuild/run_all.sh` exits 1 only for four retained Core type names. Source: [fixes-OP2](docs/review-opus/fixes-OP2.md). The 565-row ledger records citations, not feature acceptance. No Mac runtime acceptance or release is claimed.

On the Linux workspace, from the repository root, use explicit portable targets and a private scratch path:

```sh
source /workspace/toolchains/env.sh  # Linux workspace toolchain
swift build --scratch-path /tmp/build-HELM-REVIEW --target HelmCore
swift test --scratch-path /tmp/build-HELM-REVIEW --filter 'Helm(Core|FileSystem|Persistence|Operations|Search|TestKit)Tests'
HELM_K11_SCRATCH=/tmp/build-HELM-REVIEW bash scripts/rebuild/run_all.sh
HELM_UI_SCRATCH=/tmp/build-HELM-REVIEW python3 -B Tests/HelmUITests/PortableRunner/run.py
```

The supplemental runner is Linux-only portable UI/App logic; it does not type-check
SwiftUI/AppKit. Use the staged Mac instructions in the handoff for SDK validation.
No publishing, sending, sharing changes, paid renders or pushes are part of this handoff. The Mac run commits only locally on `handoff/mac-fixups`.

---

## Legacy app README (historical)

Its commands build the legacy package under `Helm/`, not the rebuild.

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
