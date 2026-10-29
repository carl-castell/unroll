import Foundation

/// A device item that will be copied, with its key and target folder.
public struct PlannedItem: Sendable, Equatable {
    public let item: DeviceItem
    public let key: ItemKey
    /// Relative to the destination root, e.g. `2026/2026-06`.
    public let folder: String
}

public struct MonthSummary: Sendable, Equatable {
    public let year: Int
    public let month: Int
    public var count: Int
    public var bytes: Int64
}

public struct PlanSummary: Sendable, Equatable {
    public let newCount: Int
    public let newBytes: Int64
    public let alreadyImported: Int
    /// Not copied because of the task's original/edited setting.
    public let excludedByVersions: Int
    /// Listed by the device but not downloadable, e.g. originals kept only in iCloud.
    public let unavailable: Int
    /// Oldest month first.
    public let months: [MonthSummary]
    /// Target folders, sorted.
    public let folders: [String]
}

/// What a run would copy: the new items after comparing against the index.
public struct SyncPlan: Sendable {
    public let taskID: UUID
    public let deviceID: DeviceID
    public let destination: ResolvedDestination
    /// The session the items were listed in; their IDs are only valid within it.
    let session: any DeviceSession
    public let items: [PlannedItem]
    public let unavailable: [DeviceItem]
    public let summary: PlanSummary

    public var destinationRoot: URL { destination.root }

    /// Keeps the first `count` items, counting a photo and its attached files (Live Photo video,
    /// edit data) as one, so pairs aren't split.
    public func limited(to count: Int) -> SyncPlan {
        let ids = Set(items.map(\.item.deviceItemID))
        var kept: [PlannedItem] = []
        var primaries = 0
        for entry in items {
            if entry.item.parentItemID.map({ !ids.contains($0) }) ?? true {
                guard primaries < count else { break }
                primaries += 1
            }
            kept.append(entry)
        }
        return SyncPlan(
            taskID: taskID, deviceID: deviceID, destination: destination, session: session,
            items: kept, unavailable: unavailable, summary: summary
        )
    }
}

public enum PlanBuilder {
    /// Selects the items to copy: wanted by the version policy, available, and not yet in the index.
    public static func plan(
        items: [DeviceItem],
        importedKeys: Set<ItemKey>,
        versions: VersionPolicy,
        folderTemplate: FolderTemplate
    ) -> (items: [PlannedItem], unavailable: [DeviceItem], summary: PlanSummary) {
        let byID = Dictionary(items.map { ($0.deviceItemID, $0) }, uniquingKeysWith: { first, _ in first })
        let editedAssets = Set(items.filter { $0.role == .edited }.compactMap(\.assetID))

        var planned: [PlannedItem] = []
        var unavailable: [DeviceItem] = []
        var alreadyImported = 0
        var excluded = 0

        for item in items {
            guard isWanted(item, versions: versions, editedAssets: editedAssets, byID: byID) else {
                excluded += 1
                continue
            }
            guard item.size > 0, let key = ItemKey(item), let date = item.captureDate else {
                unavailable.append(item)
                continue
            }
            if importedKeys.contains(key) {
                alreadyImported += 1
                continue
            }
            planned.append(PlannedItem(item: item, key: key, folder: folderTemplate.folder(for: date)))
        }

        var months: [Int: MonthSummary] = [:]
        for entry in planned {
            let c = entry.key.captureDate.components
            let year = c.year ?? 0, month = c.month ?? 0
            months[year * 100 + month, default: MonthSummary(year: year, month: month, count: 0, bytes: 0)].count += 1
            months[year * 100 + month]!.bytes += entry.item.size
        }

        let summary = PlanSummary(
            newCount: planned.count,
            newBytes: planned.reduce(0) { $0 + $1.item.size },
            alreadyImported: alreadyImported,
            excludedByVersions: excluded,
            unavailable: unavailable.count,
            months: months.keys.sorted().map { months[$0]! },
            folders: Set(planned.map(\.folder)).sorted()
        )
        return (planned, unavailable, summary)
    }

    private static func isWanted(
        _ item: DeviceItem, versions: VersionPolicy, editedAssets: Set<String>, byID: [String: DeviceItem]
    ) -> Bool {
        switch item.role {
        case .livePhotoVideo:
            // A Live Photo video goes wherever its photo goes.
            guard let parent = item.parentItemID.flatMap({ byID[$0] }) else { return true }
            return isWanted(parent, versions: versions, editedAssets: editedAssets, byID: byID)
        case .sidecar:
            return versions == .both
        case .edited:
            return versions != .original
        case .original:
            switch versions {
            case .original, .both: return true
            case .edited: return item.assetID.map { !editedAssets.contains($0) } ?? true
            }
        }
    }
}
