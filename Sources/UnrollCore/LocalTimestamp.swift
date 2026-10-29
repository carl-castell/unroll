import Foundation

/// A photo's local clock time, e.g. 2026-06-02 11:46:26, without a time zone.
///
/// Stored as seconds since 1970 as if the clock time were UTC. It doesn't change when the Mac's
/// time zone changes, it matches EXIF DateTimeOriginal, and it decides the date folder a photo goes in.
public struct LocalTimestamp: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let secondsSince1970: Int64

    public init(secondsSince1970: Int64) {
        self.secondsSince1970 = secondsSince1970
    }

    /// Recovers the clock time from an instant that was computed by interpreting it in `timeZone`.
    public init(date: Date, interpretedIn timeZone: TimeZone) {
        let offset = TimeInterval(timeZone.secondsFromGMT(for: date))
        secondsSince1970 = Int64((date.timeIntervalSince1970 + offset).rounded(.down))
    }

    /// Clock time components: year, month, day, hour, minute, second.
    public var components: DateComponents {
        Self.calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: Date(timeIntervalSince1970: TimeInterval(secondsSince1970))
        )
    }

    /// "2026-06-02 11:46:26"
    public var description: String {
        let c = components
        return String(
            format: "%04d-%02d-%02d %02d:%02d:%02d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0
        )
    }

    public static func < (lhs: LocalTimestamp, rhs: LocalTimestamp) -> Bool {
        lhs.secondsSince1970 < rhs.secondsSince1970
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
}
