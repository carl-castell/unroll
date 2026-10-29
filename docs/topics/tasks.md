# Sync tasks

A sync task copies new photos and videos from one iPhone or iPad to one folder. You set it up once; after that, a run copies only what isn't in the folder yet.

## What a task remembers

- **Device**: recognized by its device ID, never by its name.
- **Destination**: a folder on a drive. The drive is recognized by its volume UUID (or a network share by its address), never by its name or where it's mounted.
- **Folder structure**: date folders inside the destination, by default `YYYY/YYYY-MM` (for example `2026/2026-06`). Tokens: `YYYY`, `MM`, `DD`.
- **Original vs. edited**: originals only (default), the edited version where one exists, or both plus the edit data (AAE).
- **Add to Apple Photos**: off by default. See `unroll help photos-referenced`.
- **Notification when done**: off by default.

## How new items are found

An item counts as already imported when its capture time, size and file name match an entry in the destination's index. File names alone repeat on iPhones (IMG_1234), so all three must match. The capture time is the photo's clock time, so changing the Mac's time zone doesn't make old photos look new. Files with identical content are stored once.

If the destination folder already has photos but no unroll index, for example copied earlier with Image Capture, unroll recognizes them the same way, by name, size and capture time, and doesn't copy them again. The first run records them in its index before copying.

## The first run

The first run of a task shows what will be copied and asks once. Later runs start right away. It asks again only if the task's device or destination changed, or if the destination's index is empty or was rebuilt. Without a terminal, such a run stops with exit code 5; pass `--yes` to confirm it.

## Where things are stored

- Photos and videos: the task's destination folder.
- Import index: `.unroll/` inside the destination folder, so files and index always stay together.
- Tasks and settings: `~/.config/unroll/` (or `$XDG_CONFIG_HOME/unroll`).
- Logs: `~/Library/Logs/unroll/`, one file per day, kept for 90 days.

## Managing tasks

In the menu, **More for "…"** holds preview, edit, delete, rebuild index and history for a task; **Other tasks…** switches to another task or creates a new one. On the command line: `unroll tasks list`, `unroll tasks add` and `unroll tasks remove`. Removing a task never touches the files or the index in its destination.
