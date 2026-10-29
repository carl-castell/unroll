import UnrollCore
import UnrollStore

/// Features that are built but not switched on yet.
enum Features {
    /// Sorting files not taken with the task's own camera (screenshots, saved images, photos from
    /// other phones) into an Other folder. Deactivated until it is refined: the wizard, the edit
    /// menu, `tasks add --camera-model` and the docs don't offer it, and a task that has camera
    /// models from an earlier build is treated as if it had none.
    static let otherFolder = false

    /// Reads camera models only while the Other folder is on.
    static var cameraReader: (any CameraModelReading)? {
        otherFolder ? CameraModelReader() : nil
    }
}

extension SyncTask {
    /// The task's Other folder rule, or nil while the feature is deactivated.
    var activeOtherFolderRule: OtherFolderRule? {
        Features.otherFolder ? otherFolderRule : nil
    }
}
