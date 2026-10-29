# Exit codes

unroll ends with one of these codes, so scripts and Shortcuts can react. With `--json`, the last line also contains it.

- **0**: success, including when there was nothing new to copy.
- **1**: finished, but some items failed or weren't available on the device, or they couldn't be added to Apple Photos.
- **2**: the destination isn't available: its drive isn't connected, it's read-only, full, or another run is using it.
- **3**: the iPhone isn't connected, is locked, or doesn't trust this Mac.
- **4**: the task wasn't found, or the configuration is invalid.
- **5**: the run needs confirmation, but there's no terminal to ask in. Run it once in a terminal, or pass `--yes`.
- **130**: stopped with Ctrl-C after finishing the current file.
