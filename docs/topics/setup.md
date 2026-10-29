# Setting up your iPhone and Mac

## On the iPhone

- Settings → Photos → Transfer to Mac or PC → **Keep Originals**. Otherwise the iPhone may convert photos to JPEG during the transfer.
- If you use iCloud Photos on the phone, turn off **Optimize iPhone Storage**. With it on, many full-resolution originals are only in iCloud and can't be copied by cable; unroll reports them as "not available on the device".
- Connect the iPhone by cable and unlock it. The first time, tap **Trust This Computer** and enter your passcode. Keep it unlocked while a sync runs.

## On the Mac

- Connect the drive you want to copy to. Any drive Finder shows works: an external SSD, a network share, or a folder on this Mac's internal disk.
- External drives should be formatted as APFS or Mac OS Extended (Journaled).
- Run `unroll` in a terminal. On the first launch, a wizard sets up your first sync task.

## Permissions

- To add files to Apple Photos, macOS asks once whether your terminal app may control Photos. Allow it, or change it later in System Settings → Privacy & Security → Automation.
- Notifications are shown by Script Editor on unroll's behalf; macOS may ask to allow them.
