import Foundation
import UnrollCore
import UnrollStore

/// Line-oriented output without colors or animation, for pipes, scripts and Shortcuts.
struct PlainRenderer: Sendable {
    func handle(_ event: SyncEvent) {
        switch event {
        case .checkStarted, .listingProgress:
            break
        case .checkPassed(let check, let detail):
            print("✓ \(Self.label(check)): \(detail)")
        case .checkFailed(let check, _):
            print("✗ \(Self.label(check))")
        case .listingStarted:
            print("Reading item list…")
        case .itemsListed(let count):
            print("Listed \(count) files")
        case .comparisonDone(let summary):
            print("Compared against index: \(summary.newCount) new (\(Format.bytes(summary.newBytes))), "
                + "\(summary.alreadyImported) already imported")
            if summary.excludedByVersions > 0 {
                print("  \(summary.excludedByVersions) skipped by the task's original/edited setting")
            }
            if summary.unavailable > 0 {
                print("  \(summary.unavailable) not available on the device (see `unroll help troubleshooting`)")
            }
        }
    }

    func printPlan(_ plan: SyncPlan, listItems: Bool) {
        let summary = plan.summary
        guard summary.newCount > 0 else {
            print("\nNothing new to copy.")
            return
        }
        print("\nNew items by month:")
        for month in summary.months {
            let label = String(format: "%04d-%02d", month.year, month.month)
            print("  \(label)  \(String(month.count).leftPadded(to: 6))  \(Format.bytes(month.bytes).leftPadded(to: 10))")
        }
        print("\nDestination folders in \(VolumeResolver.displayPath(plan.destinationRoot)):")
        for folder in summary.folders.prefix(listItems ? .max : 12) {
            print("  \(folder)")
        }
        if !listItems, summary.folders.count > 12 {
            print("  … \(summary.folders.count - 12) more")
        }
        if listItems {
            print("\nNew items:")
            for entry in plan.items {
                print("  \(entry.folder)/\(entry.item.filename)  \(entry.key.captureDate)  \(Format.bytes(entry.item.size))")
            }
        }
    }

    static func label(_ check: Check) -> String {
        switch check {
        case .destination: "Destination"
        case .device: "Device"
        }
    }
}

enum Format {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
