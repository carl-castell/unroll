import Foundation
import Testing
@testable import UnrollCore

struct PhotosBatchTests {
    @Test func batchesNeverSplitALivePhotoPair() {
        // 99 single photos, then a pair that would straddle the 100-file boundary.
        var files = (0..<99).map { (path: "IMG_\($0).HEIC", groupKey: "\($0)") }
        files += [("IMG_P.HEIC", "pair"), ("IMG_P.MOV", "pair"), ("IMG_Z.HEIC", "z")]
        let batches = SyncEngine.batches(files)

        #expect(batches.count == 2)
        #expect(batches[0].count == 99)
        #expect(batches[1] == ["IMG_P.HEIC", "IMG_P.MOV", "IMG_Z.HEIC"])
    }

    @Test func emptyInputHasNoBatches() {
        #expect(SyncEngine.batches([]).isEmpty)
    }
}
