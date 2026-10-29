import Foundation

/// The import index stored with the files in the destination.
public protocol ImportIndex: Sendable {
    /// Keys of everything already imported, including aliases of content duplicates.
    func importedKeys() throws -> ImportedKeys
    func meta() throws -> IndexMeta
    /// Photos and videos (no edit data) copied from one device, with where they are now.
    func files(fromDevice id: DeviceID) throws -> [IndexedFile]
}

extension ImportIndex {
    public func files(fromDevice id: DeviceID) throws -> [IndexedFile] { [] }
}

/// A file in the index: its key and where it is in the destination.
public struct IndexedFile: Sendable, Equatable {
    public let key: ItemKey
    public let relativePath: String

    public init(key: ItemKey, relativePath: String) {
        self.key = key
        self.relativePath = relativePath
    }
}

public struct IndexMeta: Sendable, Equatable {
    /// Changes whenever the index is created or rebuilt.
    public let indexID: String
    public let itemCount: Int

    public init(indexID: String, itemCount: Int) {
        self.indexID = indexID
        self.itemCount = itemCount
    }
}

public protocol IndexProviding: Sendable {
    /// Opens a destination's index for reading. Nil if it doesn't exist yet; never creates one.
    func existingIndex(at destinationRoot: URL) throws -> (any ImportIndex)?
}

/// One file recorded in the index after it was copied and verified.
public struct IndexedItem: Sendable, Equatable {
    public let key: ItemKey
    /// Relative to the destination root, e.g. `2026/2026-06/IMG_2211.HEIC`.
    public let relativePath: String
    public let sha256: Data
    public let role: ItemRole
    public let assetID: String?
    public let deviceID: DeviceID?
    public let originalFilename: String?
    public let importedAt: Date

    public init(
        key: ItemKey, relativePath: String, sha256: Data, role: ItemRole, assetID: String?,
        deviceID: DeviceID?, originalFilename: String?, importedAt: Date
    ) {
        self.key = key
        self.relativePath = relativePath
        self.sha256 = sha256
        self.role = role
        self.assetID = assetID
        self.deviceID = deviceID
        self.originalFilename = originalFilename
        self.importedAt = importedAt
    }
}
