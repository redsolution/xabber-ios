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

    func testFlagOffAndCloudStorageAvailableSelectsLegacyPicker() {
        let route = ChatAttachmentPickerRoutingPolicy.route(
            isTelegramAttachmentPickerEnabled: false,
            isCloudStorageAvailable: true
        )

        XCTAssertEqual(route, .legacyImagePicker)
    }

    func testFlagOnAndCloudStorageAvailableSelectsTelegramAttachmentFlow() {
        let route = ChatAttachmentPickerRoutingPolicy.route(
            isTelegramAttachmentPickerEnabled: true,
            isCloudStorageAvailable: true
        )

        XCTAssertEqual(route, .telegramAttachmentFlow)
    }

    func testCloudStorageUnavailableBlocksLegacyRoute() {
        let route = ChatAttachmentPickerRoutingPolicy.route(
            isTelegramAttachmentPickerEnabled: false,
            isCloudStorageAvailable: false
        )

        XCTAssertEqual(route, .blocked(.cloudStorageUnavailable))
    }

    func testCloudStorageUnavailableBlocksTelegramAttachmentRoute() {
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

    func testRolloutPolicyRetainsLegacyFallbackWithoutProductSignoff() {
        let decision = ChatAttachmentPickerRolloutPolicy.decision(
            hasProductSignoffForDefaultOnRollout: false,
            sendParityVerified: true,
            focusedTestsPassed: true,
            appBuildPassed: true,
            manualSmokePassed: true,
            hasRollbackBlockers: false
        )

        XCTAssertEqual(decision, .retainLegacyFallback(.productSignoffMissing))
    }

    func testRolloutPolicyRetainsLegacyFallbackWhenManualSmokeIsMissing() {
        let decision = ChatAttachmentPickerRolloutPolicy.decision(
            hasProductSignoffForDefaultOnRollout: true,
            sendParityVerified: true,
            focusedTestsPassed: true,
            appBuildPassed: true,
            manualSmokePassed: false,
            hasRollbackBlockers: false
        )

        XCTAssertEqual(decision, .retainLegacyFallback(.manualSmokeMissing))
    }

    func testRolloutPolicyMarksLegacyRemovalEligibleOnlyAfterAllGatesPass() {
        let decision = ChatAttachmentPickerRolloutPolicy.decision(
            hasProductSignoffForDefaultOnRollout: true,
            sendParityVerified: true,
            focusedTestsPassed: true,
            appBuildPassed: true,
            manualSmokePassed: true,
            hasRollbackBlockers: false
        )

        XCTAssertEqual(decision, .eligibleToRemoveLegacyFallback)
    }

    func testRollbackRouteRemainsValidWhenLegacyFallbackIsRetained() {
        let decision = ChatAttachmentPickerRolloutPolicy.decision(
            hasProductSignoffForDefaultOnRollout: false,
            sendParityVerified: true,
            focusedTestsPassed: true,
            appBuildPassed: true,
            manualSmokePassed: true,
            hasRollbackBlockers: false
        )

        XCTAssertEqual(decision, .retainLegacyFallback(.productSignoffMissing))
        XCTAssertEqual(
            ChatAttachmentPickerRoutingPolicy.route(
                isTelegramAttachmentPickerEnabled: false,
                isCloudStorageAvailable: true
            ),
            .legacyImagePicker
        )
        XCTAssertEqual(
            ChatAttachmentPickerRoutingPolicy.route(
                isTelegramAttachmentPickerEnabled: true,
                isCloudStorageAvailable: true
            ),
            .telegramAttachmentFlow
        )
    }
}
