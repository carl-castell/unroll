# Arranging existing files

unroll can move the photos and videos already in a task's destination into the task's folder structure. That helps when the folder holds photos copied earlier in another layout, for example everything in one folder, or when you changed the task's folder structure and want the older files to follow.

## When it's offered

- After you save a new task whose folder already has photos in another layout.
- After you change a task's folder structure.
- Any time under **More for "…" → Arrange existing files…**, or with `unroll arrange "<task>"`.

It first shows how many files would move, with a few examples, and asks. Nothing moves unless you agree.

## What moves and what stays

- Photos and videos with a capture time move into the folder for that time. A Live Photo's video and its edit data (AAE) move with the photo and keep matching names.
- Files without a capture time stay where they are, because there's no date to sort them by. So do files that aren't photos or videos.
- Files already added to Apple Photos as referenced files stay too; moving them would make Photos lose them.

## Safety

- Files are only moved within the destination. They are never copied, replaced or deleted. If a name is taken in the target folder, the file gets ` (1)` added, and a Live Photo's video gets the same.
- The index is updated with every move, so the files stay known and aren't copied again.
- A folder without an index gets one first.
- Every move is listed in `.unroll/arrange-<date>-<time>.tsv` (old path, new path), so it can be undone by hand.
- Folders left empty by the moves are removed.
- Ctrl-C finishes the current move, then stops; arranging again moves the rest.

## On the command line

`unroll arrange "<task>" --dry-run` shows what would move (`--list` shows every move). Without a terminal, `--yes` is required to move anything; otherwise unroll stops with exit code 5.
