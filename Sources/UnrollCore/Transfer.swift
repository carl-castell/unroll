import Foundation

extension SyncEngine {
    /// Space kept free on the destination beyond the files being copied.
    public static let spaceMargin: Int64 = 100_000_000

    /// Copies the plan's items: download into the destination's temp area, verify size and hash,
    /// move into place without overwriting, and only then record in the index.
    ///
    /// Stops early if the device disconnects (the summary's `stoppedBecause` says why) or the
    /// calling task is cancelled (`cancelled`).
    /// - Parameter confirmed: whether the user confirmed the run. Required when `plan.confirmation` is set;
    ///   the core only signals this, and the interface decides how to ask.
    /// - Parameter photos: when set, what happens with Apple Photos once the files are copied.
    public func execute(
        _ plan: SyncPlan, confirmed: Bool, photos: PhotosStep? = nil, events: @escaping EventSink
    ) async throws(SyncError) -> SyncSummary {
        if let reason = plan.confirmation, !confirmed {
            throw .confirmationRequired(reason)
        }
        let start = ContinuousClock.now
        // Record files already in the folder first, so they aren't copied again or collide.
        try await indexExistingFiles(plan, events: events)
        let writer: any DestinationWriter
        do {
            writer = try writers.openForWriting(plan.destination)
        } catch let error as SyncError {
            throw error
        } catch {
            throw .destinationUnwritable(String(describing: error))
        }

        var summary = SyncSummary()
        summary.unavailable = plan.unavailable.count
        let alreadyImported: ImportedKeys
        do {
            summary.recovered = try writer.recoverInterrupted()
            // Re-read under the destination lock: recovery or another run may have added items since planning.
            alreadyImported = try writer.importedKeys()
        } catch {
            throw .indexUnreadable(String(describing: error))
        }
        if summary.recovered != RecoveryResult(committed: 0, discarded: 0) {
            events(.recovered(summary.recovered))
        }

        let items = plan.items.filter { !alreadyImported.contains($0.key) }
        let totalBytes = items.reduce(Int64(0)) { $0 + $1.item.size }
        if let available = plan.destination.availableBytes, available < totalBytes + Self.spaceMargin {
            throw .notEnoughSpace(needed: totalBytes, available: available)
        }

        let runID = try? writer.startRun(taskID: plan.taskID, deviceID: plan.deviceID)
        events(.transferStarted(totalItems: items.count, totalBytes: totalBytes))

        var namer = GroupNamer(items: items, exists: writer.fileExists(atRelativePath:))
        var forPhotos: [(path: String, groupKey: String)] = []
        for (index, entry) in items.enumerated() {
            // Cancelling the task (e.g. Ctrl-C) stops between files; the current file always finishes.
            if Task.isCancelled {
                summary.notAttempted = items.count - index
                summary.cancelled = true
                break
            }
            events(.fileStarted(entry, index: index))
            switch await transfer(entry, plan: plan, writer: writer, namer: &namer, events: events) {
            case .success(let outcome):
                switch outcome {
                case .imported(let path):
                    summary.imported += 1
                    if entry.item.role != .sidecar {
                        forPhotos.append((path, entry.item.parentItemID ?? entry.item.deviceItemID))
                    }
                case .duplicate:
                    summary.duplicates += 1
                }
                summary.bytes += entry.item.size
                events(.fileDone(entry, outcome))
            case .failure(let failure):
                summary.failed.append((entry.item.filename, failure))
                events(.fileFailed(entry, failure))
                if failure == .deviceDisconnected {
                    summary.notAttempted = items.count - index - 1
                    summary.stoppedBecause = .deviceNotConnected(name: plan.session.info.name)
                }
            }
            if summary.stoppedBecause != nil { break }
        }

        // After Ctrl-C, Photos is left for the next run, which retries pending files.
        if let photos, !summary.cancelled {
            summary.photos = await addToPhotos(
                newPaths: forPhotos, writer: writer, root: plan.destination.root, step: photos, events: events
            )
        }

        summary.duration = start.duration(to: .now)
        summary.indexID = try? writer.meta().indexID
        if let runID { writer.finishRun(runID, summary: summary) }
        events(.finished(summary))
        return summary
    }

    /// Records the files the plan found in the destination but not in its index: a new index
    /// when there is none, otherwise they are added. Called by `execute`; call it directly when
    /// a run has nothing new to copy, so those files aren't read again next time.
    public func indexExistingFiles(_ plan: SyncPlan, events: @escaping EventSink) async throws(SyncError) {
        guard plan.summary.existingFiles > 0, let existing else { return }
        let hasIndex = ((try? indexes.existingIndex(at: plan.destination.root)) ?? nil) != nil
        do {
            if hasIndex {
                _ = try await existing.add(plan.existingFiles, to: plan.destination) {
                    events(.existingFilesIndexing(done: $0, total: $1))
                }
            } else {
                _ = try await existing.index(plan.destination, known: plan.existingFiles) {
                    events(.existingFilesIndexing(done: $0, total: $1))
                }
            }
        } catch let error as SyncError {
            throw error
        } catch {
            throw .indexUnreadable(String(describing: error))
        }
    }

    private func transfer(
        _ entry: PlannedItem, plan: SyncPlan, writer: any DestinationWriter, namer: inout GroupNamer,
        events: @escaping EventSink
    ) async -> Result<FileOutcome, ItemFailure> {
        let item = entry.item
        let tempName = "\(UUID().uuidString)-\(item.filename)"
        do {
            try writer.beginTransfer(tempName: tempName, key: entry.key)
        } catch {
            return .failure(.writeFailed(String(describing: error)))
        }

        let file: URL
        do {
            file = try await plan.session.download(item, to: writer.partialDirectory, as: tempName) { bytes in
                events(.fileProgress(entry, bytes: bytes))
            }
        } catch {
            writer.abandonTransfer(tempName: tempName, tempFile: nil)
            switch error {
            case .disconnected, .notFound: return .failure(.deviceDisconnected)
            case .downloadFailed(let reason), .sessionFailed(let reason): return .failure(.downloadFailed(reason))
            case .accessRestricted: return .failure(.downloadFailed("the device was locked"))
            }
        }

        let actualSize = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? -1
        guard actualSize == item.size else {
            writer.abandonTransfer(tempName: tempName, tempFile: file)
            return .failure(.incomplete(expected: item.size, actual: actualSize))
        }

        do {
            let hash = try writer.hash(of: file)
            if let existing = try writer.existingPath(forHash: hash) {
                try writer.recordDuplicate(key: entry.key, of: existing, deviceID: plan.deviceID, tempFile: file, tempName: tempName)
                return .success(.duplicate(of: existing))
            }
            // Own camera or Other: decided once per group, from the photo itself, so a Live Photo's
            // video and edit data stay next to it.
            if let rule = plan.otherRule, let cameras, !namer.hasFolder(forGroupOf: entry) {
                if item.role == .sidecar {
                    // Edit data has no camera model; without its photo in this run it stays in the date folder.
                    namer.setFolder(entry.folder, forGroupOf: entry)
                } else {
                    let model = await cameras.cameraModel(of: file)
                    namer.setFolder(rule.folder(for: entry.key.captureDate, model: model), forGroupOf: entry)
                }
            }
            while true {
                let path = namer.path(for: entry)
                let indexed = IndexedItem(
                    key: entry.key, relativePath: path, sha256: hash, role: item.role, assetID: item.assetID,
                    deviceID: plan.deviceID, originalFilename: item.originalFilename, importedAt: Date()
                )
                do {
                    try writer.commit(tempFile: file, tempName: tempName, item: indexed, captureDate: entry.key.captureDate)
                    return .success(.imported(relativePath: path))
                } catch DestinationWriteError.targetExists {
                    namer.skip(path, for: entry)
                }
            }
        } catch {
            writer.abandonTransfer(tempName: tempName, tempFile: file)
            return .failure(.writeFailed(String(describing: error)))
        }
    }
}

/// Chooses file names in the destination. Never reuses an existing name: collisions get a
/// " (1)", " (2)" suffix, and a photo and its attached files (Live Photo video, AAE) share the
/// same suffix so they keep matching names.
struct GroupNamer {
    private let exists: (String) -> Bool
    /// Members of each group, by the primary's device item ID.
    private let groups: [String: [PlannedItem]]
    private var suffixes: [String: Int] = [:]
    /// Folders chosen per group, overriding the planned folder (see `OtherFolderRule`).
    private var folders: [String: String] = [:]

    init(items: [PlannedItem], exists: @escaping (String) -> Bool) {
        self.exists = exists
        let ids = Set(items.map(\.item.deviceItemID))
        groups = Dictionary(grouping: items) { entry in
            entry.item.parentItemID.flatMap { ids.contains($0) ? $0 : nil } ?? entry.item.deviceItemID
        }
    }

    func hasFolder(forGroupOf entry: PlannedItem) -> Bool {
        folders[groupOwner(of: entry)] != nil
    }

    /// Puts the entry's whole group into `folder`. Call before the group's first `path(for:)`.
    mutating func setFolder(_ folder: String, forGroupOf entry: PlannedItem) {
        folders[groupOwner(of: entry)] = folder
    }

    mutating func path(for entry: PlannedItem) -> String {
        let owner = groupOwner(of: entry)
        if let suffix = suffixes[owner] {
            return path(entry, suffix: suffix)
        }
        let members = groups[owner] ?? [entry]
        var suffix = 0
        while members.contains(where: { exists(path($0, suffix: suffix)) }) {
            suffix += 1
        }
        suffixes[owner] = suffix
        return path(entry, suffix: suffix)
    }

    /// Called when `path` turned out to be taken after all; the group moves to the next suffix.
    mutating func skip(_ path: String, for entry: PlannedItem) {
        let owner = groupOwner(of: entry)
        let next = (suffixes[owner] ?? 0) + 1
        var suffix = next
        while exists(self.path(entry, suffix: suffix)) {
            suffix += 1
        }
        suffixes[owner] = suffix
    }

    private func groupOwner(of entry: PlannedItem) -> String {
        if let parent = entry.item.parentItemID, groups[parent] != nil { return parent }
        return entry.item.deviceItemID
    }

    private func path(_ entry: PlannedItem, suffix: Int) -> String {
        Self.path(entry, folder: folders[groupOwner(of: entry)] ?? entry.folder, suffix: suffix)
    }

    static func path(_ entry: PlannedItem, folder: String, suffix: Int) -> String {
        let name = entry.item.filename
        let file: String
        if suffix > 0 {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            file = "\(base) (\(suffix))\(ext.isEmpty ? "" : ".\(ext)")"
        } else {
            file = name
        }
        return folder.isEmpty ? file : "\(folder)/\(file)"
    }
}
