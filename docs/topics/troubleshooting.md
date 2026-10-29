# Troubleshooting

## The iPhone isn't found, or is "locked or doesn't trust this Mac"

- Use a cable that carries data, unlock the iPhone, and tap **Trust This Computer** when asked.
- If it never asks: Settings → General → Transfer or Reset iPhone → Reset → Reset Location & Privacy, then connect again.
- `unroll scan` lists the connected devices and their items without copying anything.

## Items are "not available on the device"

Their originals are only in iCloud, because **Optimize iPhone Storage** is on. Turn it off and give the iPhone time to download the originals, then run the task again. These items count as failed (exit code 1) so scripts notice.

## Hidden and deleted photos

unroll copies what the iPhone shares over the cable, the same as Image Capture. The iPhone doesn't mark hidden photos there, so as far as we know they're copied like any other photo. Recently Deleted isn't shared, so those aren't copied. To check on your iPhone, hide a test photo and look for it in `unroll run "<task>" --dry-run --list`.

## Changing the folder structure

A new structure applies to files copied from then on. Files copied earlier stay where they are until you arrange them: unroll offers that right after the change, and it's always under More for "…" → Arrange existing files. See `unroll help arrange`.

## Photos arrive as JPEG instead of HEIC

Set Settings → Photos → Transfer to Mac or PC → **Keep Originals** on the iPhone.

## "The destination isn't connected"

The task's drive isn't mounted. unroll recognizes it by its volume UUID, so a different drive with the same name won't be used. Network shares must be mounted in Finder first.

## A sync was interrupted

Just run the task again. An interrupted file is never recorded as imported; the next run cleans it up and copies it again. Ctrl-C finishes the current file before stopping.

## The index is lost or damaged

Use **Rebuild index** (More for "…" in the menu) or `unroll rebuild-index`. It reads every file in the destination and records it again; files are never changed. The next run asks once before copying.

## Files aren't added to Apple Photos

- Check that **Add to Apple Photos** is on for the task (Edit task), and that adding isn't paused in Settings.
- If macOS didn't allow it: System Settings → Privacy & Security → Automation → your terminal app → Photos. The files are added on the next run.
- If Photos copied the files into its library, "Copy items to the Photos library" was on in Photos → Settings → General.

## macOS asks for permission again after an update

A build from source gets a new signature after `brew upgrade`, so macOS may ask once more to allow controlling Photos. Allow it again.

## Where the logs are

`~/Library/Logs/unroll/`, one file per day. Each run lists every copied or failed file.
