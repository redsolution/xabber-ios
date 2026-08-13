import XCTest
import UIKit
@testable import xabber

final class CloudStorageGallerySelectionTests: XCTestCase {
    func testPartialDeleteRestoresOnlyRemainingSelectedIDsAfterRowsShift() {
        var remainingSelectedIDs: Set<Int> = [101, 202, 303]
        remainingSelectedIDs.remove(101)

        let reconciliation = CloudStorageGallerySelectionPolicy.reconcile(
            remainingSelectedFileIDs: remainingSelectedIDs,
            datasourceFileIDs: [202, 303, 404]
        )

        XCTAssertEqual(reconciliation.orderedFileIDs, [202, 303])
        XCTAssertEqual(
            reconciliation.indexPaths,
            [IndexPath(item: 0, section: 0), IndexPath(item: 1, section: 0)]
        )
        XCTAssertFalse(reconciliation.orderedFileIDs.contains(404))
        XCTAssertFalse(reconciliation.indexPaths.contains(IndexPath(item: 2, section: 0)))
    }

    func testReconciliationDropsPendingIDsThatAreNoLongerInDatasource() {
        let reconciliation = CloudStorageGallerySelectionPolicy.reconcile(
            remainingSelectedFileIDs: [101, 202, 303],
            datasourceFileIDs: [nil, 303, 404]
        )

        XCTAssertEqual(reconciliation.orderedFileIDs, [303])
        XCTAssertEqual(reconciliation.indexPaths, [IndexPath(item: 1, section: 0)])
    }
}
