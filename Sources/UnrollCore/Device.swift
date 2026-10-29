import Foundation

/// Stable identifier of an iPhone or iPad, as reported by the device adapter.
public struct DeviceID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum DeviceAccess: Sendable, Equatable {
    case available
    /// Passcode-locked, or connected to a Mac the device doesn't trust yet.
    /// Until a session is opened, iPhones report this even when unlocked and trusted.
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
    case photo, video, other
}

/// How a file relates to the photo or video it belongs to.
public enum ItemRole: String, Sendable, Codable {
    /// The original photo or video.
    case original
    /// The video half of a Live Photo, attached to its photo.
    case livePhotoVideo
    /// An edited rendering (IMG_E1234), next to the original.
    case edited
    /// Edit instructions or other data files (AAE, DAT).
    case sidecar
}

/// One file on the device, described without downloading it.
public struct DeviceItem: Sendable, Equatable {
    /// Identifies the item within one open session.
    public let deviceItemID: String
    /// The file name on the device, e.g. IMG_1234.HEIC or IMG_E1234.HEIC.
    public let filename: String
    /// The name the file had when it was created; "FullSizeRender.heic" for edits,
    /// or another device's name for photos that were shared to this one.
    public let originalFilename: String?
    public let captureDate: LocalTimestamp?
    public let size: Int64
    public let kind: MediaKind
    public let role: ItemRole
    /// Shared by an original, its edits and its Live Photo video.
    public let assetID: String?
    /// Set on Live Photo videos and sidecars to the item they are attached to.
    public let parentItemID: String?

    public init(
        deviceItemID: String,
        filename: String,
        originalFilename: String?,
        captureDate: LocalTimestamp?,
        size: Int64,
        kind: MediaKind,
        role: ItemRole,
        assetID: String?,
        parentItemID: String?
    ) {
        self.deviceItemID = deviceItemID
        self.filename = filename
        self.originalFilename = originalFilename
        self.captureDate = captureDate
        self.size = size
        self.kind = kind
        self.role = role
        self.assetID = assetID
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
