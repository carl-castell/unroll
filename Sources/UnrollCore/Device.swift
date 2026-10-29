import Foundation

/// Stable identifier of an iPhone or iPad, as reported by the device adapter.
public struct DeviceID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public enum DeviceAccess: Sendable, Equatable {
    case available
    /// Passcode-locked, or connected to a Mac the device doesn't trust yet.
    case restricted
}

public struct DeviceInfo: Sendable, Equatable, Identifiable {
    public let id: DeviceID
    public let name: String
    public let productKind: String?
    public let access: DeviceAccess

    public init(id: DeviceID, name: String, productKind: String?, access: DeviceAccess) {
        self.id = id
        self.name = name
        self.productKind = productKind
        self.access = access
    }
}

public enum MediaKind: String, Sendable, Codable {
    case photo, video, sidecar, other
}

/// One file on the device, described without downloading it.
public struct DeviceItem: Sendable, Equatable {
    /// Identifies the item within one open session.
    public let deviceItemID: String
    public let originalFilename: String
    public let captureDate: Date?
    public let size: Int64
    public let kind: MediaKind
    /// Shared by the files of one asset, e.g. the HEIC and MOV of a Live Photo.
    public let groupID: String?
    /// Set on sidecar files (AAE) to the item they belong to.
    public let parentItemID: String?

    public init(
        deviceItemID: String,
        originalFilename: String,
        captureDate: Date?,
        size: Int64,
        kind: MediaKind,
        groupID: String?,
        parentItemID: String?
    ) {
        self.deviceItemID = deviceItemID
        self.originalFilename = originalFilename
        self.captureDate = captureDate
        self.size = size
        self.kind = kind
        self.groupID = groupID
        self.parentItemID = parentItemID
    }
}

public enum DeviceError: Error, Sendable, Equatable {
    case notFound
    case accessRestricted(name: String)
    case sessionFailed(String)
    case disconnected
}

public protocol DeviceBrowsing: Sendable {
    func connectedDevices() async -> [DeviceInfo]
    /// Opens a session and waits up to `unlockTimeout` for a locked or untrusted device to become available.
    func open(_ id: DeviceID, unlockTimeout: Duration) async throws(DeviceError) -> any DeviceSession
}

public protocol DeviceSession: Sendable {
    var info: DeviceInfo { get }
    /// Lists all items. `progress` receives the catalog completion in percent.
    func listItems(progress: @escaping @Sendable (Int) -> Void) async throws(DeviceError) -> [DeviceItem]
    func close() async
}
