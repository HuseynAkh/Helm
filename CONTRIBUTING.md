# Building, testing and contributing

Issues and pull requests are welcome. Before sending a change, run the tests, the static checks and the smoke run, and keep to Helm's rule: what happens to files follows macOS, and how Helm looks follows Nautilus.

## Build and test

Helm is a Swift package with an Xcode app target around it.

```bash
swift build
swift test
bash scripts/static_checks.sh
bash scripts/rebuild/host_smoke.sh
```

`swift test` runs the unit tests for every module, `static_checks.sh` checks project rules the compiler can't, and `host_smoke.sh` drives the real window through more than two thousand checks. AI mode's steps use a scripted model, so no test needs a key or a connection.

The smoke run works on a throwaway home folder it creates under `.build`, with a private pasteboard, a stand-in Trash and stand-ins for the onboarding's switches, so it never touches your files. The README's pictures come from a made-up home folder and the same scripted model: `bash scripts/readme/make_readme_images.sh` takes them again and redraws the banner.

| Module | What it does |
|---|---|
| `HelmCore` | Tabs, navigation, selection, sorting and commands, with no AppKit |
| `HelmFileSystem` | Reading folders and metadata, watching for changes, Recent |
| `HelmOperations` | Copy, move, rename, Trash and undo |
| `HelmSearch` | Name and Spotlight search, and running AI search's plans |
| `HelmPersistence` | Settings, sessions, view options, bookmarks and the sidebar's layout |
| `HelmAgent` | AI mode: the providers, the one network transport, the conversation, folder rules and plan checks. It can't change or open a file |
| `HelmUI` | Windows, the header, sidebar, grid, list, the AI panel, Read contents, settings, the onboarding and the default viewer switch |
| `HelmApp` | The app itself: launch, menus, access and the smoke driver |
| `HelmTestKit` | In-memory stand-ins that the tests share |
| `App/` | The Xcode app target, made with XcodeGen |

The original prototype is kept in `Helm/` for reference.

## The rule: Finder underneath, Nautilus on top

Helm started from GNOME Files, also called Nautilus, and that is still its DNA: one window, a path you can type, a flat sidebar and two views. Finder keeps the files honest.

**What happens to your files follows macOS. How Helm looks, and how you get around, follow Nautilus.** AI mode follows the same rule: every change it makes is an ordinary Finder-style operation.

| Finder underneath | Nautilus on top |
|---|---|
| Copies keep dates, extended attributes, permissions and clones | One window with tabs, and a path bar you can type into |
| The real Trash, with Put Back | A flat sidebar with Recent, Starred and your bookmarks |
| Quick Look, Open With, Services and Spotlight | Grid and list, with folders that open in place |
| Finder's drag and drop rules, spring-loaded folders included | A flat header bar that says what it's doing |

The whole rule is written down in [Finder underneath, Nautilus on top](docs/rebuild/03-finder-nautilus-balance.md).
