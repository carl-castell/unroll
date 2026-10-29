import Foundation

/// Identifies an item across runs: capture time + size + file name on the device.
/// File names alone repeat on iPhones (IMG_1234), so all three must match.
public struct ItemKey: Hashable, Sendable {
    public let captureDate: LocalTimestamp
    public let size: Int64
    /// The device file name (IMG_1234.HEIC, IMG_E1234.HEIC), NFC-normalized so the same name
    /// matches no matter how it was encoded.
    public let filename: String

    public init(captureDate: LocalTimestamp, size: Int64, filename: String) {
        self.captureDate = captureDate
        self.size = size
        self.filename = filename.precomposedStringWithCanonicalMapping
    }

    /// Nil for items without a capture date, which can't be matched reliably.
    public init?(_ item: DeviceItem) {
        guard let captureDate = item.captureDate else { return nil }
        self.init(captureDate: captureDate, size: item.size, filename: item.filename)
    }
}
