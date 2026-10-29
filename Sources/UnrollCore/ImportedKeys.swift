import Foundation

/// The keys of everything already in a destination, used to decide what is new.
public struct ImportedKeys: Sendable, Equatable {
    /// Seconds a capture time may differ for entries whose time was read back from the file
    /// during a rebuild: QuickTime metadata and the device round video times differently.
    public static let tolerance: Int64 = 2

    public struct NameAndSize: Hashable, Sendable {
        public let filename: String
        public let size: Int64

        public init(filename: String, size: Int64) {
            self.filename = filename
            self.size = size
        }
    }

    /// Keys recorded exactly as the device reported them.
    public private(set) var exact: Set<ItemKey>
    /// Capture times of rebuilt entries whose time came from file metadata, by name and size.
    public private(set) var approximate: [NameAndSize: [LocalTimestamp]]

    public init(exact: Set<ItemKey> = [], approximate: [ItemKey] = []) {
        self.exact = exact
        self.approximate = Dictionary(grouping: approximate) { NameAndSize(filename: $0.filename, size: $0.size) }
            .mapValues { $0.map(\.captureDate) }
    }

    public var count: Int {
        exact.count + approximate.values.reduce(0) { $0 + $1.count }
    }

    public var isEmpty: Bool { count == 0 }

    /// Adds the keys of `other`.
    public mutating func formUnion(_ other: ImportedKeys) {
        exact.formUnion(other.exact)
        approximate.merge(other.approximate) { $0 + $1 }
    }

    public func contains(_ key: ItemKey) -> Bool {
        if exact.contains(key) { return true }
        guard let times = approximate[NameAndSize(filename: key.filename, size: key.size)] else { return false }
        return times.contains { abs($0.secondsSince1970 - key.captureDate.secondsSince1970) <= Self.tolerance }
    }
}

extension ImportedKeys: ExpressibleByArrayLiteral {
    /// Exact keys.
    public init(arrayLiteral keys: ItemKey...) {
        self.init(exact: Set(keys))
    }
}
