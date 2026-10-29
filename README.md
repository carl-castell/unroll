# unroll

**Copy only the new photos from your iPhone to an external drive, and keep Apple Photos small by referencing them instead of storing them.**

Internal Mac storage is expensive, and a full photo library can easily take hundreds of gigabytes. If you don't use iCloud Photos, or don't want your library to live in the cloud, getting photos off your iPhone regularly is surprisingly awkward:

- **Apple Photos copies everything into its library** when you import from an iPhone, even if "Copy items to the Photos library" is turned off. Referenced files only work for photos that are already in a folder.
- **Image Capture** can save to any folder, but it doesn't know what you've already imported. Every time, you have to find the new photos by hand or risk duplicates.
- **iCloud Photos** solves syncing, but it means paying for cloud storage, keeping your library in the cloud, and it doesn't work with referenced files at all.

`unroll` fills that gap. It reads your iPhone directly, remembers what it has already copied, and transfers **only new photos and videos** to a folder on your external SSD, organized by date. Optionally, it adds them to Apple Photos as **referenced files**, so Photos stays a small, fast index while the originals live on your drive.

### Why not just move the whole Photos library to the SSD?

It's the usual advice, and it works until it doesn't:

- **Your photos end up inside an opaque package.** A `.photoslibrary` is a single bundle with Apple's internal folder structure and database. You can't simply browse it, point another app at it, or copy a month of photos out of it in Finder. With `unroll`, your originals are plain files in readable folders like `2026/2026-10/`.
- **Ejecting the drive becomes a fight.** Photos runs background tasks such as analysis, face recognition and library maintenance, even when the app looks closed. These keep files on the drive open, so macOS often refuses to eject it, and force-ejecting a drive with an open library risks damaging it.
- **The drive has to be connected whenever Photos runs.** If it isn't, Photos complains or quietly opens a different, empty library, which is easy to mistake for lost photos.
- **One file, one point of failure.** If the library's database gets corrupted, everything in it is affected at once. Individual files on a drive fail individually, if at all, and an index can be rebuilt from them.
- **You're tied to one app.** A library package only really works with Apple Photos. Plain folders work with Finder, Lightroom, digiKam, a NAS, another Mac, or whatever you use in ten years.
- **Backups are clumsier.** Backing up a huge library package is all or nothing, and restoring part of it isn't practical. A folder of files backs up incrementally with any tool.

Keeping a small library on your Mac that only *references* the files on your SSD gives you the Photos experience for browsing, while your originals stay flexible, stable and under your control.

---

## Install

### Homebrew

```sh
brew install <github-user>/tap/unroll
```

Homebrew builds `unroll` from source on your Mac, so there's no unsigned binary to unblock. Updates come through `brew upgrade`. The man page and shell completions (zsh, bash, fish) are installed automatically.

### Build from source (for development)

Requires Xcode or the Xcode Command Line Tools.

```sh
git clone https://github.com/<github-user>/unroll.git
cd unroll
swift build -c release
cp .build/release/unroll /usr/local/bin/
```

### Requirements

- macOS (Apple silicon or Intel)
- An iPhone or iPad connected by cable
- An external drive formatted as APFS or Mac OS Extended (Journaled)

---

## Quick start

1. **Connect your iPhone and your external SSD.** Unlock the iPhone and tap "Trust This Computer" if asked.
2. **Run `unroll`.** On first launch, a short setup wizard asks for a name for your sync task, which iPhone to use, and the destination folder on your SSD.
3. **Confirm the first sync.** The first run of a task shows what will be copied (number of items, total size, destination) and asks once. Every run after that starts immediately.

From then on, just connect your iPhone and SSD, type `unroll`, and press Enter.

---

## Usage

### Interactive menu

Running `unroll` in a terminal opens a menu you navigate with the arrow keys. Your most recently used sync task is preselected, so **Enter runs it**:

```
 unroll
 SSD "Photos-SSD" ✓   iPhone "My iPhone" ✓

 What do you want to do?
 ❯ ▶ Run "iPhone → SSD"        (last run 3 days ago)
     Preview "iPhone → SSD"    (dry run)
     Run "Old iPad → Archive"
     ─────────────
     New sync task
     Edit / delete task
     Status & history
     Rebuild index
     Help
     Settings
     Quit
```

During a sync you see each step with a status indicator (checking the SSD, connecting to the iPhone, reading the item list, comparing), followed by a progress bar for the transfer and a summary at the end.

### Sync tasks

A **sync task** is a named configuration you set up once:

| Setting | Example |
|---|---|
| Name | `iPhone → SSD` |
| Device | your iPhone, recognized by its device ID |
| Destination | a folder on a specific SSD, recognized by its volume UUID |
| Folder structure | `YYYY/YYYY-MM` |
| Original vs. edited | keep originals (default) |
| Add to Apple Photos | off (default) |

You can have several tasks, for example one per device.

### Dry run

Choose **Preview** in the menu, or run:

```sh
unroll run "iPhone → SSD" --dry-run
```

You'll see how many new items would be copied, their total size, and a breakdown by month. In the interactive menu you can then choose **Run now**, which copies exactly what the preview showed without scanning the iPhone again.

### Direct and non-interactive use

Everything in the menu is also available as a command, which makes `unroll` usable from scripts and Apple Shortcuts:

```sh
unroll run "iPhone → SSD"            # run a task
unroll run "iPhone → SSD" --dry-run  # preview only
unroll run "iPhone → SSD" --yes      # skip the first-run confirmation
unroll run "iPhone → SSD" --json     # machine-readable output
unroll status                        # devices, tasks, last runs
unroll rebuild-index                 # rebuild the index from files on the SSD
unroll help <topic>                  # detailed help
```

When it isn't running in an interactive terminal, `unroll` never shows menus or prompts. If a confirmation would be needed, it stops with a clear message instead of waiting.

**Exit codes**

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Finished, but some items failed |
| 2 | Destination SSD not connected |
| 3 | iPhone not connected, locked, or not trusted |
| 4 | Task not found or invalid configuration |

---

## Setting up your iPhone

For complete, unconverted originals:

- **Settings → Photos → Transfer to Mac or PC → Keep Originals.** Otherwise the iPhone may convert photos to JPEG during transfer.
- **Turn off "Optimize iPhone Storage"** if you use iCloud Photos on the phone. With it on, many full-resolution originals aren't stored on the iPhone and can't be transferred by cable.
- Keep the iPhone **unlocked** while a sync runs.

---

## Using it with Apple Photos (referenced library)

`unroll` can keep Apple Photos as a lightweight index of photos that live on your SSD:

1. In Photos, go to **Settings → General** and **uncheck "Copy items to the Photos library"**.
2. Enable **"Add to Apple Photos"** in your sync task.
3. After each sync, `unroll` imports the new files into Photos as referenced files.

Things to know about referenced files in Apple Photos:

- Thumbnails stay visible when the SSD is disconnected. Opening, editing or exporting a full original needs the SSD connected.
- **Don't move or rename folders on the SSD** after import, or Photos loses the link.
- Referenced files are **not included in Photos backups** and **don't sync with iCloud Photos**. Back up the SSD itself.
- To see which photos are stored inside the library, create a Smart Album with the condition *Photo is not Referenced*.

---

## How it works

### Sync flow

1. **Check:** the destination SSD is mounted (matched by volume UUID, never by name) and the iPhone is connected, unlocked and trusted. If anything is missing, nothing is written.
2. **List:** read all items on the iPhone with filename, capture date and size, without downloading anything.
3. **Compare:** look each item up in the task's index. An item counts as already imported if its capture date, size and original filename match.
4. **Copy:** download only the new items into the date-based folder structure. Live Photos (HEIC + MOV) stay together. Existing files are never overwritten.
5. **Verify and record:** compute a SHA-256 hash, confirm the file is complete, and only then record it in the index. Interrupted transfers are never marked as imported.
6. **Optional:** add the new files to Apple Photos as referenced files and show a notification.

### Where data lives

| What | Where | Why |
|---|---|---|
| Photos and videos | Your chosen folder on the SSD | The whole point |
| Import index (SQLite) | `.unroll/` in the destination folder on the SSD | Index and files always stay together. Restoring or moving the SSD keeps them consistent |
| Sync tasks and settings | `~/.config/unroll/` | Small, machine-specific configuration |
| Logs | `~/Library/Logs/unroll/` | Standard macOS location |

If the index is ever lost, `unroll rebuild-index` reconstructs it from the files on the SSD.

### Architecture

The code is split into three layers. The core logic never prints anything itself. It reports progress as a stream of events, and each interface decides how to display them.

```
┌──────────────────┬───────────────────┬──────────────────┐
│ Interactive menu │  Direct commands  │  Help and docs   │   Interface
│ (Noora)          │  (ArgumentParser) │  (--help, man)   │
└────────┬─────────┴─────────┬─────────┴────────┬─────────┘
         └───────────────────┼──────────────────┘
                             ▼
┌─────────────────────────────────────────────────────────┐
│ Core: tasks, comparison, sync plan, copy, events        │   Core
└────────┬───────────────────┬──────────────────┬─────────┘
         ▼                   ▼                  ▼
┌──────────────────┬───────────────────┬──────────────────┐
│ ImageCaptureCore │  SSD + SQLite     │  Task config     │   Adapters
│ (iPhone access)  │  (files, index)   │  (~/.config)     │
└──────────────────┴───────────────────┴──────────────────┘
```

- **Interface layer:** the interactive menu, built with [Noora](https://github.com/tuist/Noora) for arrow-key menus, progress steps, progress bars and alerts; direct commands, built with [swift-argument-parser](https://github.com/apple/swift-argument-parser); and help, man page and shell completions. Without arguments in a terminal, `unroll` opens the menu; with a command, or outside a terminal, it runs non-interactively.
- **Core layer:** manages sync tasks, builds a *sync plan* (the list of new items plus totals), executes it and emits events such as *check passed*, *items listed*, *file progress* and *sync finished*. Rules like "the first run of a task needs confirmation" live here. The core only signals that confirmation is required; the interface decides how to ask.
- **Adapter layer:** talks to the outside world. Apple's ImageCaptureCore framework for the iPhone, the file system and SQLite index on the SSD, and the task configuration in your home folder.

This separation means one sync engine serves the menu, scripts and Shortcuts, and the core can be tested without a terminal or an iPhone.

### Project structure

```
unroll/
├── Package.swift
├── Sources/
│   ├── unroll/          # executable: entry point, menus, commands, rendering
│   ├── UnrollCore/      # tasks, sync plan, comparison, events
│   ├── UnrollDevice/    # ImageCaptureCore adapter
│   └── UnrollStore/     # SQLite index, file writing, config
├── Tests/
├── docs/                   # help topics, man page source
└── README.md
```

---

## Development

```sh
git clone https://github.com/<github-user>/unroll.git
cd unroll
swift build
swift test
swift run unroll
```

- Open `Package.swift` in Xcode, or use VS Code with the Swift extension.
- Tests for the core run without a connected device. Device tests are opt-in.
- Releases are tagged as `vX.Y.Z`. A GitHub Action builds the release binary and updates the Homebrew formula.

---

## Help and documentation

- `unroll --help` and `unroll <command> --help`
- `unroll help <topic>`: `setup`, `tasks`, `photos-referenced`, `troubleshooting`, `exit-codes`
- `man unroll`
- **Help** in the interactive menu

---

## FAQ

**Does it delete anything from my iPhone?**
No. `unroll` only reads from the iPhone.

**Can I use it without Apple Photos?**
Yes. Adding to Photos is optional. By default you just get a clean, date-organized folder of originals.

**What if I plug in a different SSD?**
Each task is bound to a specific drive by its volume UUID. A different drive won't be written to unless you change the task.

**macOS asks for permission on first run.**
macOS may ask whether your terminal app is allowed to access the iPhone, or, with the Photos option, to control Photos. Allow it once.

**Some photos are missing.**
Most likely "Optimize iPhone Storage" is on, so the originals aren't on the phone. See [Setting up your iPhone](#setting-up-your-iphone) and `unroll help troubleshooting`.

---

## License

`unroll` is released under the [MIT License](LICENSE).

It depends only on permissively licensed components, all compatible with MIT and with Homebrew's licensing requirements:

| Dependency | Used for | License |
|---|---|---|
| [Noora](https://github.com/tuist/Noora) | Interactive menus, progress, alerts | MIT |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | Commands, `--help`, shell completions | Apache 2.0 |
| SQLite (system library) | Import index | Public domain |
| ImageCaptureCore (macOS framework) | iPhone access | Part of macOS, linked, not redistributed |

Third-party license texts are listed in [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
