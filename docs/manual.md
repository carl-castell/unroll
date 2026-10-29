# NAME

unroll - copy only the new photos and videos from an iPhone to a folder on a drive

# SYNOPSIS

```
unroll
unroll run <task> [--dry-run] [--yes] [--json] [--list]
unroll status [--json]
unroll tasks [list | add | remove]
unroll rebuild-index [<task>] [--yes]
unroll scan
unroll help [<topic>]
```

# DESCRIPTION

unroll reads photos and videos directly from a connected iPhone or iPad, remembers what it has already copied, and copies only new items into a date-based folder structure on a drive. Optionally it adds them to Apple Photos as referenced files, so the Photos library stays small while the originals stay in the folder. It never changes or deletes anything on the device.

Run without arguments in a terminal, unroll opens an interactive menu. Outside a terminal it never shows menus or prompts; without arguments it prints the help.

# COMMANDS

## run <task>

Checks that the task's destination and device are connected, compares the device with the destination's index and copies only new items. `--dry-run` only shows what would be copied, by month; `--list` adds every item. `--yes` confirms a first run (or a run after the task's device, destination or index changed) without asking. `--json` writes one JSON object per line, ending with `result` and the exit code. Ctrl-C finishes the current file, then stops.

## status

Shows the connected devices and, for each task, whether its device and destination are connected, its last run and the number of files in its destination. `--json` prints a single object.

## tasks

`tasks list` shows all tasks. `tasks add --name <name> --destination <folder>` creates one without the wizard; `--device`, `--folder-template` and `--versions` are optional. `tasks remove <task>` deletes a task but never the files or the index in its destination.

## rebuild-index

Recreates a task's index from the files in its destination. Files are only read. Asks for confirmation unless `--yes` is given; without a terminal, `--yes` is required.

## scan

Lists connected devices and the items on them without copying anything. Useful for troubleshooting.

## help <topic>

Shows a help topic: setup, tasks, photos-referenced, troubleshooting, exit-codes or keys.
