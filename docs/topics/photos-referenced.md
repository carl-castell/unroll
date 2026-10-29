# Apple Photos with referenced files

unroll can add new files to Apple Photos after each sync. Photos then shows them without copying them into its library: the originals stay in the destination folder, and the library stays small.

## Setting it up

- In Photos, open Settings → General and turn off **Copy items to the Photos library**. unroll can't read this setting, so it reminds you of it after each import.
- Turn on **Add to Apple Photos** for the task: More for "…" → Edit task.
- Files go into the library Photos has open. To use another library, hold Option while opening Photos.

## What happens during a run

- After copying, unroll hands the new files to Photos in one import, so each sync is one entry under Imports. Live Photos are imported together and stay paired. Edit data (AAE) isn't imported on its own.
- Photos comes to the front during the import and the terminal comes back afterwards. Photos doesn't report progress, so unroll shows the time spent.
- **Let Photos check for duplicates** (on by default) skips photos already in the library, for example from an earlier import straight from the iPhone. When Photos finds some, it asks in its own dialog and waits for your answer, also in runs from Shortcuts. Turn the check off for unattended runs if your library has no older copies.
- If Photos can't be controlled, the files are remembered and added on the next run.
- To pause Photos for all tasks, use **Adding to Apple Photos: allowed / paused** under Help & settings → Settings. Files copied meanwhile are added once it's allowed again.

## Things to know about referenced files

- Thumbnails stay visible when the drive is disconnected. Opening, editing or exporting an original needs the drive connected.
- Don't move or rename folders in the destination after the import, or Photos loses the link.
- Referenced files aren't part of Photos backups and don't sync with iCloud Photos. Back up the destination itself.
- To see which photos are stored inside the library instead, create a Smart Album with the condition "Photo is not Referenced".
