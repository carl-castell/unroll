import Foundation

/// Reads the camera model recorded in a photo or video, e.g. "iPhone 15 Pro".
public protocol CameraModelReading: Sendable {
    /// Nil when the file has no camera model, like screenshots, screen recordings and most
    /// images saved from messengers or the web.
    func cameraModel(of file: URL) async -> String?
}

/// Separates photos and videos taken with the task's own cameras from everything else.
/// Own camera → the task's folder structure; everything else → `Other`, split by year
/// (or one flat `Other` folder when the task uses no folders).
public struct OtherFolderRule: Sendable, Equatable {
    public static let folderName = "Other"

    public let cameraModels: Set<String>
    public let template: FolderTemplate

    public init(cameraModels: [String], template: FolderTemplate) {
        self.cameraModels = Set(cameraModels.map(Self.normalized))
        self.template = template
    }

    public func isOwnCamera(_ model: String?) -> Bool {
        model.map { cameraModels.contains(Self.normalized($0)) } ?? false
    }

    public func otherFolder(for date: LocalTimestamp) -> String {
        guard !template.isNone else { return Self.folderName }
        return "\(Self.folderName)/\(String(format: "%04d", date.components.year ?? 0))"
    }

    /// The folder for a file, given the camera model read from it.
    public func folder(for date: LocalTimestamp, model: String?) -> String {
        isOwnCamera(model) ? template.folder(for: date) : otherFolder(for: date)
    }

    static func normalized(_ model: String) -> String {
        model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

extension SyncTask {
    /// Set when the task separates its own camera's files from other images.
    public var otherFolderRule: OtherFolderRule? {
        cameraModels.map { OtherFolderRule(cameraModels: $0, template: folderTemplate) }
    }
}
