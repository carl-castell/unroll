import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers
import UnrollCore

/// Reads the camera model from a local file: the TIFF `Model` field of photos, the QuickTime
/// model of videos. Screenshots, screen recordings and images saved from apps have none.
public struct CameraModelReader: CameraModelReading {
    public init() {}

    public func cameraModel(of file: URL) async -> String? {
        guard let type = UTType(filenameExtension: file.pathExtension) else { return nil }
        let model: String?
        if type.conforms(to: .image) {
            model = Self.photoModel(of: file)
        } else if type.conforms(to: .audiovisualContent) {
            model = await Self.videoModel(of: file)
        } else {
            model = nil
        }
        return model.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    private static func photoModel(of file: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] else { return nil }
        return tiff[kCGImagePropertyTIFFModel] as? String
    }

    private static func videoModel(of file: URL) async -> String? {
        guard let metadata = try? await AVURLAsset(url: file).load(.metadata) else { return nil }
        for identifier: AVMetadataIdentifier in [.quickTimeMetadataModel, .commonIdentifierModel] {
            if let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier).first,
               let value = try? await item.load(.stringValue) {
                return value
            }
        }
        return nil
    }
}
