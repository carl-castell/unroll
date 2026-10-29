import Foundation

/// A named, saved sync configuration: one device to one destination folder.
public struct SyncTask: Codable, Sendable, Equatable, Identifiable {
    public struct DeviceRef: Codable, Sendable, Equatable {
        public var id: DeviceID
        /// For display only; the device is matched by `id`.
        public var name: String

        public init(id: DeviceID, name: String) {
            self.id = id
            self.name = name
        }
    }

    public var id: UUID
    public var name: String
    public var device: DeviceRef
    public var destination: Destination
    public var folderTemplate: FolderTemplate
    public var versions: VersionPolicy
    public var addToPhotos: Bool
    public var notify: Bool
    public var lastRun: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        device: DeviceRef,
        destination: Destination,
        folderTemplate: FolderTemplate = .default,
        versions: VersionPolicy = .original,
        addToPhotos: Bool = false,
        notify: Bool = false,
        lastRun: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.device = device
        self.destination = destination
        self.folderTemplate = folderTemplate
        self.versions = versions
        self.addToPhotos = addToPhotos
        self.notify = notify
        self.lastRun = lastRun
    }

    /// Finds a task by exact name (case-insensitive) or by a unique ID prefix.
    public static func find(_ query: String, in tasks: [SyncTask]) -> SyncTask? {
        if let byName = tasks.first(where: { $0.name.caseInsensitiveCompare(query) == .orderedSame }) {
            return byName
        }
        let byID = tasks.filter { $0.id.uuidString.lowercased().hasPrefix(query.lowercased()) }
        return query.count >= 4 && byID.count == 1 ? byID[0] : nil
    }
}

/// Which renderings of edited photos to copy.
public enum VersionPolicy: String, Codable, Sendable, CaseIterable {
    /// Originals only (with their Live Photo videos).
    case original
    /// The edited version where one exists, otherwise the original.
    case edited
    /// Originals, edited versions and edit data (AAE).
    case both
}

/// Where a task copies to: a folder on a volume identified by its UUID, or on a network share.
public struct Destination: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case local, network
    }

    public var kind: Kind
    /// Identifies local volumes. Never matched by name or mount path.
    public var volumeUUID: String?
    /// Identifies network shares, e.g. smb://nas.local/Photos.
    public var remountURL: String?
    /// For display only.
    public var volumeName: String
    /// Folder relative to the volume root.
    public var path: String

    public init(kind: Kind, volumeUUID: String?, remountURL: String?, volumeName: String, path: String) {
        self.kind = kind
        self.volumeUUID = volumeUUID
        self.remountURL = remountURL
        self.volumeName = volumeName
        self.path = path
    }
}

public enum VolumeKind: String, Sendable {
    case `internal`, external, network
}

/// A destination whose volume is currently mounted.
public struct ResolvedDestination: Sendable, Equatable {
    public let root: URL
    public let volumeName: String
    public let kind: VolumeKind
    public let format: String?
    public let isReadOnly: Bool
    public let availableBytes: Int64?

    public init(
        root: URL, volumeName: String, kind: VolumeKind, format: String?, isReadOnly: Bool, availableBytes: Int64? = nil
    ) {
        self.root = root
        self.volumeName = volumeName
        self.kind = kind
        self.format = format
        self.isReadOnly = isReadOnly
        self.availableBytes = availableBytes
    }
}

public protocol DestinationResolving: Sendable {
    /// Nil when the destination's volume isn't mounted.
    func resolve(_ destination: Destination) -> ResolvedDestination?
}
