import XCTest
@testable import xabber

final class ChatAttachmentPickerEntryPointTests: XCTestCase {
    private var previousTelegramAttachmentPickerFlag: Bool?

    override func setUp() {
        super.setUp()
        previousTelegramAttachmentPickerFlag = CommonConfigManager.shared.config.use_telegram_attachment_picker
    }

    override func tearDown() {
        CommonConfigManager.shared.config.use_telegram_attachment_picker = previousTelegramAttachmentPickerFlag
        super.tearDown()
    }

    func testLegacyFeatureFlagOffStillSelectsCurrentAttachmentFlow() {
        let route = ChatAttachmentPickerRoutingPolicy.route(
            isTelegramAttachmentPickerEnabled: false,
            isCloudStorageAvailable: true
        )

        XCTAssertEqual(route, .telegramAttachmentFlow)
    }

    func testFlagOnAndCloudStorageAvailableSelectsCurrentAttachmentFlow() {
        let route = ChatAttachmentPickerRoutingPolicy.route(
            isTelegramAttachmentPickerEnabled: true,
            isCloudStorageAvailable: true
        )

        XCTAssertEqual(route, .telegramAttachmentFlow)
    }

    func testCloudStorageUnavailableBlocksRouteWhenLegacyFlagIsOff() {
        let route = ChatAttachmentPickerRoutingPolicy.route(
            isTelegramAttachmentPickerEnabled: false,
            isCloudStorageAvailable: false
        )

        XCTAssertEqual(route, .blocked(.cloudStorageUnavailable))
    }

    func testCloudStorageUnavailableBlocksRouteWhenLegacyFlagIsOn() {
        let route = ChatAttachmentPickerRoutingPolicy.route(
            isTelegramAttachmentPickerEnabled: true,
            isCloudStorageAvailable: false
        )

        XCTAssertEqual(route, .blocked(.cloudStorageUnavailable))
    }

    func testMissingConfigFlagResolvesToTelegramAttachmentFlow() {
        CommonConfigManager.shared.config.use_telegram_attachment_picker = nil

        XCTAssertTrue(CommonConfigManager.shared.isTelegramAttachmentPickerEnabled)

        let route = ChatAttachmentPickerRoutingPolicy.route(
            isTelegramAttachmentPickerEnabled: CommonConfigManager.shared.config.use_telegram_attachment_picker,
            isCloudStorageAvailable: true
        )

        XCTAssertEqual(route, .telegramAttachmentFlow)
    }

}
