//
//  ChatSearchStressStateTests.swift
//  xabberTests
//
//  Created by Codex on 14.07.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import XCTest
import RealmSwift
import UIKit
import XMPPFramework
@testable import xabber

@MainActor
final class ChatSearchStressStateTests: XCTestCase {
    func testOneHundredQueryReplacementsCommitOnlyLatestGeneration() throws {
        var session = ChatSearchSession()
        var requests: [ChatSearchSession.Request] = []
        let queries = ["t", "te", "tes", "test"] + (4..<100).map { "test-\($0)" }

        for query in queries {
            let effects = session.accept(query: query, scope: regularScope)
            let request = try XCTUnwrap(scheduledRequest(in: effects))
            requests.append(request)
            XCTAssertEqual(
                session.flush(),
                [.cancelDebounce(generation: request.generation), .startProviderRequest(request)]
            )
        }

        for request in requests.dropLast() {
            XCTAssertFalse(
                session.receive(.result(generation: request.generation, id: .archived("stale")))
            )
            XCTAssertFalse(session.receive(.finished(generation: request.generation)))
        }
        let latest = try XCTUnwrap(requests.last)
        XCTAssertTrue(
            session.receive(.result(generation: latest.generation, id: .archived("latest")))
        )
        XCTAssertTrue(session.receive(.finished(generation: latest.generation)))

        XCTAssertEqual(session.generation, 100)
        XCTAssertEqual(session.normalizedQuery, "test-99")
        XCTAssertEqual(session.resultCount, 1)
        XCTAssertEqual(session.providerPhase, .finished)
        XCTAssertFalse(session.isProviderSearching)
    }

    func testCancelBeforeDebounceAndFailedRetryHaveSingleCurrentRequest() throws {
        var session = ChatSearchSession()
        let cancelled = try XCTUnwrap(
            scheduledRequest(in: session.accept(query: "test", scope: regularScope))
        )

        XCTAssertEqual(
            session.cancel(),
            [.cancelDebounce(generation: cancelled.generation)]
        )
        XCTAssertTrue(session.debounceElapsed(generation: cancelled.generation).isEmpty)
        XCTAssertEqual(session.providerPhase, .idle)

        let first = try XCTUnwrap(
            scheduledRequest(in: session.accept(query: "test", scope: regularScope))
        )
        _ = session.flush()
        XCTAssertTrue(session.receive(.failed(generation: first.generation)))

        let retry = try XCTUnwrap(
            scheduledRequest(in: session.accept(query: "test", scope: regularScope))
        )
        XCTAssertGreaterThan(retry.generation, first.generation)
        XCTAssertEqual(session.providerPhase, .debouncing)
        XCTAssertFalse(session.receive(.failed(generation: first.generation)))
    }

    func testCancelBetweenArchiveFinalAndPersistenceSuppressesCompletion() {
        var session = ChatSearchArchiveSession(generation: 7, queryId: "stress-mam")

        XCTAssertTrue(
            session.receiveFinal(
                generation: 7,
                queryId: "stress-mam",
                complete: true,
                first: "10",
                last: "20",
                serverResultCount: 10
            )
        )
        XCTAssertEqual(
            session.cancel(),
            .cancelled(resultCount: 0, pageCount: 0)
        )
        XCTAssertNil(
            session.commitPersistedPage(
                generation: 7,
                queryId: "stress-mam",
                persistedMessageCount: 10
            )
        )
        XCTAssertEqual(
            session.terminal,
            .cancelled(resultCount: 0, pageCount: 0)
        )
    }

    func testRepeatedCursorProducesExactlyOneTruncatedTerminal() {
        var session = ChatSearchArchiveSession(generation: 8, queryId: "stress-cursor")

        XCTAssertTrue(
            session.receiveFinal(
                generation: 8,
                queryId: "stress-cursor",
                complete: false,
                first: "cursor",
                last: "newer",
                serverResultCount: 1
            )
        )
        XCTAssertEqual(
            session.commitPersistedPage(
                generation: 8,
                queryId: "stress-cursor",
                persistedMessageCount: 1
            ),
            .requestNext(cursor: "cursor")
        )
        XCTAssertTrue(
            session.receiveFinal(
                generation: 8,
                queryId: "stress-cursor",
                complete: false,
                first: "cursor",
                last: "newer",
                serverResultCount: 1
            )
        )
        let terminal = ChatSearchArchiveSession.Terminal.truncated(
            reason: .repeatedCursor,
            resultCount: 0,
            pageCount: 2
        )
        XCTAssertEqual(
            session.commitPersistedPage(
                generation: 8,
                queryId: "stress-cursor",
                persistedMessageCount: 0
            ),
            .terminal(terminal)
        )
        XCTAssertFalse(
            session.receiveFinal(
                generation: 8,
                queryId: "stress-cursor",
                complete: false,
                first: "cursor",
                last: "newer",
                serverResultCount: 1
            )
        )
        XCTAssertNil(
            session.commitPersistedPage(
                generation: 8,
                queryId: "stress-cursor",
                persistedMessageCount: 1
            )
        )
        XCTAssertEqual(session.terminal, terminal)
    }

    func testLocalCancelBetweenBatchesEmitsOneTypedTerminalAndNoLaterBatch() throws {
        let configuration = Realm.Configuration(
            inMemoryIdentifier: "ChatSearchStressStateTests-local-\(UUID().uuidString)"
        )
        let realm = try Realm(configuration: configuration)
        try realm.write {
            realm.add((0..<130).map(makeEncryptedMessage))
        }
        let provider = ChatSearchLocalProvider(
            realmConfiguration: configuration,
            batchSize: 8
        )
        let request = localRequest(generation: 11, queryId: "stress-local")
        let cancelled = expectation(description: "typed cancellation")
        let quietPeriod = expectation(description: "no stale local batch")
        var batchCount = 0
        var terminalCount = 0

        provider.search(request) { event in
            switch event.phase {
            case .batch:
                batchCount += 1
                if batchCount == 1 {
                    XCTAssertTrue(
                        provider.cancel(
                            queryId: request.queryId,
                            generation: request.generation
                        )
                    )
                }
            case .cancelled:
                terminalCount += 1
                cancelled.fulfill()
                DispatchQueue.main.async {
                    quietPeriod.fulfill()
                }
            case .completed, .failed:
                XCTFail("Cancelled local request must not publish another terminal")
            }
        }

        wait(for: [cancelled, quietPeriod], timeout: 2)
        XCTAssertEqual(batchCount, 1)
        XCTAssertEqual(terminalCount, 1)
        XCTAssertFalse(provider.cancel(queryId: request.queryId, generation: request.generation))
        _ = realm
    }

    func testTimestampReplacementAndCancelEachDeliverOneTerminal() {
        let harness = StressTimestampHarness()
        let resolver = ChatSearchTimestampMAMResolver(dependencies: harness.dependencies)
        let requestID = UUID()
        var firstOutcomes: [ChatSearchTimestampMAMResolutionOutcome] = []
        var secondOutcomes: [ChatSearchTimestampMAMResolutionOutcome] = []

        resolver.resolve(timestampFallback, requestID: requestID, generation: 1) {
            firstOutcomes.append($0)
        }
        let stale = harness.attempts[0]
        resolver.resolve(timestampFallback, requestID: requestID, generation: 2) {
            secondOutcomes.append($0)
        }

        XCTAssertEqual(firstOutcomes, [.cancelled])
        XCTAssertEqual(harness.cancelledQueryIDs, [stale.plan.queryId])
        XCTAssertTrue(resolver.cancel(requestID: requestID))
        XCTAssertEqual(secondOutcomes, [.cancelled])

        stale.callbacks.onEndPage?(
            stale.plan.queryId,
            MessageArchivePageEndState(
                queryExhausted: true,
                archiveEnded: false,
                persistedMessageCount: 0,
                requestCursorId: nil
            ),
            "",
            "",
            0
        )
        XCTAssertEqual(firstOutcomes, [.cancelled])
        XCTAssertEqual(secondOutcomes, [.cancelled])
        XCTAssertEqual(harness.attempts.count, 2)
    }

    func testOneHundredAlternatingArrowIntentsCoalesceToLastValidTarget() {
        let controller = ChatViewController()
        controller.searchMessagesQueue = (0..<5).map { index in
            let item = MessageStorageItem()
            item.primary = "arrow-\(index)"
            return item
        }
        controller.searchResultNavigationState = .positioning(index: 2)

        for index in 0..<100 {
            index.isMultiple(of: 2)
                ? controller.onSearchPanelSeekUp()
                : controller.onSearchPanelSeekDown()
        }

        XCTAssertEqual(
            controller.searchResultNavigationState,
            .pending(index: 2, scrollDirection: .down)
        )
        XCTAssertEqual(
            controller.consumePendingSearchResultNavigation(finishedIndex: 1),
            ChatSearchPendingNavigation(index: 2, scrollDirection: .down)
        )
        XCTAssertEqual(controller.searchResultNavigationState, .idle)
    }

    func testTwentyRapidListTransitionsSettleAtLastModeWithoutSnapshotOrDisabledHitTesting() {
        let factory = StressAnimatorFactory()
        let coordinator = ChatSearchModeTransitionCoordinator(animatorFactory: factory)
        let host = StressModeHost()
        var finalModes: [ChatSearchModeTransitionPlan.Mode] = []

        for index in 0..<20 {
            let mode: ChatSearchModeTransitionPlan.Mode = index.isMultiple(of: 2) ? .list : .chat
            coordinator.transition(
                to: mode,
                generation: 22,
                animated: true,
                animationSpec: .production,
                containerView: host.container,
                listContentView: host.list,
                timelineView: host.timeline,
                isGenerationCurrent: { $0 == 22 },
                bringChromeToFront: {},
                applyFinalMode: { finalModes.append($0) }
            )
        }
        factory.finishAll()

        XCTAssertEqual(coordinator.requestedMode, .chat)
        XCTAssertEqual(coordinator.settledMode, .chat)
        XCTAssertEqual(coordinator.activeOverlayCount, 0)
        XCTAssertFalse(coordinator.isTransitioning)
        XCTAssertTrue(host.list.isHidden)
        XCTAssertFalse(host.list.isUserInteractionEnabled)
        XCTAssertFalse(host.timeline.isHidden)
        XCTAssertTrue(host.timeline.isUserInteractionEnabled)
        XCTAssertEqual(finalModes.last, .chat)
    }

    func testTwentyRapidCalendarTransitionsSettleDismissedWithoutDimOrChild() {
        let factory = StressAnimatorFactory()
        let controller = ChatSearchCalendarViewController(
            model: ChatSearchCalendarModel(
                calendar: stressCalendar,
                locale: Locale(identifier: "en_US_POSIX"),
                clock: StressCalendarClock(now: Date(timeIntervalSince1970: 1_784_044_800))
            ),
            animationSpec: .production,
            animatorFactory: factory,
            prefersNativeGlass: false
        )
        let host = StressCalendarHost()
        controller.install(in: host.parent, containerView: host.parent.view)

        for index in 0..<20 {
            if index.isMultiple(of: 2) {
                controller.present(
                    generation: 23,
                    animated: true,
                    focusReturnView: nil,
                    isGenerationCurrent: { $0 == 23 }
                )
            } else {
                controller.dismiss(
                    generation: 23,
                    animated: true,
                    isGenerationCurrent: { $0 == 23 },
                    completion: nil
                )
            }
        }
        factory.finishAll()

        XCTAssertEqual(controller.requestedState, .dismissed)
        XCTAssertEqual(controller.settledState, .dismissed)
        XCTAssertEqual(controller.activeOverlayCount, 0)
        XCTAssertNil(controller.parent)
        XCTAssertNil(controller.view.superview)
        XCTAssertFalse(controller.dimView.isUserInteractionEnabled)
        XCTAssertFalse(controller.calendarView.isUserInteractionEnabled)
    }

    private var regularScope: ChatSearchSession.Scope {
        ChatSearchSession.Scope(
            owner: "owner@example.com",
            jid: "andrew@example.com",
            conversationTypeRawValue: ClientSynchronizationManager.ConversationType.regular.rawValue,
            isEncrypted: false
        )
    }

    private func scheduledRequest(
        in effects: [ChatSearchSession.Effect]
    ) -> ChatSearchSession.Request? {
        effects.compactMap { effect in
            guard case .scheduleDebounce(let request, _) = effect else { return nil }
            return request
        }.first
    }

    private func localRequest(
        generation: UInt64,
        queryId: String
    ) -> ChatSearchLocalProvider.Request {
        ChatSearchLocalProvider.Request(
            generation: generation,
            queryId: queryId,
            query: "test",
            mappingContext: ChatSearchResultMappingContext(
                scope: ChatSearchResult.Scope(
                    owner: "owner@example.com",
                    jid: "andrew@example.com",
                    conversationTypeRawValue: ClientSynchronizationManager.ConversationType.omemo.rawValue
                ),
                localizedYou: "You",
                contactDisplayName: "Andrew Nenakhov"
            )
        )
    }

    private func makeEncryptedMessage(_ index: Int) -> MessageStorageItem {
        let item = MessageStorageItem()
        item.primary = "local-\(index)"
        item.archivedId = "\(index)"
        item.owner = "owner@example.com"
        item.opponent = "andrew@example.com"
        item.conversationType = .omemo
        item.body = "test \(index)"
        item.date = Date(timeIntervalSince1970: TimeInterval(index))
        return item
    }

    private var timestampFallback: ChatSearchTimestampRemoteFallback {
        ChatSearchTimestampRemoteFallback(
            scope: ChatSearchResult.Scope(
                owner: "owner@example.com",
                jid: "andrew@example.com",
                conversationTypeRawValue: ClientSynchronizationManager.ConversationType.regular.rawValue
            ),
            selectedTimestamp: Date(timeIntervalSince1970: 1_784_044_800),
            localCandidates: []
        )
    }

    private var stressCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 1
        return calendar
    }
}

private final class StressTimestampHarness {
    struct Attempt {
        let plan: ChatSearchTimestampMAMRequestPlan
        let callbacks: MessageArchiveManager.RequestCallbacks
    }

    private(set) var attempts: [Attempt] = []
    private(set) var cancelledQueryIDs: [String] = []

    var dependencies: ChatSearchTimestampMAMResolver.Dependencies {
        .init(
            start: { [weak self] plan, callbacks in
                self?.attempts.append(Attempt(plan: plan, callbacks: callbacks))
                return self != nil
            },
            cancel: { [weak self] queryID in
                self?.cancelledQueryIDs.append(queryID)
            }
        )
    }
}

@MainActor
private final class StressAnimatorFactory: ChatSearchModeAnimatorFactory {
    private(set) var animators: [StressAnimator] = []

    func makeAnimator(
        timing: ChatSearchAnimationSpec.Timing,
        animations: @escaping () -> Void
    ) -> ChatSearchModeAnimating {
        let animator = StressAnimator(animations: animations)
        animators.append(animator)
        return animator
    }

    func finishAll() {
        animators.filter { !$0.didFinish }.forEach {
            $0.finishAnimation(at: .end)
        }
    }
}

@MainActor
private final class StressAnimator: ChatSearchModeAnimating {
    private let animations: () -> Void
    private var completions: [(UIViewAnimatingPosition) -> Void] = []
    private(set) var didFinish = false

    init(animations: @escaping () -> Void) {
        self.animations = animations
    }

    func addCompletion(_ completion: @escaping (UIViewAnimatingPosition) -> Void) {
        completions.append(completion)
    }

    func startAnimation() {
        animations()
    }

    func stopAnimation(_ withoutFinishing: Bool) {}

    func finishAnimation(at finalPosition: UIViewAnimatingPosition) {
        guard !didFinish else { return }
        didFinish = true
        completions.forEach { $0(finalPosition) }
    }
}

@MainActor
private final class StressModeHost {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    let timeline = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    let list = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))

    init() {
        list.isHidden = true
        list.addSubview(UILabel(frame: CGRect(x: 16, y: 100, width: 100, height: 30)))
        container.addSubview(timeline)
        container.addSubview(list)
        window.addSubview(container)
        window.isHidden = false
        container.layoutIfNeeded()
    }
}

private struct StressCalendarClock: ChatSearchCalendarClock {
    let now: Date
}

@MainActor
private final class StressCalendarHost {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    let parent = UIViewController()

    init() {
        window.rootViewController = parent
        window.isHidden = false
        parent.loadViewIfNeeded()
        parent.view.frame = window.bounds
        parent.view.layoutIfNeeded()
    }
}
