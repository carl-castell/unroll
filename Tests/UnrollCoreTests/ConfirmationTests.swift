import Foundation
import Testing
@testable import UnrollCore
import UnrollTestSupport

struct ConfirmationTests {
    let index = IndexMeta(indexID: "index-1", itemCount: 10)

    func confirmedTask() -> SyncTask {
        var task = sampleTask()
        task.confirmation = ConfirmationSnapshot(deviceID: task.device.id, destination: task.destination, indexID: "index-1")
        return task
    }

    @Test func firstRunAsksOnce() {
        #expect(ConfirmationPolicy.reason(for: sampleTask(), index: nil, newItems: 5) == .firstRun)
        #expect(ConfirmationPolicy.reason(for: confirmedTask(), index: index, newItems: 5) == nil)
    }

    @Test func nothingToCopyNeverAsks() {
        #expect(ConfirmationPolicy.reason(for: sampleTask(), index: nil, newItems: 0) == nil)
    }

    @Test func changedDestinationAsksAgain() {
        var task = confirmedTask()
        task.destination.path = "Other"
        #expect(ConfirmationPolicy.reason(for: task, index: index, newItems: 1) == .destinationOrDeviceChanged)
        task = confirmedTask()
        task.destination.volumeUUID = "VOL-2"
        #expect(ConfirmationPolicy.reason(for: task, index: index, newItems: 1) == .destinationOrDeviceChanged)
    }

    /// Volume names are display-only; renaming the drive isn't a change.
    @Test func renamedVolumeDoesNotAsk() {
        var task = confirmedTask()
        task.destination.volumeName = "Renamed SSD"
        #expect(ConfirmationPolicy.reason(for: task, index: index, newItems: 1) == nil)
    }

    @Test func changedDeviceAsksAgain() {
        var task = confirmedTask()
        task.device.id = DeviceID("other-phone")
        #expect(ConfirmationPolicy.reason(for: task, index: index, newItems: 1) == .destinationOrDeviceChanged)
    }

    @Test func rebuiltOrEmptyIndexAsksAgain() {
        #expect(ConfirmationPolicy.reason(for: confirmedTask(), index: IndexMeta(indexID: "index-2", itemCount: 10), newItems: 1) == .indexRebuilt)
        #expect(ConfirmationPolicy.reason(for: confirmedTask(), index: IndexMeta(indexID: "index-1", itemCount: 0), newItems: 1) == .indexEmpty)
        #expect(ConfirmationPolicy.reason(for: confirmedTask(), index: nil, newItems: 1) == .indexEmpty)
    }

    @Test func executeRefusesUnconfirmedPlan() async throws {
        let session = FakeDeviceSession(info: phone, items: [item("1", "IMG_1.HEIC")])
        let engine = SyncEngine(
            devices: FakeDeviceBrowser(devices: [phone], session: session),
            destinations: FakeDestinations(resolved: ssd), indexes: FakeIndexes(index: nil), writers: NoWriters()
        )
        let plan = try await engine.makePlan(for: sampleTask(), unlockTimeout: .zero, events: { _ in })
        #expect(plan.confirmation == .firstRun)
        await #expect(throws: SyncError.confirmationRequired(.firstRun)) {
            try await engine.execute(plan, confirmed: false, events: { _ in })
        }
        #expect(session.downloaded.isEmpty)
    }
}
