# NAME

unroll - copy only the new photos and videos from an iPhone to a folder on a drive

# SYNOPSIS

```
unroll
unroll run <task> [--dry-run] [--yes] [--json] [--list]
unroll status [--json]
unroll tasks [list | add | remove]
unroll arrange [<task>] [--dry-run] [--list] [--yes]
unroll rebuild-index [<task>] [--yes]
unroll scan
unroll help [<topic>]
```

# DESCRIPTION

unroll reads photos and videos directly from a connected iPhone or iPad, remembers what it has already copied, and copies only new items into a date-based folder structure on a drive. Optionally it adds them to Apple Photos as referenced files, so the Photos library stays small while the originals stay in the folder. It never changes or deletes anything on the device.

Run without arguments in a terminal, unroll opens an interactive menu. Outside a terminal it never shows menus or prompts; without arguments it prints the help.

# COMMANDS

## run <task>

Checks that the task's destination and device are connected, compares the device with the destination's index and copies only new items. `--dry-run` only shows how many files would be copied, their size and the space left afterwards; `--list` adds a breakdown by month and every file. `--yes` confirms a first run (or a run after the task's device, destination or index changed) without asking. `--json` writes one JSON object per line, ending with `result` and the exit code. Ctrl-C finishes the current file, then stops.

## status

Shows the connected devices and, for each task, whether its device and destination are connected, its last run and the number of files in its destination. `--json` prints a single object.

## tasks

`tasks list` shows all tasks. `tasks add --name <name> --destination <folder>` creates one without the wizard; `--device`, `--folder-template` (or `none`), `--versions` and `--camera-model` (repeatable) are optional. `tasks remove <task>` deletes a task but never the files or the index in its destination.

## arrange

Moves the photos and videos already in a task's destination into its folder structure, keeping a Live Photo's video and edit data with their photo. Files are only moved, never replaced or deleted; files without a capture time, other files and files added to Apple Photos stay. Every move is listed in `.unroll/arrange-<time>.tsv`. `--dry-run` only shows what would move. Asks for confirmation unless `--yes` is given; without a terminal, `--yes` is required. See `unroll help arrange`.

## rebuild-index

Recreates a task's index from the files in its destination. Files are only read. Asks for confirmation unless `--yes` is given; without a terminal, `--yes` is required.

## scan

Lists connected devices and the items on them without copying anything. Useful for troubleshooting.

## help <topic>

Shows a help topic: setup, tasks, photos-referenced, troubleshooting, exit-codes or keys.
