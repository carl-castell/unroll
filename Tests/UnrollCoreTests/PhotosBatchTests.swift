import Foundation
import Testing
@testable import UnrollCore

struct PhotosBatchTests {
    @Test func batchesNeverSplitALivePhotoPair() {
        // Singles up to one below the limit, then a pair that would straddle the boundary.
        let singles = SyncEngine.photosBatchSize - 1
        var files = (0..<singles).map { (path: "IMG_\($0).HEIC", groupKey: "\($0)") }
        files += [("IMG_P.HEIC", "pair"), ("IMG_P.MOV", "pair"), ("IMG_Z.HEIC", "z")]
        let batches = SyncEngine.batches(files)

        #expect(batches.count == 2)
        #expect(batches[0].count == singles)
        #expect(batches[1] == ["IMG_P.HEIC", "IMG_P.MOV", "IMG_Z.HEIC"])
    }

    @Test func emptyInputHasNoBatches() {
        #expect(SyncEngine.batches([]).isEmpty)
    }
}
