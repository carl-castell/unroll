# Sync tasks

A sync task copies new photos and videos from one iPhone or iPad to one folder. You set it up once; after that, a run copies only what isn't in the folder yet.

## What a task remembers

- **Device**: recognized by its device ID, never by its name.
- **Destination**: a folder on a drive. The drive is recognized by its volume UUID (or a network share by its address), never by its name or where it's mounted.
- **Folder structure**: date folders inside the destination, by default `YYYY/YYYY-MM` (for example `2026/2026-06`). Tokens: `YYYY`, `MM`, `DD`. Or no folders: all files directly in the destination folder (`--folder-template none`). When names repeat, as iPhone numbers do over the years, the later file gets ` (1)` added.
- **Separate Other folder**: off by default. When on, only photos and videos taken with this iPhone's camera go into the folder structure. Everything else goes into `Other/YYYY` (or one `Other` folder without a structure): screenshots, screen recordings, images saved from apps or the web, and photos from other phones or cameras. unroll recognizes this iPhone's photos by the camera model stored in each file, for example "iPhone 15 Pro". While setting up, it reads the models from a sample of the photos on the iPhone and lets you tick which are yours; tick earlier iPhones too if their photos are on this one. A Live Photo's video and edit data always stay with their photo. On the command line: `unroll tasks add … --camera-model "iPhone 15 Pro"`.
- **Original vs. edited**, for photos you edited on the iPhone (Live Photo videos always come with their photo):
  - *Originals only* (default).
  - *Originals plus their edit files (.AAE)*: the smallest way to keep edits. An AAE file stores the edits separately from the photo; most apps ignore it and show the original.
  - *Edited version instead of the original* where you edited a photo (`IMG_E1234.HEIC`); unedited photos as the original.
  - *Originals and edited versions*: both files, without AAE.
- **Add to Apple Photos**: off by default. See `unroll help photos-referenced`.
- **Notification when done**: off by default.

## How new items are found

An item counts as already imported when its capture time, size and file name match an entry in the destination's index. File names alone repeat on iPhones (IMG_1234), so all three must match. The capture time is the photo's clock time, so changing the Mac's time zone doesn't make old photos look new. Files with identical content are stored once.

If the destination folder already has photos but no unroll index, for example copied earlier with Image Capture, unroll recognizes them the same way, by name, size and capture time, and doesn't copy them again. The first run records them in its index before copying.

## The first run

After a run from the menu that finished without problems, or found nothing new, unroll quits. If something failed or you stopped the run, it returns to the menu.

The first run of a task shows what will be copied and asks once. Later runs start right away. It asks again only if the task's device or destination changed, or if the destination's index is empty or was rebuilt. Without a terminal, such a run stops with exit code 5; pass `--yes` to confirm it.

## Where things are stored

- Photos and videos: the task's destination folder.
- Import index: `.unroll/` inside the destination folder, so files and index always stay together.
- Tasks and settings: `~/.config/unroll/` (or `$XDG_CONFIG_HOME/unroll`).
- Logs: `~/Library/Logs/unroll/`, one file per day, kept for 90 days.

## Managing tasks

In the menu, **More for "…"** holds preview, edit, arrange existing files, delete, rebuild index and history for a task; **Other tasks…** switches to another task or creates a new one. On the command line: `unroll tasks list`, `unroll tasks add` and `unroll tasks remove`. Removing a task never touches the files or the index in its destination.
