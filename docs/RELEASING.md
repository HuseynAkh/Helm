# Releasing Helm

Helm ships as a disk image on [GitHub Releases](https://github.com/HuseynAkh/Helm/releases). This page covers how a maintainer makes a release, how anyone can check one, and why Helm isn't notarized yet.

## What a release holds

| File | What it is |
|---|---|
| `Helm-<version>.dmg` | A compressed, read-only disk image with Helm.app and a link to Applications, so installing is one drag |
| `Helm-<version>.zip` | The same app in a zip, made with `ditto` and without extended attributes, so any unzip tool leaves the app's signature intact |
| `SHA256SUMS.txt` | The SHA-256 of both, in the format `shasum -a 256 -c` reads |
| Release notes | What's new, the requirements, how to install, the first launch, updating, how to verify with the app's CDHash, and privacy |

When GitHub Actions builds a release, the disk image and the zip also get a **build provenance attestation**: a signed record, kept by GitHub, of the repository, commit and workflow run that built each file.

[`scripts/release/make_release.sh`](../scripts/release/make_release.sh) makes all of it, on a Mac or on GitHub Actions. It needs Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen), and nothing else: no network, no signing identity and no installs. It runs the source privacy check, regenerates the Xcode project, and builds Release in a scratch folder. It checks the app's signature, that it's built for both Apple silicon and Intel, and that it passes [`scripts/release/check_binary_privacy.sh`](../scripts/release/check_binary_privacy.sh). Then it makes the disk image and the zip, checks both, and writes everything to `dist/`, which git ignores.

It builds the folder as it is. On a Mac, uncommitted changes go into the build, and the script and the notes say so. On GitHub Actions, a checkout with changes stops the build, because the attestation names the commit.

## Make a release

1. **Set the version.** In `App/Info.plist`, set `CFBundleShortVersionString` to the new version, such as `0.2`, and raise `CFBundleVersion` by one.
2. **Write what's new** in `docs/releases/<version>.md`, such as `docs/releases/0.2.md`. Plain Markdown with no heading. It becomes the "What's new" part of the notes.
3. **Try it on your Mac.** This is optional:
   ```bash
   bash scripts/release/make_release.sh
   ```
   Open the disk image in `dist/` and check it.
4. **Commit and push.** Then tag the commit and push the tag:
   ```bash
   git tag -a v0.2 -m "Helm 0.2"
   git push origin v0.2
   ```
5. **Wait for the Release workflow.** It runs the static and privacy checks and the tests, builds and checks the app, attests the disk image and the zip, and makes a **draft** release called "Helm 0.2". Nothing is public yet.
6. **Check the draft** under Releases: the disk image, the zip and `SHA256SUMS.txt` are attached, and the notes read well. Download the disk image, verify it as below, and open Helm.
7. **Publish the draft.** Only then can people see it.

If something is wrong, delete the draft and the tag, fix the problem, and tag again:

```bash
git push origin :refs/tags/v0.2
git tag -d v0.2
```

The tag has to match the app: `v0.2` needs `0.2` in `App/Info.plist`, or the workflow stops in its first step, before the tests. A suffix after a `-` is allowed, so `v0.2-beta.1` also builds from `0.2`, and its draft is marked as a pre-release. A `+` isn't, because GitHub renames release files that have one.

**Without a tag.** Actions › Release › Run workflow builds the branch you choose. Leave the version empty to use the one in `App/Info.plist`. It makes the same draft, and publishing it creates the tag `v<version>` at that commit. If that tag already exists at another commit, the run stops in its first step.

The workflow is [`.github/workflows/release.yml`](../.github/workflows/release.yml). It runs only for pushed `v*` tags and when started by hand, never for ordinary pushes or pull requests, so it uses Actions minutes only when you ask. It runs on GitHub's `xcode-27` runner with Xcode 27.0, the version Helm is developed with. That matters beyond compiling: the macOS SDK an app is built with decides how AppKit draws it. If GitHub drops Xcode 27.0 from the image, the Select Xcode step stops and lists the Xcodes it has; set `XCODE_APP` in the workflow to one of them. Each action it uses is pinned to a full commit SHA. XcodeGen comes from Homebrew and isn't pinned; the log shows its version.

## Verify a release

Download the disk image (or the zip) and `SHA256SUMS.txt` into one folder. Then, in Terminal:

```bash
cd ~/Downloads
shasum -a 256 -c SHA256SUMS.txt --ignore-missing
```

Each file you downloaded should be followed by `OK`. That shows the files are the ones listed on the release page, with nothing damaged or changed.

To check that GitHub Actions built a file from this repository, use the [GitHub CLI](https://cli.github.com). It only works signed in (`gh auth login`), but any GitHub account will do:

```bash
gh attestation verify Helm-0.2.dmg --repo HuseynAkh/Helm
```

It prints the repository, commit and workflow that built the file. To accept only this repository's release workflow, add `--signer-workflow HuseynAkh/Helm/.github/workflows/release.yml`.

Everything that goes into a release can be read: the workflow, the build script, and the run's log, which is linked at the bottom of the release notes.

After installing, this checks that the app's files still match the signature inside it:

```bash
codesign --verify --deep --strict --verbose=2 /Applications/Helm.app
```

Anyone can make an ad hoc signature, so this catches damage, not tampering. To tie your copy to the release, the release notes give a line that also checks the code directory hashes (CDHashes) the build recorded, one for each kind of Mac:

```bash
codesign --verify --deep --strict --verbose=1 -R='cdhash H"<Apple silicon hash>" or cdhash H"<Intel hash>"' /Applications/Helm.app
```

It should end with `explicit requirement satisfied`. Only `--verify` checks the files: the hash that `codesign -d` prints is read from the signature, which a changed copy can carry along. The checksums and the attestation show where the download came from.

## Why Helm isn't notarized yet

macOS fully trusts an app from outside the App Store when it is signed with a **Developer ID** and **notarized**: Apple checks the app and issues a ticket that Gatekeeper looks for. A Developer ID needs a paid Apple Developer Program membership. Whether to pay for one is the maintainer's call, so for now Helm is signed ad hoc.

For people who download Helm, that means two things:

- **macOS stops Helm the first time it opens.** On macOS 15 and later, the way past is System Settings › Privacy & Security › Open Anyway. On macOS 14, it's Control-click › Open.
- **Each new version is a new app to macOS.** Full Disk Access, and the answers to the folder questions, have to be given again after an update. For Full Disk Access, remove Helm from the list with − and add it back with +.

With a Developer ID, `make_release.sh` would sign with it instead of `-`, send the disk image to Apple with `xcrun notarytool submit --wait`, and attach the ticket with `xcrun stapler staple`. Both problems above would go away.
