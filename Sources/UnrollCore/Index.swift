import Foundation

/// The import index stored with the files in the destination.
public protocol ImportIndex: Sendable {
    /// Keys of everything already imported, including aliases of content duplicates.
    func importedKeys() throws -> Set<ItemKey>
    func meta() throws -> IndexMeta
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
