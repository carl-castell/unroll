import Foundation
import Testing
@testable import UnrollCore
import UnrollTestSupport

struct SyncEngineTests {
    func engine(
        browser: FakeDeviceBrowser, destination: ResolvedDestination? = ssd, index: FakeIndex? = nil
    ) -> SyncEngine {
        SyncEngine(
            devices: browser, destinations: FakeDestinations(resolved: destination), indexes: FakeIndexes(index: index),
            writers: NoWriters()
        )
    }

    @Test func plansNewItemsAndKeepsSessionOpenUntilClosed() async throws {
        let items = [item("1", "IMG_1.HEIC"), item("2", "IMG_2.HEIC")]
        let session = FakeDeviceSession(info: phone, items: items)
        let browser = FakeDeviceBrowser(devices: [phone], session: session)
        let index = FakeIndex(keys: [ItemKey(items[0])!])

        let engine = engine(browser: browser, index: index)
        let plan = try await engine.makePlan(for: sampleTask(), unlockTimeout: .zero, events: { _ in })

        #expect(plan.items.map(\.item.filename) == ["IMG_2.HEIC"])
        #expect(plan.destinationRoot == ssd.root)
        #expect(!session.closed)
        await engine.close(plan)
        #expect(session.closed)
    }

    @Test func missingIndexMeansEverythingIsNew() async throws {
        let session = FakeDeviceSession(info: phone, items: [item("1", "IMG_1.HEIC")])
        let plan = try await engine(browser: FakeDeviceBrowser(devices: [phone], session: session), index: nil)
            .makePlan(for: sampleTask(), unlockTimeout: .zero, events: { _ in })
        #expect(plan.summary.newCount == 1)
    }

    /// The destination is checked first; the device isn't touched when it's missing.
    @Test func missingDestinationFailsBeforeDevice() async {
        let browser = FakeDeviceBrowser(devices: [phone], session: FakeDeviceSession(info: phone, items: []))
        let recorder = EventRecorder()
        await #expect(throws: SyncError.destinationNotConnected(volumeName: "Photos-SSD")) {
            try await engine(browser: browser, destination: nil)
                .makePlan(for: sampleTask(), unlockTimeout: .zero, events: recorder.record)
        }
        #expect(browser.openCalls == 0)
        guard case .checkFailed(.destination, _) = recorder.events.last else {
            Issue.record("expected a failed destination check, got \(recorder.events)")
            return
        }
    }

    @Test func readOnlyDestinationFails() async {
        let readOnly = ResolvedDestination(root: ssd.root, volumeName: "Photos-SSD", kind: .external, format: "APFS", isReadOnly: true)
        await #expect(throws: SyncError.destinationReadOnly(volumeName: "Photos-SSD")) {
            try await engine(browser: FakeDeviceBrowser(), destination: readOnly)
                .makePlan(for: sampleTask(), unlockTimeout: .zero, events: { _ in })
        }
    }

    @Test func disconnectedDeviceFails() async {
        await #expect(throws: SyncError.deviceNotConnected(name: "Test iPhone")) {
            try await engine(browser: FakeDeviceBrowser(devices: []))
                .makePlan(for: sampleTask(), unlockTimeout: .zero, events: { _ in })
        }
    }

    @Test func lockedDeviceFails() async {
        let browser = FakeDeviceBrowser(devices: [phone])
        browser.openError = .accessRestricted(name: "Test iPhone")
        await #expect(throws: SyncError.deviceLocked(name: "Test iPhone")) {
            try await engine(browser: browser).makePlan(for: sampleTask(), unlockTimeout: .zero, events: { _ in })
        }
    }

    @Test func listingFailureClosesSession() async {
        let session = FakeDeviceSession(info: phone, items: [])
        session.listError = .disconnected
        await #expect(throws: SyncError.deviceNotConnected(name: "Test iPhone")) {
            try await engine(browser: FakeDeviceBrowser(devices: [phone], session: session))
                .makePlan(for: sampleTask(), unlockTimeout: .zero, events: { _ in })
        }
        #expect(session.closed)
    }

    @Test func findsTasksByNameOrIDPrefix() {
        let task = sampleTask()
        #expect(SyncTask.find("iphone → ssd", in: [task]) == task)
        #expect(SyncTask.find(String(task.id.uuidString.prefix(6)), in: [task]) == task)
        #expect(SyncTask.find("nope", in: [task]) == nil)
    }
}
