import ArgumentParser
import Foundation
import UnrollCore
import UnrollDevice

/// Lists connected devices and the items on one of them, without downloading anything.
struct Scan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List connected devices and the items on them, without copying anything.",
        discussion: "A diagnostic command. It reads the item list only and never writes or deletes anything."
    )

    @Option(name: .shortAndLong, help: "Device to scan, by name or ID. Defaults to the first connected device.")
    var device: String?

    @Option(help: "Number of items to print. 0 prints all.")
    var limit = 20

    @Flag(help: "Print every date and grouping field ImageCaptureCore reports.")
    var raw = false

    @Option(help: "Request EXIF metadata for this many items and time each request.")
    var exif = 0

    @Option(help: "Seconds to wait for a locked or untrusted device.")
    var unlockTimeout = 30

    @MainActor
    func run() async throws {
        let browser = ICCDeviceBrowser()
        let devices = await browser.connectedDevices()

        print("Devices:")
        if devices.isEmpty {
            print("  none. Connect an iPhone or iPad with a cable and unlock it.")
            throw UnrollExit.deviceUnavailable
        }
        for info in devices {
            // Before a session is open, iPhones always report access as restricted, so no state is shown here.
            print("  \(info.name) (\(info.productKind ?? "unknown")) id=\(info.id)")
        }

        guard let target = pick(from: devices) else {
            print("No connected device matches \"\(device ?? "")\".")
            throw UnrollExit.deviceUnavailable
        }

        let session: ICCDeviceSession
        do {
            session = try await openSession(target, browser: browser)
        } catch {
            print(Self.message(for: error))
            throw UnrollExit.deviceUnavailable
        }
        defer { Task { await session.close() } }

        let start = ContinuousClock.now
        let reporter = PercentReporter()
        let items: [DeviceItem]
        do {
            items = try await session.listItems { percent in
                // The ImageCaptureCore session reports progress on the main actor.
                MainActor.assumeIsolated { reporter.report(percent) }
            }
        } catch {
            print(Self.message(for: error))
            throw UnrollExit.deviceUnavailable
        }
        print("Listed in \(start.duration(to: .now).formatted(.units(allowed: [.seconds, .milliseconds])))")

        printSummary(items)
        if raw {
            printRaw(session.rawFields())
        } else {
            printItems(items)
        }
        if exif > 0 {
            await printExif(session, limit: exif)
        }
    }

    /// Opens the device, asking to unlock it only if a first quick attempt fails.
    @MainActor
    private func openSession(_ target: DeviceInfo, browser: ICCDeviceBrowser) async throws(DeviceError) -> ICCDeviceSession {
        do {
            return try await browser.openSession(target.id, unlockTimeout: .seconds(2))
        } catch .accessRestricted, .sessionFailed {
            print("Waiting up to \(unlockTimeout)s: unlock \"\(target.name)\" and tap Trust if asked…")
            return try await browser.openSession(target.id, unlockTimeout: .seconds(unlockTimeout))
        }
    }

    private func pick(from devices: [DeviceInfo]) -> DeviceInfo? {
        guard let device else { return devices.first }
        return devices.first { $0.id.rawValue == device || $0.name.localizedCaseInsensitiveCompare(device) == .orderedSame }
    }

    private func printSummary(_ items: [DeviceItem]) {
        let total = items.reduce(Int64(0)) { $0 + $1.size }
        print("\n\(items.count) files, \(Self.bytes(total))")
        let rows: [(String, (DeviceItem) -> Bool)] = [
            ("photos", { $0.role == .original && $0.kind == .photo }),
            ("videos", { $0.role == .original && $0.kind == .video }),
            ("Live Photo videos", { $0.role == .livePhotoVideo }),
            ("edited versions", { $0.role == .edited }),
            ("sidecars (AAE, DAT)", { $0.role == .sidecar }),
            ("other", { $0.role == .original && $0.kind == .other }),
        ]
        for (label, matches) in rows {
            let group = items.filter(matches)
            guard !group.isEmpty else { continue }
            print("  \(label): \(group.count) (\(Self.bytes(group.reduce(0) { $0 + $1.size })))")
        }
        print("  files without capture date: \(items.filter { $0.captureDate == nil }.count)")
        print("  items with size 0: \(items.filter { $0.size == 0 }.count)")
    }

    private func printItems(_ items: [DeviceItem]) {
        let shown = limit == 0 ? items[...] : items.prefix(limit)
        print("")
        for item in shown {
            let date = item.captureDate?.description ?? "no date"
            let asset = item.assetID.map { " asset=\($0.prefix(8))" } ?? ""
            print("  \(item.filename)  \(date)  \(Self.bytes(item.size))  \(item.kind.rawValue)/\(item.role.rawValue)\(asset)")
        }
        if shown.count < items.count {
            print("  … \(items.count - shown.count) more (use --limit 0 to show all)")
        }
    }

    private func printRaw(_ fields: [ICCDeviceSession.RawFields]) {
        let shown = limit == 0 ? fields[...] : fields.prefix(limit)
        for f in shown {
            print("")
            print("  \(f.name ?? "?")  original=\(f.originalFilename ?? "-")  uti=\(f.uti ?? "-")  size=\(f.size)")
            print("    creationDate=\(Self.optionalDate(f.creationDate))  modificationDate=\(Self.optionalDate(f.modificationDate))")
            print("    fileCreationDate=\(Self.optionalDate(f.fileCreationDate))  exifCreationDate=\(Self.optionalDate(f.exifCreationDate))")
            print("    groupUUID=\(f.groupUUID ?? "-")  relatedUUID=\(f.relatedUUID ?? "-")  burstUUID=\(f.burstUUID ?? "-")")
            print("    originatingAssetID=\(f.originatingAssetID ?? "-")  fingerprint=\(f.fingerprint ?? "-")")
            if !f.sidecars.isEmpty { print("    sidecars=\(f.sidecars.joined(separator: ", "))") }
        }
    }

    @MainActor
    private func printExif(_ session: ICCDeviceSession, limit: Int) async {
        print("\nEXIF capture dates (first \(limit)):")
        for sample in await session.exifSamples(limit: limit) {
            let fields = sample.fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "  ")
            print("  \(sample.name)  \(fields.isEmpty ? "no EXIF dates" : fields)  (\(sample.duration))")
        }
    }

    static func message(for error: DeviceError) -> String {
        switch error {
        case .notFound: "The device is no longer connected."
        case .accessRestricted(let name): "\"\(name)\" is locked or doesn't trust this Mac. Unlock it, tap Trust, and try again."
        case .sessionFailed(let reason): "Couldn't open the device: \(reason)"
        case .disconnected: "The device was disconnected."
        case .downloadFailed(let reason): "Download failed: \(reason)"
        }
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func optionalDate(_ date: Date?) -> String {
        date.map { $0.formatted(.iso8601) } ?? "-"
    }
}

/// Prints catalog progress in steps of 10 %.
@MainActor
private final class PercentReporter {
    private var last = -1

    func report(_ percent: Int) {
        guard percent >= last + 10 || (percent == 100 && last != 100) else { return }
        last = percent
        print("Reading item list… \(percent)%")
    }
}
