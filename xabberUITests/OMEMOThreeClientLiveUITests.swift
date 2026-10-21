import UIKit
import XCTest

/// Explicitly opted-in physical probes of the existing personal-account application.
/// No launch(), terminate(), launchEnvironment, launchArguments, fixture or storage mutation.
final class OMEMOThreeClientLiveUITests: XCTestCase {
    func testReportExistingPhysicalAppUI() throws {
        // Must remain the first executable statement, before XCUIApplication creation.
        let authorization = try requireAuthorization(operation: .report)
        let app = try activateExistingApplication(authorization)
        attachPrivateEvidence(app, authorization: authorization, stage: "report-existing-ui")
    }

    func testExactTaggedMessageIsCurrentlyVisible() throws {
        // This test does not navigate or search older history.
        let authorization = try requireAuthorization(operation: .visibleMessage)
        let app = try activateExistingApplication(authorization)
        do {
            let messageID = try XCTUnwrap(authorization.messageID)
            let body = try XCTUnwrap(authorization.messageBody)
            let collections = app.collectionViews.matching(identifier: OMEMOThreeClientLiveUIAuthorization.conversationCollectionIdentifier)
            try wait(for: "one identity-bound message inside the visible conversation collection", app: app) {
                guard collections.count == 1 else { return false }
                let collection = collections.element(boundBy: 0)
                guard self.isVisible(collection, in: app) else { return false }
                let cells = collection.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@",
                    OMEMOThreeClientLiveUIAuthorization.messageIdentifierPrefix(messageID)))
                let witnesses = (0..<min(cells.count, 2)).map { index in
                    let cell = cells.element(boundBy: index)
                    let texts = cell.staticTexts.matching(NSPredicate(format: "label == %@", body))
                    return OMEMOThreeClientLiveUIAuthorization.VisibleMessageWitness(
                        collectionIdentifier: collection.identifier, cellIdentifier: cell.identifier,
                        body: texts.count == 1 ? texts.element(boundBy: 0).label : "",
                        isVisible: texts.count == 1 && self.isVisible(cell, in: app)
                            && self.isVisible(texts.element(boundBy: 0), in: app))
                }
                return OMEMOThreeClientLiveUIAuthorization.hasExactlyOneVisibleMessage(id: messageID, body: body, witnesses: witnesses)
            }
            attachPrivateEvidence(app, authorization: authorization, stage: "exact-tagged-message-visible")
        } catch {
            attachPrivateEvidence(app, authorization: authorization, stage: "visible-message-failure")
            throw error
        }
    }

    func testDismissAlreadySuccessfulVerificationWithNormalButton() throws {
        // Requires a fresh external wire/state witness; this test cannot establish cryptographic success.
        let authorization = try requireAuthorization(operation: .terminalDone)
        let app = try activateExistingApplication(authorization)
        do {
            let successLabel = try XCTUnwrap(authorization.successLabel)
            let doneLabel = try XCTUnwrap(authorization.doneLabel)
            let headings = app.staticTexts.matching(NSPredicate(format: "label == %@", successLabel))
            let buttons = app.buttons.matching(NSPredicate(format: "label == %@", doneLabel))
            try wait(for: "the already-successful verification and its normal terminal button", app: app) {
                headings.count == 1 && buttons.count == 1
                    && self.isVisible(headings.element(boundBy: 0), in: app)
                    && self.isVisible(buttons.element(boundBy: 0), in: app)
            }
            attachPrivateEvidence(app, authorization: authorization, stage: "verification-success-before-done")
            buttons.element(boundBy: 0).tap()
            try wait(for: "the successful verification sheet to dismiss", app: app) {
                headings.count == 0 && buttons.count == 0
            }
            attachPrivateEvidence(app, authorization: authorization, stage: "verification-success-after-done")
        } catch {
            attachPrivateEvidence(app, authorization: authorization, stage: "terminal-done-failure")
            throw error
        }
    }

    private func requireAuthorization(
        operation: OMEMOThreeClientLiveUIAuthorization.Operation
    ) throws -> OMEMOThreeClientLiveUIAuthorization.Configuration {
        #if targetEnvironment(simulator)
        let isSimulator = true
        #else
        let isSimulator = false
        #endif
        let idiom: OMEMOThreeClientLiveUIAuthorization.Idiom
        switch UIDevice.current.userInterfaceIdiom {
        case .phone: idiom = .phone
        case .pad: idiom = .pad
        default: idiom = .other
        }
        guard let authorization = try OMEMOThreeClientLiveUIAuthorization.authorize(
            environment: ProcessInfo.processInfo.environment,
            isSimulator: isSimulator,
            idiom: idiom,
            operation: operation
        ) else {
            throw XCTSkip("Physical OMEMO UI scenario is not explicitly opted in for this operation.")
        }
        continueAfterFailure = false
        executionTimeAllowance = 60
        return authorization
    }

    private func activateExistingApplication(
        _ authorization: OMEMOThreeClientLiveUIAuthorization.Configuration
    ) throws -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "xabber.ios")
        switch app.state {
        case .runningForeground, .runningBackground, .runningBackgroundSuspended:
            break
        default:
            throw OMEMOThreeClientLiveUIAuthorization.Rejection(
                reason: "The coordinator must start and authenticate the existing main app before this probe. No launch was attempted."
            )
        }
        app.activate()
        try wait(for: "the existing main app to become foreground", app: app) {
            app.state == .runningForeground
        }
        return app
    }

    private func wait(for description: String, app: XCUIApplication, condition: @escaping () -> Bool) throws {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in condition() }, object: nil
        )
        guard XCTWaiter.wait(for: [expectation], timeout: 15) == .completed else {
            throw OMEMOThreeClientLiveUIAuthorization.Rejection(reason: "Timed out waiting for \(description).")
        }
    }

    private func isVisible(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        element.exists && element.isHittable && !element.frame.isEmpty
            && element.frame.intersects(app.frame)
    }

    private func attachPrivateEvidence(
        _ app: XCUIApplication,
        authorization: OMEMOThreeClientLiveUIAuthorization.Configuration,
        stage: String
    ) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "\(authorization.token)-\(authorization.role.rawValue)-\(stage)"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let accessibility = XCTAttachment(string: app.debugDescription)
        accessibility.name = "\(authorization.token)-\(authorization.role.rawValue)-\(stage)-private-accessibility"
        accessibility.lifetime = .keepAlways
        add(accessibility)

        let metadata = XCTAttachment(string: [
            "stage=\(stage)",
            "expectedRole=\(authorization.role.rawValue)",
            "expectedAccount=\(authorization.account)",
            "token=\(authorization.token)",
            "privateBaselineSHA256=\(authorization.baselineSHA256)",
            "deviceModel=\(UIDevice.current.model)",
            "reportedDeviceName=\(UIDevice.current.name)",
            "systemVersion=\(UIDevice.current.systemVersion)",
            "messageIDExpectation=\(authorization.messageID ?? "none")",
            "messageManifestSHA256=\(authorization.messageManifestSHA256 ?? "none")",
            "verifiedSIDExpectation=\(authorization.verifiedSID ?? "none")",
            "accountAndCryptographicStateProvedByThisTest=false"
        ].joined(separator: "\n"))
        metadata.name = "\(authorization.token)-\(authorization.role.rawValue)-\(stage)-private-metadata"
        metadata.lifetime = .keepAlways
        add(metadata)
    }
}
