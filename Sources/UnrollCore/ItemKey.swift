import Foundation

/// Identifies an item across runs: capture date + size + original filename.
/// Filenames alone repeat on iPhones (IMG_1234), so all three must match.
public struct ItemKey: Hashable, Sendable {
    /// Whole seconds since 1970, UTC.
    public let captureDate: Int64
    public let size: Int64
    /// NFC-normalized, so the same name matches no matter how it was encoded.
    public let originalFilename: String

    public init(captureDate: Date, size: Int64, originalFilename: String) {
        self.captureDate = Int64(captureDate.timeIntervalSince1970.rounded(.down))
        self.size = size
        self.originalFilename = originalFilename.precomposedStringWithCanonicalMapping
    }
}
