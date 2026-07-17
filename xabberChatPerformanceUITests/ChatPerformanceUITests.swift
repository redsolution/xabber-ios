import XCTest

final class ChatPerformanceUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
        XCUIDevice.shared.orientation = .portrait
    }

    func testSmallHistoryOpensWithBoundedFirstFrame() {
        launch(scale: "small")

        let status = waitForReady()
        XCTAssertTrue(status.label.contains("logical=100"))
        XCTAssertTrue(status.label.contains("resident=80"))
        XCTAssertTrue(status.label.contains("applies=1"))
        XCTAssertTrue(status.label.contains("layouts=1"))
        XCTAssertTrue(status.label.contains("offsets=1"))
    }

    func testMillionHistoryOpensWithSameBoundedFirstFrame() {
        launch(scale: "million")

        let status = waitForReady(timeout: 12)
        XCTAssertTrue(status.label.contains("logical=1000000"))
        XCTAssertTrue(status.label.contains("resident=80"))
        XCTAssertTrue(status.label.contains("applies=1"))
        XCTAssertTrue(status.label.contains("layouts=1"))
        XCTAssertTrue(status.label.contains("offsets=1"))
    }

    func testScrollIncomingAndOptimisticSendEditDeleteStayStable() {
        launch(scale: "million")
        _ = waitForReady(timeout: 12)

        let timeline = app.collectionViews["chat.performance.timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 3))
        timeline.swipeDown(velocity: .fast)
        timeline.swipeUp(velocity: .fast)

        app.buttons["chat.performance.incoming"].tap()
        let composer = app.textViews["chat.composer.text_field"]
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        composer.tap()
        composer.typeText("deterministic optimistic test")
        let send = app.buttons["chat.composer.send_button"]
        XCTAssertTrue(send.waitForExistence(timeout: 3))
        send.tap()

        let state = app.staticTexts["chat.performance.state"]
        XCTAssertTrue(waitForLabel(state, containing: "optimistic=1"))
        app.buttons["chat.performance.edit"].tap()
        XCTAssertTrue(waitForLabel(state, containing: "edited=1"))
        app.buttons["chat.performance.delete"].tap()
        XCTAssertTrue(waitForLabel(state, containing: "optimistic=0"))
        XCTAssertTrue(state.label.contains("anchor=0.0"))
    }

    func testRotationReflowsTimelineAndPreservesAnchorWithoutCorrection() {
        launch(scale: "million")
        _ = waitForReady(timeout: 12)
        let timeline = app.collectionViews["chat.performance.timeline"]
        let state = app.staticTexts["chat.performance.state"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 3))

        XCUIDevice.shared.orientation = .landscapeLeft

        let landscape = NSPredicate { object, _ in
            guard let element = object as? XCUIElement else { return false }
            return element.frame.width > element.frame.height
        }
        let expectation = XCTNSPredicateExpectation(predicate: landscape, object: timeline)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 5),
            .completed,
            "Timeline did not reflow to landscape. device=\(XCUIDevice.shared.orientation.rawValue) app=\(app.frame) timeline=\(timeline.frame)"
        )
        XCTAssertTrue(waitForLabel(state, containing: "anchor=0.0"))
        XCTAssertTrue(state.label.contains("corrections=0"))

        XCUIDevice.shared.orientation = .landscapeRight
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(
                    predicate: NSPredicate { _, _ in
                        XCUIDevice.shared.orientation == .landscapeRight
                    },
                    object: XCUIDevice.shared
                )],
                timeout: 5
            ),
            .completed
        )
        XCTAssertTrue(waitForLabel(state, containing: "anchor=0.0"))
        XCTAssertTrue(state.label.contains("corrections=0"))

        XCUIDevice.shared.orientation = .portrait
        let portrait = NSPredicate { object, _ in
            guard let element = object as? XCUIElement else { return false }
            return element.frame.height > element.frame.width
        }
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: portrait, object: timeline)],
                timeout: 5
            ),
            .completed
        )
    }

    func testMediaSkeletonAndExactSearchRouteAreAtomic() {
        launch(scale: "million")
        _ = waitForReady(timeout: 12)
        let state = app.staticTexts["chat.performance.state"]

        app.buttons["chat.performance.media_prefetch"].tap()
        app.buttons["chat.performance.media_visible"].tap()
        XCTAssertTrue(waitForLabel(state, containing: "media=1/1/1"))

        app.buttons["chat.performance.skeleton"].tap()
        XCTAssertTrue(waitForLabel(state, containing: "skeleton=true"))
        app.buttons["chat.performance.reveal"].tap()
        XCTAssertTrue(waitForLabel(state, containing: "skeleton=false"))

        app.buttons["chat.performance.lastchats_search"].tap()
        let search = app.searchFields["lastchats.performance.search_input"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("test")
        let result = app.cells["lastchats.performance.exact_result"]
        XCTAssertTrue(result.waitForExistence(timeout: 3))
        result.tap()
        XCTAssertTrue(waitForLabel(
            state,
            containing: "target=chat-performance-exact-target"
        ))
    }

    private func launch(scale: String) {
        app = XCUIApplication()
        app.launchArguments = ["--xabber-chat-performance-fixture", scale]
        app.launchEnvironment = ["XABBER_CHAT_PERFORMANCE_UI_TEST": "1"]
        app.launch()
    }

    @discardableResult
    private func waitForReady(timeout: TimeInterval = 8) -> XCUIElement {
        let status = app.staticTexts["chat.performance.ready"]
        XCTAssertTrue(status.waitForExistence(timeout: timeout))
        XCTAssertTrue(waitForLabel(status, containing: "ready", timeout: timeout))
        return status
    }

    private func waitForLabel(
        _ element: XCUIElement,
        containing text: String,
        timeout: TimeInterval = 5
    ) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
