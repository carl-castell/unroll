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
            // A locked or untrusted iPhone refuses the session, so wait for the restriction to lift first.
            while camera.isAccessRestrictedAppleDevice {
                guard ContinuousClock.now < deadline else {
                    throw .accessRestricted(name: info.name)
                }
                try await pause(.milliseconds(250))
            }
            do {
                try await camera.requestOpenSession()
                return
            } catch {
                // The restriction flag can lag behind the device state; retry until the deadline.
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

    static func items(for file: ICCameraFile) -> [DeviceItem] {
        let main = DeviceItem(
            deviceItemID: itemID(file),
            originalFilename: file.originalFilename ?? file.name ?? itemID(file),
            // Capture-date source is still being validated against real devices (milestone 1).
            captureDate: file.creationDate ?? file.fileCreationDate,
            size: Int64(file.fileSize),
            kind: kind(of: file),
            groupID: file.groupUUID,
            parentItemID: nil
        )
        let sidecars = (file.sidecarFiles ?? []).compactMap { $0 as? ICCameraFile }.map { sidecar in
            DeviceItem(
                deviceItemID: itemID(sidecar),
                originalFilename: sidecar.originalFilename ?? sidecar.name ?? itemID(sidecar),
                captureDate: sidecar.creationDate ?? sidecar.fileCreationDate ?? main.captureDate,
                size: Int64(sidecar.fileSize),
                kind: .sidecar,
                groupID: file.groupUUID,
                parentItemID: main.deviceItemID
            )
        }
        return [main] + sidecars
    }

    static func kind(of file: ICCameraItem) -> MediaKind {
        let type = file.uti.flatMap(UTType.init) ?? (file.name.map { UTType(filenameExtension: ($0 as NSString).pathExtension) } ?? nil)
        guard let type else { return .other }
        if type.conforms(to: .image) { return .photo }
        if type.conforms(to: .audiovisualContent) { return .video }
        if (file.name as NSString?)?.pathExtension.uppercased() == "AAE" { return .sidecar }
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
