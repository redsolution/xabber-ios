import XCTest
import UIKit
@testable import xabber

@MainActor
final class ChatAttachmentPickerPageSheetTests: XCTestCase {
    func testPageSheetStyleUsesLargeOnlyDismissibleSystemSheet() {
        let picker = UIViewController()

        ChatAttachmentPickerPageSheetStyle.apply(to: picker)

        XCTAssertEqual(picker.modalPresentationStyle, .pageSheet)
        XCTAssertFalse(picker.isModalInPresentation)
        XCTAssertNil(picker.transitioningDelegate)
        XCTAssertEqual(picker.sheetPresentationController?.detents.count, 1)
        XCTAssertEqual(picker.sheetPresentationController?.selectedDetentIdentifier, .large)
        XCTAssertEqual(picker.sheetPresentationController?.prefersGrabberVisible, false)
        XCTAssertEqual(
            picker.sheetPresentationController?.preferredCornerRadius,
            ChatAttachmentSheetGlassStyle.sheetCornerRadius
        )
    }
}
