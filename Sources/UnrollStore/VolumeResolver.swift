import Foundation
import UnrollCore

/// A mounted volume, as offered when choosing a destination.
public struct Volume: Sendable, Equatable {
    public let url: URL
    public let name: String
    public let uuid: String?
    public let remountURL: String?
    public let kind: VolumeKind
    public let format: String?
    public let isReadOnly: Bool
    public let availableBytes: Int64?
}

public enum VolumeError: Error, Equatable, CustomStringConvertible {
    case noVolume(path: String)
    case noIdentity(volumeName: String)

    public var description: String {
        switch self {
        case .noVolume(let path): "No mounted volume contains \(path)."
        case .noIdentity(let name): "\"\(name)\" has no volume UUID or network address, so it can't be recognized again."
        }
    }
}

/// Finds mounted volumes and resolves task destinations by volume UUID or network address.
public struct VolumeResolver: DestinationResolving {
    /// The writable volume behind the internal disk. Paths like /Users/... live on it
    /// through firmlinks, so they don't start with its mount path.
    static let internalDataVolume = "/System/Volumes/Data"

    private static let keys: [URLResourceKey] = [
        .volumeNameKey, .volumeLocalizedNameKey, .volumeUUIDStringKey, .volumeURLForRemountingKey,
        .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsReadOnlyKey, .volumeLocalizedFormatDescriptionKey,
        .volumeAvailableCapacityForImportantUsageKey, .volumeIsBrowsableKey,
    ]

    public init() {}

    /// All mounted volumes a user could choose, external first, then network, then internal.
    public func mountedVolumes() -> [Volume] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Self.keys, options: []) ?? []
        let volumes = urls.compactMap(Self.volume(at:)).filter { volume in
            // Hide the sealed system volume and other internal helper volumes, except the data volume.
            volume.kind != .internal || volume.url.path == Self.internalDataVolume || volume.url.path == "/"
        }
        let order: [VolumeKind] = [.external, .network, .internal]
        return volumes.sorted { order.firstIndex(of: $0.kind)! < order.firstIndex(of: $1.kind)! }
    }

    public func resolve(_ destination: Destination) -> ResolvedDestination? {
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Self.keys, options: [])?
            .compactMap(Self.volume(at:)) ?? []
        let match = volumes.first { volume in
            switch destination.kind {
            case .local: destination.volumeUUID != nil && volume.uuid == destination.volumeUUID
            case .network: destination.remountURL != nil && volume.remountURL == destination.remountURL
            }
        }
        guard let match else { return nil }
        return ResolvedDestination(
            root: match.url.appending(path: destination.path, directoryHint: .isDirectory),
            volumeName: match.name,
            kind: match.kind,
            format: match.format,
            isReadOnly: match.isReadOnly
        )
    }

    /// Builds a destination for a folder. The folder doesn't need to exist yet.
    public func destination(forFolder folder: URL) throws -> Destination {
        let folder = folder.standardizedFileURL.resolvingSymlinksInPath()
        var existing = folder
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            existing = existing.deletingLastPathComponent()
        }
        guard let volumeURL = try? existing.resourceValues(forKeys: [.volumeURLKey]).volume,
              let volume = Self.volume(at: volumeURL) else {
            throw VolumeError.noVolume(path: folder.path)
        }

        let path = Self.relativePath(of: folder.path, onVolumeAt: volume.url.path)
        if volume.kind == .network {
            guard let remount = volume.remountURL else { throw VolumeError.noIdentity(volumeName: volume.name) }
            return Destination(kind: .network, volumeUUID: volume.uuid, remountURL: remount, volumeName: volume.name, path: path)
        }
        guard let uuid = volume.uuid else { throw VolumeError.noIdentity(volumeName: volume.name) }
        return Destination(kind: .local, volumeUUID: uuid, remountURL: nil, volumeName: volume.name, path: path)
    }

    /// Shortens /System/Volumes/Data/Users/... to /Users/... for display.
    public static func displayPath(_ url: URL) -> String {
        let path = url.path
        return path.hasPrefix(internalDataVolume + "/") ? String(path.dropFirst(internalDataVolume.count)) : path
    }

    static func relativePath(of path: String, onVolumeAt mountPath: String) -> String {
        let mount = mountPath.hasSuffix("/") ? String(mountPath.dropLast()) : mountPath
        if mount.isEmpty { return String(path.drop { $0 == "/" }) }
        if path == mount { return "" }
        if path.hasPrefix(mount + "/") { return String(path.dropFirst(mount.count + 1)) }
        // Firmlinked path on the internal data volume (e.g. /Users/...).
        return String(path.drop { $0 == "/" })
    }

    private static func volume(at url: URL) -> Volume? {
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        let kind: VolumeKind = if values.volumeIsLocal == false {
            .network
        } else if values.volumeIsInternal == true {
            .internal
        } else {
            .external
        }
        return Volume(
            url: url,
            name: values.volumeLocalizedName ?? values.volumeName ?? url.lastPathComponent,
            uuid: values.volumeUUIDString,
            remountURL: values.volumeURLForRemounting?.absoluteString,
            kind: kind,
            format: values.volumeLocalizedFormatDescription,
            isReadOnly: values.volumeIsReadOnly ?? false,
            availableBytes: values.volumeAvailableCapacityForImportantUsage
        )
    }
}
