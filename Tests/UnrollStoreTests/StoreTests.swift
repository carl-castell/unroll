import Foundation
import Testing
import UnrollCore
@testable import UnrollStore

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "unroll-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct SQLiteIndexTests {
    func indexed(_ name: String, date: Int64 = 1_780_393_586, size: Int64 = 100) -> IndexedItem {
        IndexedItem(
            key: ItemKey(captureDate: LocalTimestamp(secondsSince1970: date), size: size, filename: name),
            relativePath: "2026/2026-06/\(name)", sha256: Data(repeating: 1, count: 32), role: .original,
            assetID: "A", deviceID: DeviceID("phone"), originalFilename: name, importedAt: Date()
        )
    }

    @Test func missingIndexIsNilAndNotCreated() throws {
        let root = try temporaryDirectory()
        #expect(try SQLiteIndex.openExisting(destinationRoot: root, readOnly: true) == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: ".unroll").path))
    }

    @Test func recordsAndReadsBackKeys() throws {
        let root = try temporaryDirectory()
        let index = try SQLiteIndex.openOrCreate(destinationRoot: root)
        try index.record(indexed("IMG_1.HEIC"))
        try index.record(indexed("IMG_2.HEIC", size: 200))

        let reopened = try #require(try SQLiteIndex.openExisting(destinationRoot: root, readOnly: true))
        #expect(try reopened.importedKeys() == [indexed("IMG_1.HEIC").key, indexed("IMG_2.HEIC", size: 200).key])
        #expect(try reopened.meta().itemCount == 2)
        #expect(try !reopened.meta().indexID.isEmpty)
    }

    @Test func rejectsDuplicateKey() throws {
        let index = try SQLiteIndex.openOrCreate(destinationRoot: try temporaryDirectory())
        try index.record(indexed("IMG_1.HEIC"))
        #expect(throws: SQLiteError.self) { try index.record(indexed("IMG_1.HEIC")) }
    }

    @Test func indexIDSurvivesReopen() throws {
        let root = try temporaryDirectory()
        let first = try SQLiteIndex.openOrCreate(destinationRoot: root).meta().indexID
        let second = try SQLiteIndex.openOrCreate(destinationRoot: root).meta().indexID
        #expect(first == second)
    }
}

struct TaskStoreTests {
    @Test func roundTripsTasks() throws {
        let store = TaskStore(directory: try temporaryDirectory())
        #expect(try store.loadTasks().isEmpty)
        let task = SyncTask(
            name: "iPhone → SSD",
            device: .init(id: DeviceID("phone"), name: "My iPhone"),
            destination: Destination(kind: .local, volumeUUID: "VOL", remountURL: nil, volumeName: "SSD", path: "Photos"),
            folderTemplate: try FolderTemplate("YYYY/MM"),
            versions: .both,
            lastRun: Date(timeIntervalSince1970: 1_780_000_000)
        )
        try store.saveTasks([task])
        #expect(try store.loadTasks() == [task])

        let json = try String(contentsOf: store.tasksURL, encoding: .utf8)
        #expect(json.contains("\"folderTemplate\" : \"YYYY/MM\""))
        #expect(json.contains("\"id\" : \"phone\""))
    }

    @Test func honorsXDGConfigHome() {
        let url = TaskStore.defaultDirectory(environment: ["XDG_CONFIG_HOME": "/tmp/cfg"])
        #expect(url.path == "/tmp/cfg/unroll")
    }

    @Test func rejectsInvalidFolderTemplateInFile() throws {
        let store = TaskStore(directory: try temporaryDirectory())
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let json = """
            {"version": 1, "tasks": [{"id": "6F1C2B1E-0000-0000-0000-000000000000", "name": "x",
              "device": {"id": "p", "name": "p"},
              "destination": {"kind": "local", "volumeUUID": "V", "volumeName": "S", "path": ""},
              "folderTemplate": "../evil", "versions": "original", "addToPhotos": false, "notify": false}]}
            """
        try Data(json.utf8).write(to: store.tasksURL)
        #expect(throws: TaskStoreError.self) { try store.loadTasks() }
    }
}

struct VolumeResolverTests {
    @Test func relativePaths() {
        #expect(VolumeResolver.relativePath(of: "/Volumes/SSD/Photos", onVolumeAt: "/Volumes/SSD") == "Photos")
        #expect(VolumeResolver.relativePath(of: "/Volumes/SSD", onVolumeAt: "/Volumes/SSD/") == "")
        // Firmlinked home folder on the internal data volume.
        #expect(VolumeResolver.relativePath(of: "/Users/me/unroll-test", onVolumeAt: "/System/Volumes/Data") == "Users/me/unroll-test")
    }

    /// A folder in the temporary directory resolves back to the same location.
    @Test func resolvesLocalFolderRoundTrip() throws {
        let folder = try temporaryDirectory().appending(path: "not-yet-created", directoryHint: .isDirectory)
        let resolver = VolumeResolver()
        let destination = try resolver.destination(forFolder: folder)
        #expect(destination.kind == .local)
        #expect(destination.volumeUUID != nil)
        let resolved = try #require(resolver.resolve(destination))
        #expect(resolved.root.resolvingSymlinksInPath().path.hasSuffix(folder.resolvingSymlinksInPath().path))
    }
}
