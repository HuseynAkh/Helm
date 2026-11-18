# Installing Helm

Helm is an early preview for macOS 14 Sonoma or later, on Apple silicon or Intel. It's developed and tested on macOS 26 Tahoe.

1. **Download** `Helm-<version>.dmg` from the [latest release](https://github.com/HuseynAkh/Helm/releases/latest). A `.zip` of the same app is there too.
2. **Verify it**, if you like. Download `SHA256SUMS.txt` from the same release, then in Terminal:

   ```bash
   cd ~/Downloads
   shasum -a 256 -c SHA256SUMS.txt --ignore-missing
   gh attestation verify Helm-<version>.dmg --repo HuseynAkh/Helm
   ```

   The first command checks the file matches the release: it prints `OK` after the file's name. The second checks that GitHub Actions built it from this repository. It needs the [GitHub CLI](https://cli.github.com), signed in with `gh auth login`. [RELEASING.md](RELEASING.md#verify-a-release) explains both.
3. **Drag Helm to Applications.** Open the disk image and drag Helm onto the Applications folder beside it, then eject the disk image.
4. **Open it the first time.** Helm isn't notarized yet, so macOS stops it once. On macOS 15 and later, click **Done**, open **System Settings › Privacy & Security**, scroll to **Security**, click **Open Anyway** next to the note about Helm, and confirm with your password. On macOS 14, Control-click Helm in Applications, choose **Open**, then **Open** again. [Why it isn't notarized](RELEASING.md#why-helm-isnt-notarized-yet).
5. **Set it up.** Helm opens one window that goes step by step, with Back and Continue: **Welcome**, **Full Disk Access**, **Default File Viewer**, **AI Mode** and **You're All Set**. A step that's already done is left out; AI Mode always shows, with how it stands. Opened from the disk image, the welcome offers to move Helm to Applications first. Full Disk Access opens System Settings only when you click its button. Once it's on, macOS asks to quit and reopen Helm, and the step's **Restart Helm** does the same; either way setup carries on at the next step. Default File Viewer makes Helm open in place of Finder and puts it next to Finder in the Dock, if you leave its box ticked.
6. **Turn on AI mode**, if you want it, at the AI Mode step: switch it on, pick a provider, then click **Continue with ChatGPT** for OpenAI, paste your key, or start Ollama or LM Studio. **Continue** keeps it on; **Not Now**, or closing the window before you answer, leaves it off. Set up before, it shows as it is, and **Continue** goes on. Click **Get Started** at the end and your files open, with nothing else popping up. **Help › Set Up Helm…** goes through the steps again.

Helm is signed ad hoc, so macOS treats each new version as a new app. After an update, open it as in step 4 again, and turn Full Disk Access back on: remove Helm from the list with − and add it back with +.

## Build from source

You need Xcode 27, which runs on macOS 26.6 or later, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
git clone https://github.com/HuseynAkh/Helm.git
cd Helm
bash scripts/release/make_release.sh
```

The disk image, zip and checksums land in `dist/`. Install from the disk image as above; a copy you build yourself isn't quarantined, so macOS doesn't stop it. To try Helm without building the app, `swift run HelmDev` starts it straight from the package. The Services, the default file viewer and the Dock settings need the built app.

## Make Helm your file viewer

The onboarding's **Default File Viewer** step does this, and puts Helm next to Finder in the Dock. To undo it, click **Restore Finder** in Settings › General › Default File Viewer and turn off **Show next to Finder in the Dock**; **Make Default** and that Dock switch do it again. From Terminal:

```bash
/Applications/Helm.app/Contents/MacOS/Helm --default-viewer helm
/Applications/Helm.app/Contents/MacOS/Helm --dock-first on
/Applications/Helm.app/Contents/MacOS/Helm --viewer-status
```

`--default-viewer finder` and `--dock-first off` undo the first two, and `--viewer-status` says where each stands.

After that, "Show in Finder" and "Reveal in Finder" in other apps open Helm with the file selected. Some things stay with Finder whatever you choose:

- The desktop and the Dock's Finder icon.
- Folders opened from Spotlight, Dock stacks or `open`: macOS 26 doesn't let apps take over folders.
- Apps that ask Finder by name, and apps that were already open when you switched.

The details are in [DEFAULT_FILE_MANAGER.md](handoff/DEFAULT_FILE_MANAGER.md).

## Full Disk Access

Helm is a file manager, so it works best when it can see your whole Mac. Without Full Disk Access, macOS keeps the Trash, Mail, Safari and other apps' data out of reach, and asks before Helm opens Desktop, Documents and Downloads. Your music, TV and photo libraries and cloud drives have switches of their own, even with Full Disk Access.

1. Click **Open System Settings** at the onboarding's Full Disk Access step, or open **Help › Full Disk Access…**.
2. Click **+** and choose Helm, or drag Helm's icon from the window into the list.
3. Turn Helm on, then choose **Quit & Reopen** when macOS offers it, or click **Restart Helm** at the onboarding's step. Helm reopens where setup left off.

Full Disk Access isn't part of Files and Folders: it has its own entry in Privacy & Security.
