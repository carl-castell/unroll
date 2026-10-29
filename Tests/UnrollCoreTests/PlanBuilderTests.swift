import Foundation
import Testing
@testable import UnrollCore
import UnrollTestSupport

struct PlanBuilderTests {
    /// A Live Photo with an edit, its AAE, and the edited Live Photo video, as an iPhone reports them.
    let editedLivePhoto: [DeviceItem] = [
        item("1", "IMG_0783.HEIC", asset: "A"),
        item("2", "IMG_0783.MOV", kind: .video, role: .livePhotoVideo, asset: "A", parent: "1"),
        item("3", "IMG_0783.AAE", kind: .other, role: .sidecar, asset: "A", parent: "1"),
        item("4", "IMG_E0783.HEIC", role: .edited, asset: "A"),
        item("5", "IMG_E0783.MOV", kind: .video, role: .livePhotoVideo, asset: "A", parent: "4"),
    ]

    func names(_ items: [DeviceItem], _ versions: VersionPolicy, imported: ImportedKeys = []) -> [String] {
        PlanBuilder.plan(items: items, importedKeys: imported, versions: versions, folderTemplate: .default)
            .items.map(\.item.filename)
    }

    @Test func originalPolicyKeepsOriginalAndItsLivePhotoVideo() {
        #expect(names(editedLivePhoto, .original) == ["IMG_0783.HEIC", "IMG_0783.MOV"])
    }

    @Test func editedPolicyReplacesOriginalWithEdit() {
        #expect(names(editedLivePhoto, .edited) == ["IMG_E0783.HEIC", "IMG_E0783.MOV"])
    }

    @Test func editedPolicyKeepsOriginalsWithoutEdit() {
        let plain = [item("1", "IMG_1.HEIC", asset: "B"), item("2", "IMG_1.MOV", kind: .video, role: .livePhotoVideo, asset: "B", parent: "1")]
        #expect(names(plain, .edited) == ["IMG_1.HEIC", "IMG_1.MOV"])
    }

    @Test func bothPolicyKeepsEverything() {
        #expect(names(editedLivePhoto, .both).count == 5)
    }

    @Test func skipsAlreadyImportedKeys() {
        let items = [item("1", "IMG_1.HEIC"), item("2", "IMG_2.HEIC")]
        let imported: ImportedKeys = [ItemKey(items[0])!]
        let plan = PlanBuilder.plan(items: items, importedKeys: imported, versions: .original, folderTemplate: .default)
        #expect(plan.items.map(\.item.filename) == ["IMG_2.HEIC"])
        #expect(plan.summary.alreadyImported == 1)
    }

    /// iPhone file names repeat; a same-named file with another date or size is new.
    @Test func repeatedFilenameWithDifferentDateIsNew() {
        let old = item("1", "IMG_0398.HEIC", date: 1_761_327_312, size: 3_245_240)
        let new = item("2", "IMG_0398.HEIC", date: 1_779_592_729, size: 3_947_480)
        #expect(names([new], .original, imported: [ItemKey(old)!]) == ["IMG_0398.HEIC"])
    }

    @Test func reportsItemsWithoutSizeOrDateAsUnavailable() {
        let missing = DeviceItem(
            deviceItemID: "9", filename: "IMG_9.HEIC", originalFilename: nil, captureDate: nil,
            size: 10, kind: .photo, role: .original, assetID: nil, parentItemID: nil
        )
        let items = [item("1", "IMG_1.HEIC", size: 0), missing, item("2", "IMG_2.HEIC")]
        let plan = PlanBuilder.plan(items: items, importedKeys: [], versions: .original, folderTemplate: .default)
        #expect(plan.summary.unavailable == 2)
        #expect(plan.items.count == 1)
    }

    @Test func summarizesByMonthOldestFirst() {
        let june = Int64(1_780_393_586)   // 2026-06-02 clock time
        let feb = Int64(1_770_923_953)    // 2026-02-12 clock time
        let items = [item("1", "A.HEIC", date: june, size: 10), item("2", "B.HEIC", date: feb, size: 5), item("3", "C.HEIC", date: june, size: 1)]
        let summary = PlanBuilder.plan(items: items, importedKeys: [], versions: .original, folderTemplate: .default).summary
        #expect(summary.months == [
            MonthSummary(year: 2026, month: 2, count: 1, bytes: 5),
            MonthSummary(year: 2026, month: 6, count: 2, bytes: 11),
        ])
        #expect(summary.folders == ["2026/2026-02", "2026/2026-06"])
        #expect(summary.newBytes == 16)
    }
}

struct ImportedKeysTests {
    let key = ItemKey(captureDate: LocalTimestamp(secondsSince1970: 1_000), size: 10, filename: "IMG_1.MOV")

    func shifted(_ seconds: Int64) -> ItemKey {
        ItemKey(captureDate: LocalTimestamp(secondsSince1970: 1_000 + seconds), size: 10, filename: "IMG_1.MOV")
    }

    @Test func exactKeysMatchOnlyExactly() {
        let keys: ImportedKeys = [key]
        #expect(keys.contains(key))
        #expect(!keys.contains(shifted(1)))
    }

    /// Rebuilt video times can differ from the device's by a second or two.
    @Test func approximateKeysMatchWithinTolerance() {
        let keys = ImportedKeys(approximate: [key])
        #expect(keys.contains(shifted(-2)))
        #expect(keys.contains(shifted(2)))
        #expect(!keys.contains(shifted(3)))
        let otherSize = ItemKey(captureDate: key.captureDate, size: 11, filename: "IMG_1.MOV")
        #expect(!keys.contains(otherSize))
    }
}

struct LocalTimestampParsingTests {
    @Test func parsesStoredAndExifForms() {
        #expect(LocalTimestamp(parsing: "2026-06-02 11:46:26")?.description == "2026-06-02 11:46:26")
        #expect(LocalTimestamp(parsing: "2026:06:02 11:46:26")?.description == "2026-06-02 11:46:26")
        // QuickTime: the offset is ignored, the clock time kept.
        #expect(LocalTimestamp(parsing: "2026-06-02T11:46:26+0400")?.description == "2026-06-02 11:46:26")
        #expect(LocalTimestamp(parsing: "not a date") == nil)
        #expect(LocalTimestamp(parsing: "2026-13-02 11:46:26") == nil)
    }
}

struct FolderTemplateTests {
    @Test func rendersTokens() throws {
        let date = LocalTimestamp(secondsSince1970: 1_780_393_586) // 2026-06-02
        #expect(FolderTemplate.default.folder(for: date) == "2026/2026-06")
        #expect(try FolderTemplate("YYYY/MM/DD").folder(for: date) == "2026/06/02")
    }

    @Test func rejectsUnsafePatterns() {
        #expect(throws: FolderTemplate.Invalid.absolute) { try FolderTemplate("/YYYY") }
        #expect(throws: FolderTemplate.Invalid.parentReference) { try FolderTemplate("YYYY/../x") }
        #expect(throws: FolderTemplate.Invalid.emptyComponent) { try FolderTemplate("YYYY//MM") }
        #expect(throws: FolderTemplate.Invalid.empty) { try FolderTemplate("") }
    }
}
