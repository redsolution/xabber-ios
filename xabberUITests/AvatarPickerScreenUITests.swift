import XCTest

final class AvatarPickerScreenUITests: XCTestCase {
    private enum AccessibilityID {
        static let screen = "avatar.emoji.screen"
        static let title = "avatar.emoji.title"
        static let subtitle = "avatar.emoji.subtitle"
        static let preview = "avatar.emoji.preview"
        static let edit = "avatar.emoji.edit"
        static let save = "avatar.emoji.save"
        static let purple = "avatar.emoji.color.purple"
        static let emojiPickerScreen = "avatar.emoji.picker.screen"
        static let emojiCollection = "avatar.emoji.picker.collection"
        static let firstEmoji = "avatar.emoji.picker.item.0.0"
    }

    func testSelectingColorAndEmojiUpdatesPreviewAndKeepsSaveAvailable() {
        let app = XCUIApplication()
        app.launchArguments = ["--xabber-avatar-picker-ui-test"]
        app.launchEnvironment["XABBER_AVATAR_PICKER_UI_TEST"] = "1"
        app.launch()
        addTeardownBlock {
            if app.state != .notRunning {
                app.terminate()
            }
        }

        XCTAssertTrue(app.otherElements[AccessibilityID.screen].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts[AccessibilityID.title].exists)
        XCTAssertTrue(app.staticTexts[AccessibilityID.subtitle].exists)
        XCTAssertTrue(app.otherElements[AccessibilityID.preview].exists)

        let save = app.buttons[AccessibilityID.save]
        XCTAssertTrue(save.exists)
        XCTAssertTrue(save.isEnabled)

        let purple = app.buttons[AccessibilityID.purple]
        XCTAssertTrue(purple.exists)
        purple.tap()
        XCTAssertEqual(purple.value as? String, "selected")

        app.buttons[AccessibilityID.edit].tap()
        XCTAssertTrue(
            app.otherElements[AccessibilityID.emojiPickerScreen]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.collectionViews[AccessibilityID.emojiCollection].exists)

        let firstEmoji = app.cells[AccessibilityID.firstEmoji]
        XCTAssertTrue(firstEmoji.waitForExistence(timeout: 5))
        let selectedEmoji = firstEmoji.label
        XCTAssertFalse(selectedEmoji.isEmpty)
        firstEmoji.tap()

        XCTAssertTrue(app.otherElements[AccessibilityID.screen].waitForExistence(timeout: 5))
        XCTAssertEqual(
            app.otherElements[AccessibilityID.preview].value as? String,
            selectedEmoji
        )
        XCTAssertTrue(save.isEnabled)
    }
}
