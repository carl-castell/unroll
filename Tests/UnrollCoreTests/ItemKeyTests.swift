import Foundation
import Testing
@testable import UnrollCore

struct ItemKeyTests {
    @Test func normalizesFilenameToNFC() {
        let key = ItemKey(captureDate: LocalTimestamp(secondsSince1970: 0), size: 1, filename: "Cafe\u{301}.JPG")
        #expect(key.filename.unicodeScalars.count == "Café.JPG".unicodeScalars.count)
    }

    @Test func sameNameDifferentSizeOrDateDiffers() {
        let time = LocalTimestamp(secondsSince1970: 1_700_000_000)
        let base = ItemKey(captureDate: time, size: 100, filename: "IMG_1234.HEIC")
        #expect(base != ItemKey(captureDate: time, size: 101, filename: "IMG_1234.HEIC"))
        #expect(base != ItemKey(captureDate: LocalTimestamp(secondsSince1970: 1_700_000_001), size: 100, filename: "IMG_1234.HEIC"))
        #expect(base == ItemKey(captureDate: time, size: 100, filename: "IMG_1234.HEIC"))
    }

    @Test func itemWithoutCaptureDateHasNoKey() {
        let item = DeviceItem(
            deviceItemID: "1", filename: "IMG_1.HEIC", originalFilename: nil, captureDate: nil,
            size: 1, kind: .photo, role: .original, assetID: nil, parentItemID: nil
        )
        #expect(ItemKey(item) == nil)
    }
}

struct LocalTimestampTests {
    /// ImageCaptureCore reports 11:46:26 clock time as the instant 11:46:26 in the Mac's zone.
    @Test func recoversClockTimeRegardlessOfMacTimeZone() {
        let berlin = TimeZone(identifier: "Europe/Berlin")!
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let summerInBerlin = Date(timeIntervalSince1970: 1_780_393_586) // 2026-06-02 09:46:26 UTC = 11:46:26 CEST
        let sameClockInTokyo = Date(timeIntervalSince1970: 1_780_368_386) // 2026-06-02 02:46:26 UTC = 11:46:26 JST
        let a = LocalTimestamp(date: summerInBerlin, interpretedIn: berlin)
        let b = LocalTimestamp(date: sameClockInTokyo, interpretedIn: tokyo)
        #expect(a == b)
        #expect(a.description == "2026-06-02 11:46:26")
    }

    @Test func handlesWinterOffset() {
        let berlin = TimeZone(identifier: "Europe/Berlin")!
        let winter = Date(timeIntervalSince1970: 1_770_923_953) // 2026-02-12 19:19:13 UTC = 20:19:13 CET
        #expect(LocalTimestamp(date: winter, interpretedIn: berlin).description == "2026-02-12 20:19:13")
    }

    @Test func truncatesFractionalSeconds() {
        let date = Date(timeIntervalSince1970: 1000.9)
        #expect(LocalTimestamp(date: date, interpretedIn: TimeZone(identifier: "UTC")!).secondsSince1970 == 1000)
    }
}
