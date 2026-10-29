import Foundation

/// Why a run must be confirmed before copying.
public enum ConfirmationReason: String, Sendable, Equatable {
    case firstRun
    /// The task now points at another device or destination than when it was last confirmed.
    case destinationOrDeviceChanged
    /// The destination's index was rebuilt since the last confirmed run.
    case indexRebuilt
    /// The destination has no index entries, so everything on the device would be copied.
    case indexEmpty
}

/// What a confirmed run was confirmed for. Stored in the task.
public struct ConfirmationSnapshot: Codable, Sendable, Equatable {
    public var deviceID: DeviceID
    public var destination: Destination
    public var indexID: String

    public init(deviceID: DeviceID, destination: Destination, indexID: String) {
        self.deviceID = deviceID
        self.destination = destination
        self.indexID = indexID
    }
}

public enum ConfirmationPolicy {
    /// The first run of a task asks once; later runs don't, unless the task's device or destination
    /// changed, or the destination's index is new, rebuilt or empty. Nothing to copy, nothing to ask.
    public static func reason(for task: SyncTask, index: IndexMeta?, newItems: Int) -> ConfirmationReason? {
        guard newItems > 0 else { return nil }
        guard let confirmed = task.confirmation else { return .firstRun }
        if confirmed.deviceID != task.device.id || !sameLocation(confirmed.destination, task.destination) {
            return .destinationOrDeviceChanged
        }
        guard let index, index.itemCount > 0 else { return .indexEmpty }
        if index.indexID != confirmed.indexID { return .indexRebuilt }
        return nil
    }

    /// Names are display-only; a destination is the same if volume identity and folder match.
    private static func sameLocation(_ a: Destination, _ b: Destination) -> Bool {
        a.kind == b.kind && a.volumeUUID == b.volumeUUID && a.remountURL == b.remountURL && a.path == b.path
    }
}
