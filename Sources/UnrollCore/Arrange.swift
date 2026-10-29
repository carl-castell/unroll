import Foundation

/// A file already in the destination, as seen when arranging it into the folder structure.
public struct ArrangeFile: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case photo, video
        /// Edit data (AAE) and similar files that belong to a photo.
        case sidecar
        /// Anything else; never moved.
        case other
    }

    /// Relative to the destination root.
    public let relativePath: String
    public let kind: Kind
    /// Nil when the file has no capture time of its own (only a file date); such files stay.
    public let captureDate: LocalTimestamp?
    /// Only read when the task separates its own camera from Other.
    public let cameraModel: String?
    /// Added to Apple Photos as a referenced file; moving it would break the reference.
    public let inPhotos: Bool

    public init(relativePath: String, kind: Kind, captureDate: LocalTimestamp?, cameraModel: String? = nil, inPhotos: Bool = false) {
        self.relativePath = relativePath
        self.kind = kind
        self.captureDate = captureDate
        self.cameraModel = cameraModel
        self.inPhotos = inPhotos
    }

    var folder: String {
        (relativePath as NSString).deletingLastPathComponent
    }

    var name: String {
        (relativePath as NSString).lastPathComponent
    }
}

public struct ArrangeMove: Sendable, Equatable {
    public let from: String
    public let to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

/// What arranging would do: the moves, and why other files stay where they are.
public struct ArrangePlan: Sendable, Equatable {
    public var moves: [ArrangeMove] = []
    /// Photos and videos already in the right folder.
    public var inPlace = 0
    /// Photos and videos without a capture time; there's no folder to put them in.
    public var undated = 0
    /// Files that aren't photos or videos.
    public var otherFiles = 0
    /// Files Apple Photos references; moving them would break the reference.
    public var inPhotos = 0

    public init() {}

    /// Files that stay although they aren't in the structure.
    public var staying: Int { undated + otherFiles + inPhotos }
}

/// Plans moving the files already in a destination into the task's folder structure.
/// A photo, its Live Photo video and its edit data move together and keep matching names.
/// Never plans a move onto an existing file: a taken name gets " (1)", " (2)" for the whole group.
public enum ArrangePlanner {
    public static func plan(
        files: [ArrangeFile], template: FolderTemplate, rule: OtherFolderRule?, exists: (String) -> Bool
    ) -> ArrangePlan {
        var plan = ArrangePlan()
        var claimed = Set<String>()
        let groups = Dictionary(grouping: files) { file in
            file.kind == .other ? file.relativePath : (file.relativePath as NSString).deletingPathExtension
        }
        for key in groups.keys.sorted() {
            let members = groups[key]!.sorted { $0.relativePath < $1.relativePath }
            if members.allSatisfy({ $0.kind == .other }) {
                plan.otherFiles += members.count
                continue
            }
            guard let leader = members.first(where: { $0.kind == .photo })
                ?? members.first(where: { $0.kind == .video }), let date = leader.captureDate else {
                plan.undated += members.count
                continue
            }
            if members.contains(where: \.inPhotos) {
                plan.inPhotos += members.count
                continue
            }
            let folder = rule?.folder(for: date, model: leader.cameraModel) ?? template.folder(for: date)
            let moving = members.filter { $0.folder != folder }
            plan.inPlace += members.count - moving.count
            guard !moving.isEmpty else { continue }

            var suffix = 0
            while moving.contains(where: { taken(target($0.name, folder: folder, suffix: suffix), exists, claimed) }) {
                suffix += 1
            }
            for file in moving {
                let to = target(file.name, folder: folder, suffix: suffix)
                claimed.insert(to)
                plan.moves.append(ArrangeMove(from: file.relativePath, to: to))
            }
        }
        plan.moves.sort { $0.from < $1.from }
        return plan
    }

    private static func taken(_ path: String, _ exists: (String) -> Bool, _ claimed: Set<String>) -> Bool {
        claimed.contains(path) || exists(path)
    }

    /// "IMG_1.HEIC" in "2026/2026-06", with " (n)" before the extension when `suffix` > 0.
    public static func target(_ name: String, folder: String, suffix: Int) -> String {
        var file = name
        if suffix > 0 {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            file = "\(base) (\(suffix))\(ext.isEmpty ? "" : ".\(ext)")"
        }
        return folder.isEmpty ? file : "\(folder)/\(file)"
    }
}
