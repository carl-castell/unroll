import CryptoKit
import Foundation
import Testing
import UnrollCore
@testable import UnrollStore
import UnrollTestSupport

/// End-to-end transfers with a fake device, the real destination store and real files in a temp folder.
struct TransferTests {
    let root: URL
    let session: FakeDeviceSession
    let engine: SyncEngine

    init() throws {
        root = try temporaryDirectory().appending(path: "Photos", directoryHint: .isDirectory)
        session = FakeDeviceSession(info: phone, items: [])
        let destination = ResolvedDestination(
            root: root, volumeName: "Test", kind: .external, format: "APFS", isReadOnly: false, availableBytes: nil
        )
        engine = SyncEngine(
            devices: FakeDeviceBrowser(devices: [phone], session: session),
            destinations: FakeDestinations(resolved: destination),
            indexes: SQLiteIndexProvider(),
            writers: DestinationStoreOpener()
        )
    }

    @discardableResult
    func run(
        limit: Int? = nil, versions: VersionPolicy = .original, folders: FolderTemplate = .default,
        photos: FakePhotos? = nil, step: PhotosStep? = nil
    ) async throws -> SyncSummary {
        let task = sampleTask(versions: versions, folders: folders)
        var plan = try await engine.makePlan(for: task, unlockTimeout: .zero, events: { _ in })
        if let limit { plan = plan.limited(to: limit) }
        let summary = try await engine.execute(plan, confirmed: true, photos: step ?? photos.map { .add($0) }, events: { _ in })
        await engine.close(plan)
        return summary
    }

    func files() throws -> [String] {
        // The temp folder is under /var, a symlink to /private/var; compare resolved paths.
        let base = root.resolvingSymlinksInPath().path
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        return (enumerator?.allObjects as? [URL] ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map { String($0.resolvingSymlinksInPath().path.dropFirst(base.count + 1)) }
            .filter { !$0.hasPrefix(".unroll/") }
            .sorted()
    }

    func index() throws -> SQLiteIndex {
        try #require(try SQLiteIndex.openExisting(destinationRoot: root, readOnly: false))
    }

    var partialFiles: [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: root.appending(path: ".unroll/partial"), includingPropertiesForKeys: nil
        )) ?? []
    }

    // June 2026 clock time.
    let june = Int64(1_780_393_586)

    @Test func copiesVerifiesAndRecords() async throws {
        session.items = [item("1", "IMG_1.HEIC", date: june), item("2", "IMG_2.MOV", date: june, kind: .video)]
        let summary = try await run()

        #expect(summary.imported == 2)
        #expect(try files() == ["2026/2026-06/IMG_1.HEIC", "2026/2026-06/IMG_2.MOV"])
        let copied = try Data(contentsOf: root.appending(path: "2026/2026-06/IMG_1.HEIC"))
        #expect(copied == FakeDeviceSession.bytes(for: session.items[0]))
        #expect(try index().importedKeys() == ImportedKeys(exact: Set(session.items.compactMap(ItemKey.init))))
        #expect(try index().pendingTransfers().isEmpty)
        #expect(partialFiles.isEmpty)
    }

    @Test func writesKeyIntoExtendedAttributes() async throws {
        session.items = [item("1", "IMG_1.HEIC", date: june)]
        try await run()
        let path = root.appending(path: "2026/2026-06/IMG_1.HEIC").path
        var buffer = [UInt8](repeating: 0, count: 64)
        let length = getxattr(path, UnrollAttribute.captureDate, &buffer, buffer.count, 0, 0)
        #expect(String(decoding: buffer.prefix(max(length, 0)), as: UTF8.self) == "2026-06-02 09:46:26")
    }

    @Test func secondRunCopiesNothing() async throws {
        session.items = [item("1", "IMG_1.HEIC", date: june)]
        try await run()
        let plan = try await engine.makePlan(for: sampleTask(), unlockTimeout: .zero, events: { _ in })
        #expect(plan.items.isEmpty)
        #expect(plan.summary.alreadyImported == 1)
    }

    /// An existing file is never replaced; the Live Photo pair moves to the same new suffix.
    @Test func collisionKeepsLivePhotoNamesTogether() async throws {
        let folder = root.appending(path: "2026/2026-06")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("someone else's file".utf8).write(to: folder.appending(path: "IMG_1.HEIC"))
        session.items = [
            item("1", "IMG_1.HEIC", date: june, asset: "A"),
            item("2", "IMG_1.MOV", date: june, kind: .video, role: .livePhotoVideo, asset: "A", parent: "1"),
        ]
        try await run()

        #expect(try files() == ["2026/2026-06/IMG_1 (1).HEIC", "2026/2026-06/IMG_1 (1).MOV", "2026/2026-06/IMG_1.HEIC"])
        #expect(try String(contentsOf: folder.appending(path: "IMG_1.HEIC"), encoding: .utf8) == "someone else's file")
    }

    /// iPhone numbers repeat: a different photo with the same name gets a suffix.
    @Test func repeatedFilenameGetsSuffix() async throws {
        session.items = [item("1", "IMG_0398.HEIC", date: june, size: 500)]
        try await run()
        session.items = [item("1", "IMG_0398.HEIC", date: june + 3600, size: 700)]
        try await run()
        #expect(try files() == ["2026/2026-06/IMG_0398 (1).HEIC", "2026/2026-06/IMG_0398.HEIC"])
    }

    /// Without folders, everything lands in the destination itself; repeated names get a suffix.
    @Test func noFoldersCopiesIntoTheRoot() async throws {
        session.items = [item("1", "IMG_0398.HEIC", date: june, size: 500), item("2", "IMG_2.MOV", date: june, kind: .video)]
        try await run(folders: .none)
        session.items = [item("1", "IMG_0398.HEIC", date: june + 86_400 * 400, size: 700)]
        try await run(folders: .none)
        #expect(try files() == ["IMG_0398 (1).HEIC", "IMG_0398.HEIC", "IMG_2.MOV"])
    }

    /// Own camera into the structure, everything else into Other/YYYY; a Live Photo's video
    /// follows its photo even though the video is checked on its own.
    @Test func separatesOwnCameraFromOther() async throws {
        let cameras = FakeCameraModels([
            "IMG_1.HEIC": "iPhone 15 Pro", "IMG_3.HEIC": "iPhone 12", "IMG_4.MOV": "iPhone 15 Pro ",
        ])
        session.items = [
            item("1", "IMG_1.HEIC", date: june, asset: "A"),
            item("2", "IMG_1.MOV", date: june, kind: .video, role: .livePhotoVideo, asset: "A", parent: "1"),
            item("3", "IMG_2.PNG", date: june),
            item("4", "IMG_3.HEIC", date: june),
            item("5", "IMG_4.MOV", date: june, kind: .video),
        ]
        try await runSeparating(cameras: cameras, models: ["iPhone 15 Pro"], folders: .default)
        #expect(try files() == [
            "2026/2026-06/IMG_1.HEIC", "2026/2026-06/IMG_1.MOV", "2026/2026-06/IMG_4.MOV",
            "Other/2026/IMG_2.PNG", "Other/2026/IMG_3.HEIC",
        ])
    }

    @Test func otherIsFlatWithoutFolders() async throws {
        session.items = [item("1", "IMG_1.HEIC", date: june), item("2", "IMG_2.PNG", date: june)]
        try await runSeparating(cameras: FakeCameraModels(["IMG_1.HEIC": "iPhone 15 Pro"]), models: ["iPhone 15 Pro"], folders: .none)
        #expect(try files() == ["IMG_1.HEIC", "Other/IMG_2.PNG"])
    }

    func runSeparating(cameras: FakeCameraModels, models: [String], folders: FolderTemplate) async throws {
        let destination = ResolvedDestination(root: root, volumeName: "Test", kind: .external, format: "APFS", isReadOnly: false)
        let engine = SyncEngine(
            devices: FakeDeviceBrowser(devices: [phone], session: session), destinations: FakeDestinations(resolved: destination),
            indexes: SQLiteIndexProvider(), writers: DestinationStoreOpener(), cameras: cameras
        )
        let task = sampleTask(folders: folders, cameraModels: models)
        let plan = try await engine.makePlan(for: task, unlockTimeout: .zero, events: { _ in })
        _ = try await engine.execute(plan, confirmed: true, events: { _ in })
        await engine.close(plan)
    }

    /// Deleted on the iPhone after copying: reported, kept. Deleted from the destination too: not reported.
    @Test func reportsFilesNoLongerOnTheDevice() async throws {
        session.items = [
            item("1", "IMG_1.HEIC", date: june), item("2", "IMG_2.HEIC", date: june + 60), item("3", "IMG_3.HEIC", date: june + 120),
        ]
        try await run()
        try FileManager.default.removeItem(at: root.appending(path: "2026/2026-06/IMG_3.HEIC"))
        session.items = [item("1", "IMG_1.HEIC", date: june)]

        let plan = try await engine.makePlan(for: sampleTask(), unlockTimeout: .zero, events: { _ in })
        await engine.close(plan)
        #expect(plan.summary.goneFromDevice == 1)
        #expect(plan.goneFromDevice == ["2026/2026-06/IMG_2.HEIC"])
        #expect(try files().contains("2026/2026-06/IMG_2.HEIC"))
    }

    @Test func identicalContentIsRecordedAsAlias() async throws {
        let same = Data(repeating: 7, count: 1_000)
        session.items = [item("1", "IMG_1.HEIC", date: june), item("2", "IMG_9.HEIC", date: june + 60)]
        session.contents = ["1": same, "2": same]
        let summary = try await run()

        #expect(summary.imported == 1)
        #expect(summary.duplicates == 1)
        #expect(try files() == ["2026/2026-06/IMG_1.HEIC"])
        // Both keys count as imported, so the duplicate isn't downloaded again.
        #expect(try index().importedKeys().count == 2)
        #expect(partialFiles.isEmpty)
    }

    @Test func truncatedDownloadIsNotRecordedAndRetriedNextRun() async throws {
        session.items = [item("1", "IMG_1.HEIC", date: june)]
        session.truncate = ["1": 10]
        let first = try await run()
        #expect(first.failed.map(\.reason) == [.incomplete(expected: 1_000, actual: 990)])
        #expect(try files().isEmpty)
        #expect(try index().importedKeys().isEmpty)
        #expect(partialFiles.isEmpty)

        session.truncate = [:]
        let second = try await run()
        #expect(second.imported == 1)
    }

    @Test func disconnectStopsRunWithoutRecordingTheInterruptedItem() async throws {
        session.items = [item("1", "IMG_1.HEIC", date: june), item("2", "IMG_2.HEIC", date: june), item("3", "IMG_3.HEIC", date: june)]
        session.downloadErrors = ["2": .disconnected]
        let summary = try await run()

        #expect(summary.imported == 1)
        #expect(summary.failed.map(\.reason) == [.deviceDisconnected])
        #expect(summary.notAttempted == 1)
        #expect(summary.stoppedBecause == .deviceNotConnected(name: "Test iPhone"))
        #expect(try index().importedKeys() == [ItemKey(session.items[0])!])
        #expect(try index().pendingTransfers().isEmpty)
    }

    /// Photos copied earlier without unroll (e.g. with Image Capture): no index, no attributes.
    @Test func filesAlreadyInFolderWithoutIndexAreNotCopiedAgain() async throws {
        let existing = item("1", "IMG_1.HEIC", date: june)
        let folder = root.appending(path: "Imported with Image Capture")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "IMG_1.HEIC")
        try FakeDeviceSession.bytes(for: existing).write(to: file)
        // Image Capture sets the file date to the capture time; there's no EXIF in the fake bytes.
        try FileManager.default.setAttributes(
            [.modificationDate: existing.captureDate!.date(in: .current)], ofItemAtPath: file.path
        )
        session.items = [existing, item("2", "IMG_2.HEIC", date: june + 60)]
        let destination = ResolvedDestination(root: root, volumeName: "Test", kind: .external, format: "APFS", isReadOnly: false)
        let engine = SyncEngine(
            devices: FakeDeviceBrowser(devices: [phone], session: session), destinations: FakeDestinations(resolved: destination),
            indexes: SQLiteIndexProvider(), writers: DestinationStoreOpener(), existing: ExistingFilesScanner()
        )

        let plan = try await engine.makePlan(for: sampleTask(), unlockTimeout: .zero, events: { _ in })
        #expect(plan.summary.existingFiles == 1)
        #expect(plan.items.map(\.item.filename) == ["IMG_2.HEIC"])
        // A dry run writes nothing.
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: ".unroll").path))

        let summary = try await engine.execute(plan, confirmed: true, events: { _ in })
        await engine.close(plan)
        #expect(summary.imported == 1)
        #expect(try files() == ["2026/2026-06/IMG_2.HEIC", "Imported with Image Capture/IMG_1.HEIC"])
        // Both are now in the index; the next run finds nothing new.
        #expect(try index().importedKeys().count == 2)
        let next = try await engine.makePlan(for: sampleTask(), unlockTimeout: .zero, events: { _ in })
        #expect(next.items.isEmpty)
        await engine.close(next)
    }

    @Test func rebuiltIndexRecognizesEverythingAgain() async throws {
        let folder = root.appending(path: "2026/2026-06")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("someone else's file".utf8).write(to: folder.appending(path: "IMG_1.HEIC"))
        session.items = [
            item("1", "IMG_1.HEIC", date: june, asset: "A"),
            item("2", "IMG_1.MOV", date: june, kind: .video, role: .livePhotoVideo, asset: "A", parent: "1"),
            item("3", "IMG_2.HEIC", date: june + 60),
        ]
        try await run()
        let filesBefore = try files()
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: SQLiteIndex.url(forDestinationRoot: root).path + suffix)
        }

        let destination = ResolvedDestination(root: root, volumeName: "Test", kind: .external, format: "APFS", isReadOnly: false)
        let result = try await IndexRebuilder().rebuild(destination: destination) { _, _ in }

        // The foreign IMG_1.HEIC has no attributes and is indexed by its file date; the rest exactly.
        #expect(result.files == 4)
        #expect(result.fromAttributes == 3)
        #expect(try files() == filesBefore)
        let plan = try await engine.makePlan(for: sampleTask(), unlockTimeout: .zero, events: { _ in })
        #expect(plan.items.isEmpty)
        #expect(plan.summary.alreadyImported == 3)
        await engine.close(plan)
    }

    /// Indexing before the first copy reuses what the preview read, unless the file changed since.
    @Test func indexingReusesKeysFromTheScan() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 100).write(to: root.appending(path: "IMG_1.HEIC"))
        try Data(repeating: 2, count: 100).write(to: root.appending(path: "IMG_2.HEIC"))
        let scanned = await ExistingFilesScanner().scan(in: root) { _, _ in }
        #expect(scanned.count == 2)
        #expect(scanned.files.map(\.relativePath) == ["IMG_1.HEIC", "IMG_2.HEIC"])

        // A key the scan "read" that differs from what reading again would give shows it was reused.
        let marked = ItemKey(captureDate: LocalTimestamp(secondsSince1970: june), size: 100, filename: "IMG_1.HEIC")
        let known = [ExistingFile(relativePath: "IMG_1.HEIC", key: marked, dateSource: "metadata")]
            + scanned.files.filter { $0.relativePath == "IMG_2.HEIC" }
        // IMG_2 changed size after the scan, so it is read again.
        try Data(repeating: 2, count: 150).write(to: root.appending(path: "IMG_2.HEIC"))

        let destination = ResolvedDestination(root: root, volumeName: "Test", kind: .external, format: "APFS", isReadOnly: false)
        let indexed = try await ExistingFilesScanner().index(destination, known: known) { _, _ in }
        #expect(indexed == 2)
        let keys = try index().importedKeys()
        #expect(keys.contains(marked))
        #expect(keys.contains(ItemKey(captureDate: scanned.files[1].key.captureDate, size: 150, filename: "IMG_2.HEIC")))
    }

    /// Changing the structure and arranging moves the files, keeps the index right and removes
    /// the emptied folders. A file someone else put at a target name is never replaced.
    @Test func arrangesIndexedFilesIntoANewStructure() async throws {
        session.items = [
            item("1", "IMG_1.HEIC", date: june, asset: "A"),
            item("2", "IMG_1.MOV", date: june, kind: .video, role: .livePhotoVideo, asset: "A", parent: "1"),
            item("3", "IMG_2.HEIC", date: june + 60),
        ]
        try await run()
        try Data("someone else's".utf8).write(to: root.appending(path: "IMG_2.HEIC"))

        let arranger = DestinationArranger(cameras: nil)
        let plan = await arranger.plan(root: root, template: .none, rule: nil) { _, _ in }
        #expect(plan.moves.count == 3)
        let destination = ResolvedDestination(root: root, volumeName: "Test", kind: .external, format: "APFS", isReadOnly: false)
        let result = try await arranger.apply(plan, destination: destination, indexing: { _, _ in }, progress: { _, _ in })

        #expect(result.moved == 3)
        #expect(result.failed.isEmpty)
        #expect(try files() == ["IMG_1.HEIC", "IMG_1.MOV", "IMG_2 (1).HEIC", "IMG_2.HEIC"])
        #expect(try String(contentsOf: root.appending(path: "IMG_2.HEIC"), encoding: .utf8) == "someone else's")
        #expect(result.removedFolders == 2)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "2026").path))
        let journal = try String(contentsOf: try #require(result.journal), encoding: .utf8)
        #expect(journal.contains("2026/2026-06/IMG_2.HEIC\tIMG_2 (1).HEIC"))
        // The index follows: content lookups find the new paths, and nothing is new.
        #expect(try index().path(forHash: FakeDeviceSession.bytes(for: session.items[2]).sha256) == "IMG_2 (1).HEIC")
        let next = try await engine.makePlan(for: sampleTask(folders: .none), unlockTimeout: .zero, events: { _ in })
        #expect(next.items.isEmpty)
        await engine.close(next)
        // Arranging again moves nothing.
        #expect(await arranger.plan(root: root, template: .none, rule: nil) { _, _ in }.moves.isEmpty)
    }

    /// Without an index, arranging builds one first, so the moved files are still known.
    @Test func arrangingAFolderWithoutIndexIndexesItFirst() async throws {
        session.items = [item("1", "IMG_1.HEIC", date: june)]
        try await run()
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: SQLiteIndex.url(forDestinationRoot: root).path + suffix)
        }
        let arranger = DestinationArranger(cameras: nil)
        let plan = await arranger.plan(root: root, template: try FolderTemplate("YYYY"), rule: nil) { _, _ in }
        let destination = ResolvedDestination(root: root, volumeName: "Test", kind: .external, format: "APFS", isReadOnly: false)
        _ = try await arranger.apply(plan, destination: destination, indexing: { _, _ in }, progress: { _, _ in })
        #expect(try files() == ["2026/IMG_1.HEIC"])
        #expect(try index().path(forHash: FakeDeviceSession.bytes(for: session.items[0]).sha256) == "2026/IMG_1.HEIC")
    }

    /// A Photos library kept in the destination is a package; its contents aren't indexed.
    @Test func rebuildSkipsPackagesLikePhotosLibraries() throws {
        let library = root.appending(path: "Test.photoslibrary/originals/0", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: library.appending(path: "ABC.heic"))
        try Data("photo".utf8).write(to: root.appending(path: "IMG_1.HEIC"))
        #expect(IndexRebuilder.mediaFiles(in: root).map(\.lastPathComponent) == ["IMG_1.HEIC"])
    }

    @Test func rebuildStripsCollisionSuffixFromFilesWithoutAttributes() {
        #expect(IndexRebuilder.withoutCollisionSuffix("IMG_1234 (1).HEIC") == "IMG_1234.HEIC")
        #expect(IndexRebuilder.withoutCollisionSuffix("IMG_1234 (12).MOV") == "IMG_1234.MOV")
        #expect(IndexRebuilder.withoutCollisionSuffix("Holiday (2025).JPG") == "Holiday.JPG")
        #expect(IndexRebuilder.withoutCollisionSuffix("IMG_1234.HEIC") == "IMG_1234.HEIC")
    }

    @Test func addsNewFilesToPhotosWithoutEditData() async throws {
        session.items = [
            item("1", "IMG_1.HEIC", date: june, asset: "A"),
            item("2", "IMG_1.MOV", date: june, kind: .video, role: .livePhotoVideo, asset: "A", parent: "1"),
            item("3", "IMG_1.AAE", date: june, kind: .other, role: .sidecar, asset: "A", parent: "1"),
            item("4", "IMG_2.HEIC", date: june + 60),
        ]
        let photos = FakePhotos()
        let summary = try await run(versions: .originalWithEdits, photos: photos)

        #expect(summary.imported == 4)
        #expect(summary.photos?.added == 3)
        #expect(photos.batches == [["IMG_1.HEIC", "IMG_1.MOV", "IMG_2.HEIC"]])
        #expect(try index().pendingPhotosImports().isEmpty)
    }

    /// A denied Automation permission leaves the files pending; the next run adds them.
    @Test func deniedPhotosAccessIsRetriedNextRun() async throws {
        session.items = [item("1", "IMG_1.HEIC", date: june)]
        let photos = FakePhotos()
        photos.error = .notAuthorized
        let first = try await run(photos: photos)
        #expect(first.imported == 1)
        #expect(first.photos?.error == .notAuthorized)
        #expect(first.photos?.pending == 1)
        #expect(try index().pendingPhotosImports() == ["2026/2026-06/IMG_1.HEIC"])

        photos.error = nil
        session.items.append(item("2", "IMG_2.HEIC", date: june + 60))
        let second = try await run(photos: photos)
        #expect(second.photos?.added == 2)
        #expect(Set(photos.batches.flatMap { $0 }) == ["IMG_1.HEIC", "IMG_2.HEIC"])
        #expect(try index().pendingPhotosImports().isEmpty)
    }

    /// With Photos switched off in Settings, files are remembered and added once it's back on.
    @Test func photosSwitchedOffRemembersFilesForLater() async throws {
        session.items = [item("1", "IMG_1.HEIC", date: june)]
        let first = try await run(step: .later)
        #expect(first.photos?.deferred == true)
        #expect(first.photos?.pending == 1)

        let photos = FakePhotos()
        session.items.append(item("2", "IMG_2.HEIC", date: june + 60))
        let second = try await run(photos: photos)
        #expect(second.photos?.added == 2)
        #expect(try index().pendingPhotosImports().isEmpty)
    }

    @Test func withoutPhotosOptionNothingIsSent() async throws {
        session.items = [item("1", "IMG_1.HEIC", date: june)]
        let summary = try await run()
        #expect(summary.photos == nil)
        #expect(try index().pendingPhotosImports().isEmpty)
    }

    @Test func limitKeepsLivePhotoPairsTogether() async throws {
        session.items = [
            item("1", "IMG_1.HEIC", date: june, asset: "A"),
            item("2", "IMG_1.MOV", date: june, kind: .video, role: .livePhotoVideo, asset: "A", parent: "1"),
            item("3", "IMG_2.HEIC", date: june),
        ]
        let summary = try await run(limit: 1)
        #expect(summary.imported == 2)
        #expect(try files() == ["2026/2026-06/IMG_1.HEIC", "2026/2026-06/IMG_1.MOV"])
    }
}

/// Crashes at each step of a transfer, simulated directly against the store.
struct RecoveryTests {
    let destination: ResolvedDestination
    let key = ItemKey(captureDate: LocalTimestamp(secondsSince1970: 1_780_393_586), size: 4, filename: "IMG_1.HEIC")

    init() throws {
        destination = ResolvedDestination(
            root: try temporaryDirectory(), volumeName: "Test", kind: .external, format: "APFS", isReadOnly: false
        )
    }

    func indexed(_ hash: Data) -> IndexedItem {
        IndexedItem(
            key: key, relativePath: "2026/2026-06/IMG_1.HEIC", sha256: hash, role: .original, assetID: nil,
            deviceID: phone.id, originalFilename: nil, importedAt: Date()
        )
    }

    @Test func crashDuringDownloadIsDiscarded() throws {
        do {
            let store = try DestinationStore(destination: destination)
            try store.beginTransfer(tempName: "t-IMG_1.HEIC", key: key)
            try Data("half".utf8).write(to: store.partialDirectory.appending(path: "t-IMG_1.HEIC"))
        } // The process "dies" here: the store is gone without finishing.

        let store = try DestinationStore(destination: destination)
        #expect(try store.recoverInterrupted() == RecoveryResult(committed: 0, discarded: 1))
        #expect(try store.importedKeys().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.partialDirectory.path).isEmpty)
    }

    @Test func crashAfterMoveBeforeRecordIsCommitted() throws {
        do {
            let store = try DestinationStore(destination: destination)
            try store.beginTransfer(tempName: "t-IMG_1.HEIC", key: key)
            let temp = store.partialDirectory.appending(path: "t-IMG_1.HEIC")
            try Data("done".utf8).write(to: temp)
            let item = indexed(try store.hash(of: temp))
            let index = try #require(try SQLiteIndex.openExisting(destinationRoot: destination.root, readOnly: false))
            try index.setPendingTarget(tempName: "t-IMG_1.HEIC", item: item)
            let target = destination.root.appending(path: item.relativePath)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: temp, to: target)
        } // Dies between the move and recording it.

        let store = try DestinationStore(destination: destination)
        #expect(try store.recoverInterrupted() == RecoveryResult(committed: 1, discarded: 0))
        #expect(try store.importedKeys() == [key])
    }

    @Test func crashAfterJournalBeforeMoveIsDiscarded() throws {
        do {
            let store = try DestinationStore(destination: destination)
            try store.beginTransfer(tempName: "t-IMG_1.HEIC", key: key)
            let temp = store.partialDirectory.appending(path: "t-IMG_1.HEIC")
            try Data("done".utf8).write(to: temp)
            let index = try #require(try SQLiteIndex.openExisting(destinationRoot: destination.root, readOnly: false))
            try index.setPendingTarget(tempName: "t-IMG_1.HEIC", item: indexed(try store.hash(of: temp)))
        } // Dies before the move: the target doesn't exist.

        let store = try DestinationStore(destination: destination)
        #expect(try store.recoverInterrupted() == RecoveryResult(committed: 0, discarded: 1))
        #expect(try store.importedKeys().isEmpty)
    }

    @Test func secondWriterIsRejectedWhileFirstIsOpen() throws {
        let first = try DestinationStore(destination: destination)
        #expect(throws: SyncError.destinationBusy) { try DestinationStore(destination: destination) }
        _ = first
    }
}

extension Data {
    var sha256: Data { Data(SHA256.hash(data: self)) }
}
