import Foundation
@testable import UnrollCore

/// Builds device items with readable defaults.
func item(
    _ id: String,
    _ filename: String,
    date: Int64 = 1_780_393_586,
    size: Int64 = 1_000,
    kind: MediaKind = .photo,
    role: ItemRole = .original,
    asset: String? = nil,
    parent: String? = nil
) -> DeviceItem {
    DeviceItem(
        deviceItemID: id, filename: filename, originalFilename: filename,
        captureDate: LocalTimestamp(secondsSince1970: date), size: size, kind: kind, role: role,
        assetID: asset, parentItemID: parent
    )
}

final class FakeDeviceSession: DeviceSession, @unchecked Sendable {
    let info: DeviceInfo
    var items: [DeviceItem]
    var listError: DeviceError?
    private(set) var closed = false

    init(info: DeviceInfo, items: [DeviceItem]) {
        self.info = info
        self.items = items
    }

    func listItems(progress: @escaping @Sendable (Int) -> Void) async throws(DeviceError) -> [DeviceItem] {
        if let listError { throw listError }
        progress(100)
        return items
    }

    func close() async {
        closed = true
    }
}

final class FakeDeviceBrowser: DeviceBrowsing, @unchecked Sendable {
    var devices: [DeviceInfo]
    var session: FakeDeviceSession?
    var openError: DeviceError?
    private(set) var openCalls = 0

    init(devices: [DeviceInfo] = [], session: FakeDeviceSession? = nil) {
        self.devices = devices
        self.session = session
    }

    func connectedDevices() async -> [DeviceInfo] {
        devices
    }

    func open(_ id: DeviceID, unlockTimeout: Duration) async throws(DeviceError) -> any DeviceSession {
        openCalls += 1
        if let openError { throw openError }
        guard let session, session.info.id == id else { throw .notFound }
        return session
    }
}

struct FakeDestinations: DestinationResolving {
    var resolved: ResolvedDestination?

    func resolve(_ destination: Destination) -> ResolvedDestination? {
        resolved
    }
}

struct FakeIndex: ImportIndex {
    var keys: Set<ItemKey>

    func importedKeys() throws -> Set<ItemKey> { keys }
    func meta() throws -> IndexMeta { IndexMeta(indexID: "fake", itemCount: keys.count) }
}

struct FakeIndexes: IndexProviding {
    var index: FakeIndex?

    func existingIndex(at destinationRoot: URL) throws -> (any ImportIndex)? { index }
}

final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [SyncEvent] = []

    var events: [SyncEvent] {
        lock.withLock { recorded }
    }

    func record(_ event: SyncEvent) {
        lock.withLock { recorded.append(event) }
    }
}

let phone = DeviceInfo(id: DeviceID("phone-1"), name: "Test iPhone", productKind: "iPhone", access: .available)

func sampleTask(versions: VersionPolicy = .original) -> SyncTask {
    SyncTask(
        name: "iPhone → SSD",
        device: .init(id: phone.id, name: phone.name),
        destination: Destination(kind: .local, volumeUUID: "VOL-1", remountURL: nil, volumeName: "Photos-SSD", path: "Photos"),
        versions: versions
    )
}

let ssd = ResolvedDestination(
    root: URL(filePath: "/Volumes/Photos-SSD/Photos", directoryHint: .isDirectory),
    volumeName: "Photos-SSD", kind: .external, format: "APFS", isReadOnly: false
)
