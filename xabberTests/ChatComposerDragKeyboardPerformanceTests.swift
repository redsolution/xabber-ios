//
//  ChatComposerDragKeyboardPerformanceTests.swift
//  xabberTests
//
//  Created by Codex on 10.07.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import UIKit
import XMPPFramework
import XCTest
@testable import xabber

@MainActor
final class ChatComposerDragKeyboardPerformanceTests: XCTestCase {
    func testCancelHintStaysOutOfTimerRegionAndFadesDuringLeftDrag() {
        let resting = RecordingCancelHintVisualPolicy.visualState(translationX: 0)
        let partial = RecordingCancelHintVisualPolicy.visualState(translationX: -60)
        let cancellation = RecordingCancelHintVisualPolicy.visualState(translationX: -120)

        XCTAssertEqual(partial.originX, resting.originX, accuracy: 0.001)
        XCTAssertEqual(cancellation.originX, resting.originX, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(resting.originX, RecordingCancelHintVisualPolicy.minimumOriginX)
        XCTAssertLessThan(partial.alpha, resting.alpha)
        XCTAssertEqual(cancellation.alpha, 0, accuracy: 0.001)
    }

    func testKeyboardFrameAwayFromBottomSkipsAnchorCaptureAndSynchronousRestoration() {
        XCTAssertFalse(ChatKeyboardFrameViewportPolicy.shouldCaptureVisibleAnchor(wasNearBottom: false))
        XCTAssertEqual(
            ChatKeyboardFrameViewportPolicy.anchorRestoration(wasNearBottom: false),
            .none
        )

        let actions = ChatComposerFrameUpdatePlanner.actions(
            for: ChatComposerFrameUpdateRequest(
                source: .keyboardFrame,
                hasMessages: true,
                previousInputHeight: 88,
                inputHeight: 380,
                anchorRestoration: ChatKeyboardFrameViewportPolicy.anchorRestoration(wasNearBottom: false)
            )
        )

        XCTAssertFalse(actions.contains(.layoutIfNeeded))
        XCTAssertFalse(actions.contains(.restoreVisibleAnchor))
        XCTAssertEqual(actions.filter { $0 == .updateInsets(380) }.count, 1)
    }

    func testKeyboardHeightOnlyBoundsChangeDoesNotResetRecordingGeometry() {
        XCTAssertFalse(ComposerRecordingGeometryResetPolicy.shouldReset(
            previousWidth: 390,
            nextWidth: 390
        ))
        XCTAssertTrue(ComposerRecordingGeometryResetPolicy.shouldReset(
            previousWidth: 390,
            nextWidth: 844
        ))
    }

    func testRecordingStateChangeDoesNotForceSynchronousLayoutPass() {
        let inputView = LayoutCountingInputView(frame: CGRect(
            x: 0,
            y: 0,
            width: 390,
            height: ModernXabberInputView.defaultBarHeight
        ))
        inputView.layoutIfNeeded()
        inputView.resetLayoutPassCount()

        inputView.changeState(to: .record)

        XCTAssertEqual(inputView.layoutPassCount, 0)
    }

    func testAccountAsyncConnectDoesNotPrepareOrStartXMPPOnMainThread() {
        let xmppQueue = DispatchQueue(label: "ChatComposerDragKeyboardPerformanceTests.xmpp")
        let account = Account(jid: "composer-performance@example.com", queue: xmppQueue)
        let stream = ThreadCapturingXMPPStream()
        let connected = expectation(description: "XMPP connect was enqueued")
        account.xmppStream = stream
        stream.onConnect = { wasMainThread in
            XCTAssertFalse(wasMainThread)
            connected.fulfill()
        }

        account.asyncConnect(trigger: .initialLoad)

        wait(for: [connected], timeout: 1)
        let queueDrained = expectation(description: "Account queue finished the connect request")
        xmppQueue.async {
            queueDrained.fulfill()
        }
        wait(for: [queueDrained], timeout: 1)
        AccountManager.shared.markAsNotConnecting(
            jid: account.jid,
            reason: "composer-performance-test-cleanup",
            clearAuthentication: true
        )
        let mainQueueDrained = expectation(description: "Main-thread relay updates finished")
        DispatchQueue.main.async {
            mainQueueDrained.fulfill()
        }
        wait(for: [mainQueueDrained], timeout: 1)
    }

    func testPresenceBatchAccumulatorDefaultDeliveryDoesNotRunOnMainThread() throws {
        let delivered = expectation(description: "Presence batch was delivered")
        let accumulator = PresenceBatchAccumulator(
            flushInterval: 0,
            batchSize: 1,
            capacity: 8
        ) { _, presences in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertEqual(presences.count, 1)
            delivered.fulfill()
        }

        let presence = try XCTUnwrap(
            XMPPPresence(xmlString: "<presence from='contact@example.com/ios'><show>chat</show></presence>")
        )
        XCTAssertTrue(accumulator.enqueue(presence))

        wait(for: [delivered], timeout: 1)
    }
}

@MainActor
private final class LayoutCountingInputView: ModernXabberInputView {
    private(set) var layoutPassCount = 0

    override func layoutSubviews() {
        layoutPassCount += 1
        super.layoutSubviews()
    }

    func resetLayoutPassCount() {
        layoutPassCount = 0
    }
}

private final class ThreadCapturingXMPPStream: XMPPStream {
    var onConnect: ((Bool) -> Void)?

    override func connect(withTimeout timeout: TimeInterval) throws {
        onConnect?(Thread.isMainThread)
    }
}
