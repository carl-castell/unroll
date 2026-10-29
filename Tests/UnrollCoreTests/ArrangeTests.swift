import Foundation
import Testing
import UnrollCore

struct ArrangePlannerTests {
    let june = LocalTimestamp(secondsSince1970: 1_780_393_586) // 2026-06-02

    func plan(_ files: [ArrangeFile], template: FolderTemplate = .default, rule: OtherFolderRule? = nil, existing: Set<String> = []) -> ArrangePlan {
        ArrangePlanner.plan(files: files, template: template, rule: rule) { existing.contains($0) }
    }

    @Test func movesPhotoWithItsVideoAndEditDataAndLeavesTheRest() {
        let result = plan([
            ArrangeFile(relativePath: "IMG_1.HEIC", kind: .photo, captureDate: june),
            ArrangeFile(relativePath: "IMG_1.MOV", kind: .video, captureDate: june),
            ArrangeFile(relativePath: "IMG_1.AAE", kind: .sidecar, captureDate: nil),
            ArrangeFile(relativePath: "IMG_2.PNG", kind: .photo, captureDate: nil),
            ArrangeFile(relativePath: "notes.txt", kind: .other, captureDate: nil),
            ArrangeFile(relativePath: "IMG_3.HEIC", kind: .photo, captureDate: june, inPhotos: true),
        ])
        #expect(result.moves == [
            ArrangeMove(from: "IMG_1.AAE", to: "2026/2026-06/IMG_1.AAE"),
            ArrangeMove(from: "IMG_1.HEIC", to: "2026/2026-06/IMG_1.HEIC"),
            ArrangeMove(from: "IMG_1.MOV", to: "2026/2026-06/IMG_1.MOV"),
        ])
        #expect(result.undated == 1)
        #expect(result.otherFiles == 1)
        #expect(result.inPhotos == 1)
        #expect(result.staying == 3)
    }

    @Test func takenNameMovesTheWholeGroupToTheNextSuffix() {
        let result = plan([
            ArrangeFile(relativePath: "old/IMG_1.HEIC", kind: .photo, captureDate: june),
            ArrangeFile(relativePath: "old/IMG_1.MOV", kind: .video, captureDate: june),
        ], existing: ["2026/2026-06/IMG_1.HEIC"])
        #expect(result.moves.map(\.to) == ["2026/2026-06/IMG_1 (1).HEIC", "2026/2026-06/IMG_1 (1).MOV"])
    }

    @Test func filesInTheRightFolderStay() {
        let result = plan([ArrangeFile(relativePath: "2026/2026-06/IMG_1.HEIC", kind: .photo, captureDate: june)])
        #expect(result.moves.isEmpty)
        #expect(result.inPlace == 1)
    }

    @Test func otherCamerasGoToOther() {
        let rule = OtherFolderRule(cameraModels: ["iPhone 15 Pro"], template: .default)
        let result = plan([
            ArrangeFile(relativePath: "IMG_1.HEIC", kind: .photo, captureDate: june, cameraModel: "iPhone 15 Pro"),
            ArrangeFile(relativePath: "IMG_2.PNG", kind: .photo, captureDate: june),
        ], rule: rule)
        #expect(result.moves.map(\.to) == ["2026/2026-06/IMG_1.HEIC", "Other/2026/IMG_2.PNG"])
    }

    @Test func twoFilesWantingTheSameNameGetDifferentOnes() {
        let result = plan([
            ArrangeFile(relativePath: "a/IMG_1.HEIC", kind: .photo, captureDate: june),
            ArrangeFile(relativePath: "b/IMG_1.HEIC", kind: .photo, captureDate: june),
        ], template: .none)
        #expect(result.moves.map(\.to) == ["IMG_1.HEIC", "IMG_1 (1).HEIC"])
    }
}
