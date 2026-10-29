import Foundation

public enum Check: String, Sendable {
    case destination, device
}

public enum SyncError: Error, Sendable, Equatable {
    case destinationNotConnected(volumeName: String)
    case destinationReadOnly(volumeName: String)
    case destinationBusy
    case destinationUnwritable(String)
    case notEnoughSpace(needed: Int64, available: Int64)
    case deviceNotConnected(name: String)
    case deviceLocked(name: String)
    case deviceFailed(String)
    case indexUnreadable(String)
    /// The plan needs confirmation (see `ConfirmationPolicy`) and `execute` wasn't told it was given.
    case confirmationRequired(ConfirmationReason)
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
    case recovered(RecoveryResult)
    case transferStarted(totalItems: Int, totalBytes: Int64)
    case fileStarted(PlannedItem, index: Int)
    /// Bytes received so far for this file.
    case fileProgress(PlannedItem, bytes: Int64)
    case fileDone(PlannedItem, FileOutcome)
    case fileFailed(PlannedItem, ItemFailure)
    case finished(SyncSummary)
}

public typealias EventSink = @Sendable (SyncEvent) -> Void

public struct SyncEngine: Sendable {
    let devices: any DeviceBrowsing
    let destinations: any DestinationResolving
    let indexes: any IndexProviding
    let writers: any DestinationOpening

    public init(
        devices: any DeviceBrowsing,
        destinations: any DestinationResolving,
        indexes: any IndexProviding,
        writers: any DestinationOpening
    ) {
        self.devices = devices
        self.destinations = destinations
        self.indexes = indexes
        self.writers = writers
    }

    /// Checks the destination, then the device, lists the device and compares against the index.
    /// Writes nothing. The plan keeps the device session open for `execute`; call `close(_:)` when done.
    public func makePlan(
        for task: SyncTask, unlockTimeout: Duration, events: @escaping EventSink
    ) async throws(SyncError) -> SyncPlan {
        let destination = try checkDestination(for: task, events: events)
        let session = try await connectDevice(for: task, unlockTimeout: unlockTimeout, events: events)
        return try await plan(for: task, destination: destination, session: session, events: events)
    }

    /// Step 1: the destination's volume is mounted (matched by UUID or network address) and writable.
    public func checkDestination(for task: SyncTask, events: EventSink) throws(SyncError) -> ResolvedDestination {
        events(.checkStarted(.destination))
        guard let destination = destinations.resolve(task.destination) else {
            throw fail(.destination, .destinationNotConnected(volumeName: task.destination.volumeName), events)
        }
        if destination.isReadOnly {
            throw fail(.destination, .destinationReadOnly(volumeName: destination.volumeName), events)
        }
        events(.checkPassed(.destination, detail: destination.volumeName))
        return destination
    }

    /// Step 2: the task's device is connected, unlocked and trusts this Mac.
    public func connectDevice(
        for task: SyncTask, unlockTimeout: Duration, events: EventSink
    ) async throws(SyncError) -> any DeviceSession {
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
        return session
    }

    /// Step 3: list the device and compare with the destination's index. Closes the session on failure.
    public func plan(
        for task: SyncTask, destination: ResolvedDestination, session: any DeviceSession, events: @escaping EventSink
    ) async throws(SyncError) -> SyncPlan {
        events(.listingStarted)
        let items: [DeviceItem]
        do {
            items = try await session.listItems { events(.listingProgress(percent: $0)) }
        } catch {
            await session.close()
            throw Self.syncError(error, deviceName: task.device.name)
        }
        events(.itemsListed(count: items.count))

        let importedKeys: ImportedKeys
        let meta: IndexMeta?
        do {
            let index = try indexes.existingIndex(at: destination.root)
            importedKeys = try index?.importedKeys() ?? []
            meta = try index?.meta()
        } catch {
            await session.close()
            throw .indexUnreadable(String(describing: error))
        }

        let result = PlanBuilder.plan(
            items: items, importedKeys: importedKeys, versions: task.versions, folderTemplate: task.folderTemplate
        )
        events(.comparisonDone(result.summary))
        return SyncPlan(
            taskID: task.id,
            deviceID: task.device.id,
            destination: destination,
            session: session,
            items: result.items,
            unavailable: result.unavailable,
            summary: result.summary,
            confirmation: ConfirmationPolicy.reason(for: task, index: meta, newItems: result.items.count)
        )
    }

    /// Whether a plan can still be executed as is: its device session is open and the destination is
    /// still mounted at the same place. Used before "Run now" after a preview.
    public func isStillValid(_ plan: SyncPlan, for task: SyncTask) async -> Bool {
        guard destinations.resolve(task.destination)?.root == plan.destination.root else { return false }
        return await devices.connectedDevices().contains { $0.id == plan.deviceID }
    }

    /// Releases the plan's device session.
    public func close(_ plan: SyncPlan) async {
        await plan.session.close()
    }

    func fail(_ check: Check, _ error: SyncError, _ events: EventSink) -> SyncError {
        events(.checkFailed(check, error))
        return error
    }

    static func syncError(_ error: DeviceError, deviceName: String) -> SyncError {
        switch error {
        case .notFound, .disconnected: .deviceNotConnected(name: deviceName)
        case .accessRestricted: .deviceLocked(name: deviceName)
        case .sessionFailed(let reason), .downloadFailed(let reason): .deviceFailed(reason)
        }
    }
}
