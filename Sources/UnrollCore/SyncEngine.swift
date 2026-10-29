import Foundation

public enum Check: String, Sendable {
    case destination, device
}

public enum SyncError: Error, Sendable, Equatable {
    case destinationNotConnected(volumeName: String)
    case destinationReadOnly(volumeName: String)
    case deviceNotConnected(name: String)
    case deviceLocked(name: String)
    case deviceFailed(String)
    case indexUnreadable(String)
}

/// Progress reported by the core. Interfaces decide how to show it; the core never prints.
public enum SyncEvent: Sendable {
    case checkStarted(Check)
    case checkPassed(Check, detail: String)
    case checkFailed(Check, SyncError)
    case listingStarted
    case listingProgress(percent: Int)
    case itemsListed(count: Int)
    case comparisonDone(PlanSummary)
}

public typealias EventSink = @Sendable (SyncEvent) -> Void

public struct SyncEngine: Sendable {
    private let devices: any DeviceBrowsing
    private let destinations: any DestinationResolving
    private let indexes: any IndexProviding

    public init(devices: any DeviceBrowsing, destinations: any DestinationResolving, indexes: any IndexProviding) {
        self.devices = devices
        self.destinations = destinations
        self.indexes = indexes
    }

    /// Checks the destination, then the device, lists the device and compares against the index.
    /// Reads only; nothing is written anywhere.
    public func makePlan(
        for task: SyncTask, unlockTimeout: Duration, events: @escaping EventSink
    ) async throws(SyncError) -> SyncPlan {
        events(.checkStarted(.destination))
        guard let destination = destinations.resolve(task.destination) else {
            throw fail(.destination, .destinationNotConnected(volumeName: task.destination.volumeName), events)
        }
        if destination.isReadOnly {
            throw fail(.destination, .destinationReadOnly(volumeName: destination.volumeName), events)
        }
        events(.checkPassed(.destination, detail: destination.volumeName))

        events(.checkStarted(.device))
        guard await devices.connectedDevices().contains(where: { $0.id == task.device.id }) else {
            throw fail(.device, .deviceNotConnected(name: task.device.name), events)
        }
        let session: any DeviceSession
        do {
            session = try await devices.open(task.device.id, unlockTimeout: unlockTimeout)
        } catch {
            throw fail(.device, Self.syncError(error, deviceName: task.device.name), events)
        }
        events(.checkPassed(.device, detail: session.info.name))

        events(.listingStarted)
        let items: [DeviceItem]
        do {
            items = try await session.listItems { events(.listingProgress(percent: $0)) }
        } catch {
            await session.close()
            throw Self.syncError(error, deviceName: task.device.name)
        }
        await session.close()
        events(.itemsListed(count: items.count))

        let importedKeys: Set<ItemKey>
        do {
            importedKeys = try indexes.existingIndex(at: destination.root)?.importedKeys() ?? []
        } catch {
            throw .indexUnreadable(String(describing: error))
        }

        let result = PlanBuilder.plan(
            items: items, importedKeys: importedKeys, versions: task.versions, folderTemplate: task.folderTemplate
        )
        events(.comparisonDone(result.summary))
        return SyncPlan(
            taskID: task.id,
            deviceID: task.device.id,
            destinationRoot: destination.root,
            items: result.items,
            unavailable: result.unavailable,
            summary: result.summary
        )
    }

    private func fail(_ check: Check, _ error: SyncError, _ events: EventSink) -> SyncError {
        events(.checkFailed(check, error))
        return error
    }

    private static func syncError(_ error: DeviceError, deviceName: String) -> SyncError {
        switch error {
        case .notFound, .disconnected: .deviceNotConnected(name: deviceName)
        case .accessRestricted: .deviceLocked(name: deviceName)
        case .sessionFailed(let reason): .deviceFailed(reason)
        }
    }
}
