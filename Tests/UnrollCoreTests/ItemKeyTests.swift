import Foundation
import Testing
@testable import UnrollCore

struct ItemKeyTests {
    @Test func truncatesToWholeSeconds() {
        let a = ItemKey(captureDate: Date(timeIntervalSince1970: 1000.2), size: 1, originalFilename: "IMG_1.HEIC")
        let b = ItemKey(captureDate: Date(timeIntervalSince1970: 1000.9), size: 1, originalFilename: "IMG_1.HEIC")
        #expect(a == b)
        #expect(a.captureDate == 1000)
    }

    @Test func normalizesFilenameToNFC() {
        let decomposed = "Cafe\u{301}.JPG"
        let key = ItemKey(captureDate: .distantPast, size: 1, originalFilename: decomposed)
        #expect(key.originalFilename.unicodeScalars.count == "Café.JPG".unicodeScalars.count)
    }

    @Test func sameNameDifferentSizeOrDateDiffers() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let base = ItemKey(captureDate: date, size: 100, originalFilename: "IMG_1234.HEIC")
        #expect(base != ItemKey(captureDate: date, size: 101, originalFilename: "IMG_1234.HEIC"))
        #expect(base != ItemKey(captureDate: date.addingTimeInterval(1), size: 100, originalFilename: "IMG_1234.HEIC"))
    }
}
