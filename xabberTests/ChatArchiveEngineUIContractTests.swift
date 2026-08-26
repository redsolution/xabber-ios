import XCTest
@testable import xabber

@MainActor
final class ChatArchiveEngineUIContractTests: XCTestCase {
    func testHistoryRecoveryAffordanceTypesAndControllerPlumbingAreAbsent() throws {
        let archiveSource = try archiveEngineSource()
        let controllerSource = try chatViewControllerSource()

        for forbidden in [
            "ChatArchiveEngineRetryView",
            "ChatArchiveBoundaryRetryView",
            "archiveEngineRetryView",
            "archiveBoundaryRetryView",
            "presentArchiveBoundaryRetry(",
            "dismissArchiveBoundaryRetry()",
        ] {
            XCTAssertFalse(archiveSource.contains(forbidden), forbidden)
            XCTAssertFalse(controllerSource.contains(forbidden), forbidden)
        }
    }

    func testVisibleArchiveCriticalSectionAcquiresAndReleasesAccountGate() throws {
        let owner = "archive-gate-(UUID().uuidString)@example.org"
        AccountManager.shared.add(withJid: owner, autoConnect: false)
        let account = try XCTUnwrap(AccountManager.shared.find(for: owner))
        let controller = ChatViewController()
        controller.owner = owner
        controller.jid = "juliet@example.org"
        controller.conversationType = .regular

        controller.beginArchiveInteractiveCriticalSection()

        XCTAssertEqual(account.interactiveChatOpenGate.activeTokenCount, 1)
        XCTAssertTrue(account.interactiveChatOpenGate.isActive)

        controller.endArchiveInteractiveCriticalSection()

        XCTAssertEqual(account.interactiveChatOpenGate.activeTokenCount, 0)
        XCTAssertFalse(account.interactiveChatOpenGate.isActive)
    }

    func testOpeningAndTargetArchivePathsOwnTheVisibleCriticalSection() throws {
        let source = try archiveEngineSource()

        XCTAssertTrue(
            source.contains("beginArchiveInteractiveCriticalSection()"),
            "Visible opening/target/paging must synchronously acquire the account scheduler gate"
        )
        XCTAssertTrue(
            source.contains("endArchiveInteractiveCriticalSection()"),
            "UIKit terminal/failure/teardown must release the account scheduler gate"
        )

        for marker in [
            "internal func startArchiveEnginePresentationIfNeeded()",
            "internal func submitArchiveEngineLatestTarget()",
            "internal func submitArchiveEngineTarget(",
        ] {
            let method = try sourceMethod(named: marker, in: source)
            let acquire = try XCTUnwrap(
                method.range(of: "beginArchiveInteractiveCriticalSection()")
            )
            let skeletonApply = try XCTUnwrap(
                method.range(of: "commitArchiveEngineOpeningSkeletonSynchronously()")
            )
            XCTAssertLessThan(
                acquire.lowerBound,
                skeletonApply.lowerBound,
                marker
            )
        }
    }

    func testOpeningAndTeardownAttachAndDetachPresentationDemand() throws {
        let source = try archiveEngineSource()
        let controllerSource = try chatViewControllerSource()

        XCTAssertTrue(
            source.contains("attachPresentationDemand("),
            "A visible chat must explicitly own ArchiveEngine reconnect demand"
        )
        XCTAssertTrue(
            source.contains("detachPresentationDemand("),
            "Controller teardown must remove reconnect demand without cancelling persistence"
        )
        XCTAssertTrue(
            source.contains("await demandTask?.value"),
            "Detach must serialize behind an in-flight attach task"
        )
        let start = try XCTUnwrap(
            source.range(of: "internal func startArchiveEnginePresentationIfNeeded")
        )
        let startTail = source[start.lowerBound...]
        let skeletonCommit = try XCTUnwrap(
            startTail.range(of: "commitArchiveEngineOpeningSkeletonSynchronously()")
        )
        let attach = try XCTUnwrap(startTail.range(of: "attachPresentationDemand("))
        let submit = try XCTUnwrap(startTail.range(of: "submit(intent)"))
        XCTAssertLessThan(skeletonCommit.lowerBound, attach.lowerBound)
        XCTAssertLessThan(skeletonCommit.lowerBound, submit.lowerBound)
        XCTAssertLessThan(attach.lowerBound, submit.lowerBound)

        let detach = try XCTUnwrap(
            source.range(of: "internal func detachArchiveEnginePresentationDemand")
        )
        let detachTail = source[detach.lowerBound...]
        let detachEnd = detachTail.range(
            of: "internal func stopArchiveEnginePresentationSubscription"
        )?.lowerBound ?? detachTail.endIndex
        let detachMethod = String(detachTail[..<detachEnd])
        XCTAssertTrue(detachMethod.contains("archiveEnginePresentationDemandConversation"))
        XCTAssertTrue(detachMethod.contains("archiveEnginePresentationDemandEngine"))
        XCTAssertFalse(detachMethod.contains("archiveEngineConversationKey"))
        XCTAssertFalse(detachMethod.contains("AccountManager.shared.find"))
        XCTAssertTrue(
            controllerSource.contains("self.detachArchiveEnginePresentationDemand()"),
            "deinit must remove demand even when navigation cleanup was skipped"
        )
    }

    func testSearchPresentationReplacesEvictedResidentPageInsteadOfAppendingForever() throws {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.inSearchMode.accept(true)
        controller.reduceSearchPresentationState(.activate)
        controller.reduceSearchPresentationState(.queryChanged("needle"))
        _ = try XCTUnwrap(
            controller.beginInChatSearchQueryIfNeeded(
                text: "needle",
                queryId: "engine-search"
            )
        )
        let scope = ChatSearchSession.Scope(
            owner: controller.owner,
            jid: controller.jid,
            conversationTypeRawValue: controller.conversationType.rawValue,
            isEncrypted: false
        )
        _ = controller.searchSession.accept(query: "needle", scope: scope)
        _ = controller.searchSession.flush()
        let sessionGeneration = controller.searchSession.generation
        controller.searchSessionGenerationByQueryId["engine-search"] = sessionGeneration

        controller.receiveArchiveEngineSearchState(
            .results(snapshot(pageIndices: [0, 1, 2]))
        )
        XCTAssertEqual(
            Set(controller.searchResultPresentations.map(\.anchor.archivedId)),
            Set(["100", "101", "102"])
        )

        controller.receiveArchiveEngineSearchState(
            .results(snapshot(pageIndices: [1, 2, 3]))
        )

        XCTAssertEqual(
            Set(controller.searchResultPresentations.map(\.anchor.archivedId)),
            Set(["101", "102", "103"]),
            "The UI must mirror the engine's bounded resident pages and remove an evicted page"
        )
        XCTAssertFalse(
            controller.searchMessagesQueue.contains { $0.archivedId == "100" },
            "An engine-evicted result must not survive in the legacy presentation queue"
        )
    }

    func testTerminalRetryableFailureSchedulesEngineOwnedAutomaticRetry() throws {
        let source = try archiveEngineSource()

        let stateHandler = try XCTUnwrap(source.range(of: "private func receiveArchiveWindowState"))
        let handlerTail = source[stateHandler.lowerBound...]
        let handlerEnd = handlerTail.range(of: "private func receiveArchiveWindowActivity")?.lowerBound
            ?? handlerTail.endIndex
        let handler = String(handlerTail[..<handlerEnd])

        XCTAssertTrue(
            handler.contains("case .retryableFailure"),
            "The state reducer must distinguish terminal failure from ordinary loading skeleton"
        )
        XCTAssertTrue(
            handler.contains("scheduleArchiveHistoryAutomaticRetry("),
            "The retryable-failure branch must schedule actor-owned automatic backoff"
        )
        XCTAssertFalse(handler.contains("archiveEngineRetryView.present"))
        XCTAssertFalse(handler.contains("presentArchiveBoundaryRetry("))

        let scheduler = try XCTUnwrap(
            source.range(of: "private func scheduleArchiveHistoryAutomaticRetry")
        )
        let schedulerTail = source[scheduler.lowerBound...]
        let schedulerEnd = schedulerTail.range(
            of: "internal func submitArchiveEngineLatestTarget"
        )?.lowerBound ?? schedulerTail.endIndex
        let schedulerMethod = String(schedulerTail[..<schedulerEnd])
        XCTAssertTrue(schedulerMethod.contains("asyncAfter"))
        XCTAssertTrue(schedulerMethod.contains("archiveEngine.retry(conversation:"))
        XCTAssertFalse(schedulerMethod.contains("requestTimelineBoundary("))
    }

    private func makeController() -> ChatViewController {
        let controller = ChatViewController()
        controller.owner = "romeo@example.org"
        controller.jid = "juliet@example.org"
        controller.conversationType = .regular
        return controller
    }

    private func snapshot(pageIndices: [Int]) -> ArchiveSearchSnapshot {
        ArchiveSearchSnapshot(
            clientQueryID: "engine-search",
            generation: 1,
            query: "needle",
            residentPages: pageIndices.map { index in
                ArchiveSearchPage(
                    index: index,
                    requestCursor: index == 0 ? nil : "cursor-\(index)",
                    continuationCursor: "cursor-\(index + 1)",
                    messages: [message(index: index)],
                    isComplete: false
                )
            },
            cursorStack: [""],
            requestAttempt: pageIndices.count,
            continuationCursor: "cursor-next",
            isComplete: false,
            isLoading: false
        )
    }

    private func message(index: Int) -> ArchiveSearchMessage {
        ArchiveSearchMessage(
            primaryID: "primary-\(index)",
            archiveID: "\(100 + index)",
            messageID: "message-\(index)",
            owner: "romeo@example.org",
            conversationJID: "juliet@example.org",
            conversationTypeRaw: ClientSynchronizationManager.ConversationType.regular.rawValue,
            body: "needle \(index)",
            date: Date(timeIntervalSince1970: TimeInterval(100 + index)),
            outgoing: false,
            deliveryStateRaw: MessageStorageItem.MessageSendingState.sended.rawValue,
            groupAuthorID: nil,
            groupAuthorNickname: nil,
            groupAuthorAvatarURL: nil
        )
    }

    private func archiveEngineSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(
                "xabber/controllers/chats/chat/extension/ChatViewController+ArchiveEngine.swift"
            ),
            encoding: .utf8
        )
    }

    private func chatViewControllerSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(
                "xabber/controllers/chats/chat/ChatViewController.swift"
            ),
            encoding: .utf8
        )
    }

    private func sourceMethod(
        named marker: String,
        in source: String
    ) throws -> String {
        let markerRange = try XCTUnwrap(source.range(of: marker))
        let openingBrace = try XCTUnwrap(
            source[markerRange.lowerBound...].firstIndex(of: "{")
        )
        var depth = 0
        var cursor = openingBrace
        while cursor < source.endIndex {
            switch source[cursor] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(source[markerRange.lowerBound...cursor])
                }
            default:
                break
            }
            cursor = source.index(after: cursor)
        }
        XCTFail("Unterminated source method: \(marker)")
        return ""
    }
}
