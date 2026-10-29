import Foundation
@preconcurrency import ImageCaptureCore
import UniformTypeIdentifiers
import UnrollCore

/// An open, read-only session with one device. Never deletes or modifies anything on it.
@MainActor
public final class ICCDeviceSession: NSObject, DeviceSession {
    public nonisolated let info: DeviceInfo
    private let camera: ICCameraDevice

    private var catalogComplete = false
    private var removed = false

    init(camera: ICCameraDevice, info: DeviceInfo) {
        self.camera = camera
        self.info = info
        super.init()
    }

    func open(unlockTimeout: Duration) async throws(DeviceError) {
        camera.delegate = self
        let deadline = ContinuousClock.now + unlockTimeout
        while true {
            // Requesting the session is what makes an unlocked iPhone show "Trust This Computer?",
            // so ask right away and keep retrying while it is locked or waiting for Trust.
            do {
                try await camera.requestOpenSession()
                return
            } catch {
                guard ContinuousClock.now < deadline else {
                    throw camera.isAccessRestrictedAppleDevice
                        ? .accessRestricted(name: info.name)
                        : .sessionFailed(error.localizedDescription)
                }
                try await pause(.seconds(1))
            }
        }
    }

    public func listItems(progress: @escaping @Sendable (Int) -> Void) async throws(DeviceError) -> [DeviceItem] {
        while !catalogComplete {
            progress(Int(camera.contentCatalogPercentCompleted))
            try await pause(.milliseconds(250))
        }
        progress(100)
        return mediaFiles.flatMap(Self.items(for:))
    }

    public func close() async {
        if camera.hasOpenSession {
            try? await camera.requestCloseSession()
        }
    }

    private var mediaFiles: [ICCameraFile] {
        (camera.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }
    }

    private func pause(_ duration: Duration = .milliseconds(50)) async throws(DeviceError) {
        if removed { throw .disconnected }
        try? await Task.sleep(for: duration)
        if removed { throw .disconnected }
    }

    // MARK: Mapping

    static func itemID(_ item: ICCameraItem) -> String {
        String(item.ptpObjectHandle)
    }

    /// Maps a media file and its attached files. On iPhones, a Live Photo's MOV and any AAE/DAT
    /// edit data arrive as `sidecarFiles` of the photo; edited renderings (IMG_E1234) are separate
    /// media files that share the original's `relatedUUID`.
    static func items(for file: ICCameraFile) -> [DeviceItem] {
        let assetID = file.relatedUUID.map { String($0.prefix { $0 != "/" }) }
        let kind = kind(of: file)
        let main = item(for: file, kind: kind, role: isEdited(file) ? .edited : .original, assetID: assetID, parent: nil)
        let attached = (file.sidecarFiles ?? []).compactMap { $0 as? ICCameraFile }.map { sidecar in
            let sidecarKind = Self.kind(of: sidecar)
            let role: ItemRole = kind == .photo && sidecarKind == .video ? .livePhotoVideo : .sidecar
            return item(for: sidecar, kind: sidecarKind, role: role, assetID: assetID, parent: main)
        }
        return [main] + attached
    }

    private static func item(
        for file: ICCameraFile, kind: MediaKind, role: ItemRole, assetID: String?, parent: DeviceItem?
    ) -> DeviceItem {
        DeviceItem(
            deviceItemID: itemID(file),
            filename: file.name ?? file.originalFilename ?? itemID(file),
            originalFilename: file.originalFilename,
            // ImageCaptureCore reports the photo's local clock time, interpreted in the Mac's time zone.
            captureDate: file.creationDate ?? file.fileCreationDate ?? parent?.captureDate,
            size: Int64(file.fileSize),
            kind: kind,
            role: role,
            assetID: assetID,
            parentItemID: parent?.deviceItemID
        )
    }

    private static func isEdited(_ file: ICCameraFile) -> Bool {
        if file.originalFilename?.lowercased().hasPrefix("fullsizerender") == true { return true }
        return file.name.map { $0.range(of: #"^[A-Z]+_E\d"#, options: .regularExpression) != nil } ?? false
    }

    static func kind(of file: ICCameraItem) -> MediaKind {
        let type = file.uti.flatMap(UTType.init)
            ?? file.name.flatMap { UTType(filenameExtension: ($0 as NSString).pathExtension) }
        guard let type else { return .other }
        if type.conforms(to: .image) { return .photo }
        if type.conforms(to: .audiovisualContent) { return .video }
        return .other
    }
}

// MARK: Diagnostics

extension ICCDeviceSession {
    /// Every date and grouping field ImageCaptureCore reports, for validating which ones to rely on.
    public struct RawFields: Sendable {
        public let name: String?
        public let originalFilename: String?
        public let uti: String?
        public let size: Int64
        public let creationDate: Date?
        public let modificationDate: Date?
        public let fileCreationDate: Date?
        public let exifCreationDate: Date?
        public let groupUUID: String?
        public let relatedUUID: String?
        public let burstUUID: String?
        public let originatingAssetID: String?
        public let fingerprint: String?
        public let sidecars: [String]
    }

    public func rawFields() -> [RawFields] {
        mediaFiles.map { file in
            RawFields(
                name: file.name,
                originalFilename: file.originalFilename,
                uti: file.uti,
                size: Int64(file.fileSize),
                creationDate: file.creationDate,
                modificationDate: file.modificationDate,
                fileCreationDate: file.fileCreationDate,
                exifCreationDate: file.exifCreationDate,
                groupUUID: file.groupUUID,
                relatedUUID: file.relatedUUID,
                burstUUID: file.burstUUID,
                originatingAssetID: file.originatingAssetID,
                fingerprint: file.fingerprint,
                sidecars: (file.sidecarFiles ?? []).compactMap(\.name)
            )
        }
    }

    /// Requests EXIF metadata for the first `limit` files and returns the capture date fields found,
    /// along with how long each request took.
    public func exifSamples(limit: Int) async -> [(name: String, fields: [String: String], duration: Duration)] {
        var results: [(String, [String: String], Duration)] = []
        for file in mediaFiles.prefix(limit) {
            let start = ContinuousClock.now
            let fields: [String: String] = await withCheckedContinuation { continuation in
                file.requestMetadataDictionary(options: nil) { metadata, _ in
                    let exif = metadata?["{Exif}"] as? [String: Any] ?? [:]
                    var found: [String: String] = [:]
                    for key in ["DateTimeOriginal", "OffsetTimeOriginal", "SubsecTimeOriginal"] {
                        if let value = exif[key] { found[key] = "\(value)" }
                    }
                    continuation.resume(returning: found)
                }
            }
            results.append((file.name ?? "?", fields, ContinuousClock.now - start))
        }
        return results
    }
}

extension ICCDeviceSession: @preconcurrency ICCameraDeviceDelegate {
    public func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {}

    public func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {}

    public func didRemove(_ device: ICDevice) {
        removed = true
    }

    public func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        catalogComplete = true
    }

    public func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        // The catalog is sent again once the device unlocks.
        catalogComplete = false
    }

    public func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
    public func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    public func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    public func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    public func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    public func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    public func cameraDevice(
        _ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: (any Error)?
    ) {}
    public func cameraDevice(
        _ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem,
        error: (any Error)?
    ) {}
}
