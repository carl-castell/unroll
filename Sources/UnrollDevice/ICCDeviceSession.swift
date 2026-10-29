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
    /// The files behind the listed items' `deviceItemID`s.
    private var filesByID: [String: ICCameraFile] = [:]
    private var activeDownload: CheckedContinuation<Result<String, DeviceError>, Never>?
    private var progressTask: Task<Void, Never>?

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
        let timeZone = Self.systemTimeZone()
        filesByID = [:]
        return mediaFiles.flatMap { items(for: $0, timeZone: timeZone) }
    }

    public func download(
        _ item: DeviceItem, to directory: URL, as filename: String, progress: @escaping @Sendable (Int64) -> Void
    ) async throws(DeviceError) -> URL {
        guard let file = filesByID[item.deviceItemID] else {
            throw .downloadFailed("\(item.filename) is no longer listed on the device")
        }
        if removed { throw .disconnected }
        // Read-only: never pass ICDeleteAfterSuccessfulDownload or ICTruncateAfterSuccessfulDownload.
        // Attached files (Live Photo video, AAE) are separate items, so sidecars aren't downloaded here.
        let options: [ICDownloadOption: Any] = [
            .downloadsDirectoryURL: directory,
            .saveAsFilename: filename,
            .overwrite: false,
            .sidecarFiles: false,
        ]
        let size = item.size
        let result: Result<String, DeviceError> = await withCheckedContinuation { continuation in
            activeDownload = continuation
            // ImageCaptureCore calls this on a background queue.
            let transfer = file.requestDownload(options: options) { @Sendable savedName, error in
                let outcome: Result<String, DeviceError> = error.map { .failure(.downloadFailed($0.localizedDescription)) }
                    ?? .success(savedName.map { ($0 as NSString).lastPathComponent } ?? filename)
                Task { @MainActor in self.finishDownload(outcome) }
            }
            if let transfer {
                progressTask = Task { @MainActor in
                    while !Task.isCancelled {
                        progress(Int64(transfer.fractionCompleted * Double(size)))
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                }
            }
        }
        progressTask?.cancel()
        progressTask = nil
        switch result {
        case .success(let name): return directory.appending(path: name)
        case .failure(let error): throw error
        }
    }

    private func finishDownload(_ result: Result<String, DeviceError>) {
        activeDownload?.resume(returning: result)
        activeDownload = nil
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

    /// Maps a media file and its attached files. On iPhones, a Live Photo's MOV and any AAE/DAT
    /// edit data arrive as `sidecarFiles` of the photo; edited renderings (IMG_E1234) are separate
    /// media files that share the original's `relatedUUID`.
    private func items(for file: ICCameraFile, timeZone: TimeZone) -> [DeviceItem] {
        let assetID = file.relatedUUID.map { String($0.prefix { $0 != "/" }) }
        let kind = Self.kind(of: file)
        let role: ItemRole = Self.isEdited(file) ? .edited : .original
        let main = item(for: file, kind: kind, role: role, assetID: assetID, parent: nil, timeZone: timeZone)
        let attached = (file.sidecarFiles ?? []).compactMap { $0 as? ICCameraFile }.map { sidecar in
            let sidecarKind = Self.kind(of: sidecar)
            let role: ItemRole = kind == .photo && sidecarKind == .video ? .livePhotoVideo : .sidecar
            return item(for: sidecar, kind: sidecarKind, role: role, assetID: assetID, parent: main, timeZone: timeZone)
        }
        return [main] + attached
    }

    private func item(
        for file: ICCameraFile, kind: MediaKind, role: ItemRole, assetID: String?, parent: DeviceItem?,
        timeZone: TimeZone
    ) -> DeviceItem {
        // ImageCaptureCore's ptpObjectHandle isn't unique on iPhones, so the session numbers items itself.
        let id = String(filesByID.count + 1)
        filesByID[id] = file
        // ImageCaptureCore reports the photo's clock time interpreted in the Mac's time zone; undo that.
        let date = (file.creationDate ?? file.fileCreationDate).map { LocalTimestamp(date: $0, interpretedIn: timeZone) }
        return DeviceItem(
            deviceItemID: id,
            filename: file.name ?? file.originalFilename ?? "item-\(id)",
            originalFilename: file.originalFilename,
            captureDate: date ?? parent?.captureDate,
            size: Int64(file.fileSize),
            kind: kind,
            role: role,
            assetID: assetID,
            parentItemID: parent?.deviceItemID
        )
    }

    /// The Mac's configured time zone. ImageCaptureCore converts dates in a system service that
    /// uses this zone, so a `TZ` environment variable must not influence the conversion back.
    static func systemTimeZone() -> TimeZone {
        if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: "/etc/localtime"),
           let range = target.range(of: "zoneinfo/"),
           let zone = TimeZone(identifier: String(target[range.upperBound...])) {
            return zone
        }
        return TimeZone.autoupdatingCurrent
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
        // A download in progress never completes once the cable is pulled.
        finishDownload(.failure(.disconnected))
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
