import UIKit
import XCTest
@testable import xabber

final class MediaGalleryFullscreenLayoutPolicyTests: XCTestCase {
    private let policy = MediaGalleryGridLayoutPolicy(
        columnCount: 3,
        sectionInset: UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8),
        interitemSpacing: 8
    )

    func testGridUsesExactlyThreeColumns() {
        XCTAssertEqual(policy.columnCount, 3)
    }

    func testSquareCellWidthIsDerivedFromActualContainerWidth() {
        let expectedWidths: [(containerWidth: CGFloat, itemWidth: CGFloat)] = [
            (320, 96),
            (375, 343.0 / 3.0),
            (390, 358.0 / 3.0),
            (430, 398.0 / 3.0),
            (768, 736.0 / 3.0),
            (1_024, 992.0 / 3.0)
        ]

        for expectation in expectedWidths {
            let size = policy.squareItemSize(containerWidth: expectation.containerWidth)

            XCTAssertEqual(size.width, expectation.itemWidth, accuracy: 0.0001)
            XCTAssertEqual(size.height, expectation.itemWidth, accuracy: 0.0001)
        }
    }

    func testContentInsetsAreRemovedFromAvailableWidth() {
        let size = policy.squareItemSize(
            containerWidth: 390,
            contentInset: UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        )

        XCTAssertEqual(size.width, 334.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(size.height, size.width, accuracy: 0.0001)
    }

    func testRepeatedSizingIsStableAndHasNoLayoutMutationInput() {
        let first = policy.squareItemSize(containerWidth: 430)
        let second = policy.squareItemSize(containerWidth: 430)

        XCTAssertEqual(first, second)
    }

    @MainActor
    func testThreeColumnFlowLayoutUsesCollectionWidthAndInvalidatesForWidthChanges() {
        let layout = MediaGalleryThreeColumnFlowLayout(policy: policy)
        let collectionView = UICollectionView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 600),
            collectionViewLayout: layout
        )

        layout.prepare()

        XCTAssertEqual(layout.itemSize.width, 358.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(layout.itemSize.height, layout.itemSize.width, accuracy: 0.0001)
        XCTAssertTrue(layout.shouldInvalidateLayout(
            forBoundsChange: CGRect(x: 0, y: 0, width: 430, height: 600)
        ))
        XCTAssertFalse(layout.shouldInvalidateLayout(
            forBoundsChange: CGRect(x: 0, y: 0, width: 390, height: 500)
        ))
        withExtendedLifetime(collectionView) {}
    }
}
