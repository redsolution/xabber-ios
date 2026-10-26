import XCTest

/// Opt-in checks of the installed app and its real account/server state.
/// This suite never creates fixture accounts or sends/deletes user messages.
final class ArchiveLoadingLiveDeviceTests: XCTestCase {
    func testInspectCurrentLiveApplication() throws {
        let app = try existingLiveApplication()
        attachEvidence(app, stage: "initial-live-application")
    }

    func testOpenRequestedOrdinaryChat() throws {
        let app = try existingLiveApplication()
        let environment = ProcessInfo.processInfo.environment
        let title = try XCTUnwrap(environment["XABBER_ARCHIVE_LIVE_ROW_TITLE"])
        var rows = app.tables.cells.containing(.staticText, identifier: title)
        if let preview = environment["XABBER_ARCHIVE_LIVE_ROW_PREVIEW"], !preview.isEmpty {
            rows = rows.containing(.staticText, identifier: preview)
        }
        let visibleRows = rows.allElementsBoundByIndex.filter { $0.isHittable }
        XCTAssertEqual(visibleRows.count, 1, "The observed exact ordinary-chat row must be uniquely visible")
        try XCTUnwrap(visibleRows.first).tap()
        let collection = app.collectionViews["chat.conversation.messages"]
        XCTAssertTrue(collection.waitForExistence(timeout: 15))
        attachEvidence(app, stage: "requested-chat-opened")
        for sample in 1...12 {
            XCTAssertFalse(app.otherElements["chat.archiveHistory.recoveryStatus"].exists)
            if sample == 6 || sample == 12 {
                attachEvidence(app, stage: "requested-chat-after-\(sample)-seconds")
            }
            Thread.sleep(forTimeInterval: 1)
        }
    }

    private func existingLiveApplication() throws -> XCUIApplication {
        #if targetEnvironment(simulator)
        throw XCTSkip("Live archive verification requires an explicitly selected physical device.")
        #else
        guard ProcessInfo.processInfo.environment["XABBER_ARCHIVE_LIVE_QA"] == "1" else {
            throw XCTSkip("Live archive verification is explicitly opt-in.")
        }
        continueAfterFailure = false
        executionTimeAllowance = 300
        let app = XCUIApplication(bundleIdentifier: "xabber.ios")
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        return app
        #endif
    }

    private func attachEvidence(_ app: XCUIApplication, stage: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "archive-live-\(stage)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let collection = app.collectionViews["chat.conversation.messages"]
        let accessibility = XCTAttachment(string: collection.exists ? collection.debugDescription : app.debugDescription)
        accessibility.name = "archive-live-\(stage)-private-accessibility"
        accessibility.lifetime = .keepAlways
        add(accessibility)
    }
}
