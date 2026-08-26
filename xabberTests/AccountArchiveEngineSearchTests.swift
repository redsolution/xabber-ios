import XCTest
@testable import xabber

final class AccountArchiveEngineSearchTests: XCTestCase {
    private let conversation = ArchiveConversationKey(
        owner: "romeo@example.org",
        jid: "juliet@example.org",
        conversationType: .regular
    )

    func testFirstPageIsOneSearchPriorityRequestAndContinuationIsExplicit() async throws {
        let transport = ArchiveSearchTransportSpy()
        let engine = makeEngine(transport: transport)
        let stream = await engine.searchStates(for: conversation)
        var states = stream.makeAsyncIterator()
        await engine.connectionDidBecomeReady(generation: 1)

        let generation = await engine.startSearch(intent(id: "q1"))
        XCTAssertEqual(generation, 1)
        guard case .loading(let loading) = await states.next() else {
            return XCTFail("Expected first-page loading state")
        }
        XCTAssertEqual(loading.requestAttempt, 1)
        let receivedFirstRequest = await waitForRequests(1, transport: transport)
        XCTAssertTrue(receivedFirstRequest)

        let recordedFirstRequest = await transport.request(at: 0)
        let firstRequest = try XCTUnwrap(recordedFirstRequest)
        XCTAssertEqual(firstRequest.request.pageCursor, nil)
        XCTAssertEqual(firstRequest.request.pageSize, ArchivePageSizing.search)
        XCTAssertEqual(firstRequest.request.pageSize, 50)
        XCTAssertEqual(firstRequest.priority, .searchCurrentPage)
        await transport.resolve(
            at: 0,
            with: .page(cursor: "cursor-1", complete: false, messageOrdinal: 1)
        )

        guard case .results(let firstPage) = await states.next() else {
            return XCTFail("Expected first search page")
        }
        XCTAssertEqual(firstPage.residentPages.count, 1)
        XCTAssertEqual(firstPage.continuationCursor, "cursor-1")
        for _ in 0..<20 { await Task.yield() }
        let requestCountBeforeContinuation = await transport.requestCount
        XCTAssertEqual(requestCountBeforeContinuation, 1, "continuation must not start automatically")

        let acceptedContinuation = await engine.requestNextSearchPage(
            conversation: conversation,
            clientQueryID: "q1"
        )
        XCTAssertTrue(acceptedContinuation)
        guard case .loading(let nextLoading) = await states.next() else {
            return XCTFail("Expected explicit continuation loading state")
        }
        XCTAssertEqual(nextLoading.requestAttempt, 2)
        let receivedSecondRequest = await waitForRequests(2, transport: transport)
        XCTAssertTrue(receivedSecondRequest)
        let recordedSecondRequest = await transport.request(at: 1)
        let secondRequest = try XCTUnwrap(recordedSecondRequest)
        XCTAssertEqual(secondRequest.request.pageCursor, "cursor-1")
        XCTAssertEqual(secondRequest.priority, .searchCurrentPage)
    }

    func testReplacementIgnoresLateReceiptFromStaleSearchGeneration() async throws {
        let transport = ArchiveSearchTransportSpy()
        let engine = makeEngine(transport: transport)
        let stream = await engine.searchStates(for: conversation)
        var states = stream.makeAsyncIterator()
        await engine.connectionDidBecomeReady(generation: 2)

        let oldGeneration = await engine.startSearch(intent(id: "old", query: "old"))
        XCTAssertEqual(oldGeneration, 1)
        guard case .loading(let oldLoading) = await states.next() else {
            return XCTFail("Expected old loading state")
        }
        XCTAssertEqual(oldLoading.clientQueryID, "old")
        let receivedOldRequest = await waitForRequests(1, transport: transport)
        XCTAssertTrue(receivedOldRequest)
        let queriesBeforeReplacement = await transport.queries
        XCTAssertEqual(queriesBeforeReplacement, ["old"])

        let newGeneration = await engine.startSearch(intent(id: "new", query: "new"))
        XCTAssertEqual(newGeneration, 2)
        guard case .loading(let newLoading) = await states.next() else {
            return XCTFail("Expected replacement loading state")
        }
        XCTAssertEqual(newLoading.clientQueryID, "new")
        let receivedReplacementRequests = await waitForRequests(2, transport: transport)
        XCTAssertTrue(receivedReplacementRequests)
        let queriesAfterReplacement = await transport.queries
        XCTAssertEqual(queriesAfterReplacement, ["old", "new"])

        await transport.resolve(
            at: 0,
            with: .page(cursor: nil, complete: true, messageOrdinal: 1)
        )
        for _ in 0..<20 { await Task.yield() }
        await transport.resolve(
            at: 1,
            with: .page(cursor: nil, complete: true, messageOrdinal: 2)
        )

        guard case .results(let result) = await states.next() else {
            return XCTFail("Expected only the replacement result")
        }
        XCTAssertEqual(result.clientQueryID, "new")
        XCTAssertEqual(result.generation, 2)
        XCTAssertEqual(result.residentMessages.map(\.primaryID), ["search-primary-2"])
    }

    func testNonAdvancingCursorFailsClosedWithoutLosingCurrentPage() async throws {
        let transport = ArchiveSearchTransportSpy()
        let engine = makeEngine(transport: transport)
        let stream = await engine.searchStates(for: conversation)
        var states = stream.makeAsyncIterator()
        await engine.connectionDidBecomeReady(generation: 3)

        _ = await engine.startSearch(intent(id: "cursor"))
        _ = await states.next()
        let receivedFirstRequest = await waitForRequests(1, transport: transport)
        XCTAssertTrue(receivedFirstRequest)
        await transport.resolve(
            at: 0,
            with: .page(cursor: "cursor-1", complete: false, messageOrdinal: 1)
        )
        guard case .results(let first) = await states.next() else {
            return XCTFail("Expected first page")
        }
        XCTAssertEqual(first.residentPages.count, 1)

        let acceptedContinuation = await engine.requestNextSearchPage(
            conversation: conversation,
            clientQueryID: "cursor"
        )
        XCTAssertTrue(acceptedContinuation)
        _ = await states.next()
        let receivedSecondRequest = await waitForRequests(2, transport: transport)
        XCTAssertTrue(receivedSecondRequest)
        await transport.resolve(
            at: 1,
            with: .page(cursor: "cursor-1", complete: false, messageOrdinal: 2)
        )

        guard case .retryableFailure(let retained, let failure) = await states.next() else {
            return XCTFail("Expected non-advancing cursor failure")
        }
        XCTAssertFalse(failure.canRetry)
        XCTAssertEqual(retained.residentPages.count, 1)
        XCTAssertEqual(retained.continuationCursor, "cursor-1")
        XCTAssertEqual(retained.residentMessages.map(\.primaryID), ["search-primary-1"])
    }

    func testTransientFailureRetainsPagesAndContinuationCursor() async throws {
        let transport = ArchiveSearchTransportSpy()
        let engine = makeEngine(transport: transport)
        let stream = await engine.searchStates(for: conversation)
        var states = stream.makeAsyncIterator()
        await engine.connectionDidBecomeReady(generation: 4)

        _ = await engine.startSearch(intent(id: "retry"))
        _ = await states.next()
        let receivedFirstRequest = await waitForRequests(1, transport: transport)
        XCTAssertTrue(receivedFirstRequest)
        await transport.resolve(
            at: 0,
            with: .page(cursor: "cursor-1", complete: false, messageOrdinal: 1)
        )
        _ = await states.next()
        let acceptedContinuation = await engine.requestNextSearchPage(
            conversation: conversation,
            clientQueryID: "retry"
        )
        XCTAssertTrue(acceptedContinuation)
        _ = await states.next()
        let receivedSecondRequest = await waitForRequests(2, transport: transport)
        XCTAssertTrue(receivedSecondRequest)
        await transport.resolve(at: 1, with: .failure(.timeout))

        guard case .retryableFailure(let retained, let failure) = await states.next() else {
            return XCTFail("Expected retryable failure")
        }
        XCTAssertTrue(failure.canRetry)
        XCTAssertEqual(retained.residentPages.count, 1)
        XCTAssertEqual(retained.continuationCursor, "cursor-1")
        XCTAssertEqual(retained.cursorStack, [""])
        XCTAssertTrue(retained.canRequestNextPage)
    }

    func testResidentSearchWindowKeepsOnlyThreePages() async throws {
        let transport = ArchiveSearchTransportSpy()
        let engine = makeEngine(transport: transport)
        let stream = await engine.searchStates(for: conversation)
        var states = stream.makeAsyncIterator()
        await engine.connectionDidBecomeReady(generation: 5)

        _ = await engine.startSearch(intent(id: "bounded"))
        var finalSnapshot: ArchiveSearchSnapshot?
        for pageIndex in 0..<4 {
            guard case .loading = await states.next() else {
                return XCTFail("Expected page loading state")
            }
            let receivedRequest = await waitForRequests(pageIndex + 1, transport: transport)
            XCTAssertTrue(receivedRequest)
            await transport.resolve(
                at: pageIndex,
                with: .page(
                    cursor: pageIndex == 3 ? nil : "cursor-\(pageIndex + 1)",
                    complete: pageIndex == 3,
                    messageOrdinal: pageIndex
                )
            )
            guard case .results(let snapshot) = await states.next() else {
                return XCTFail("Expected page result")
            }
            finalSnapshot = snapshot
            if pageIndex < 3 {
                let acceptedContinuation = await engine.requestNextSearchPage(
                    conversation: conversation,
                    clientQueryID: "bounded"
                )
                XCTAssertTrue(acceptedContinuation)
            }
        }

        let snapshot = try XCTUnwrap(finalSnapshot)
        XCTAssertEqual(snapshot.residentPages.map(\.index), [1, 2, 3])
        XCTAssertEqual(
            snapshot.residentMessages.map(\.primaryID),
            ["search-primary-1", "search-primary-2", "search-primary-3"]
        )
        XCTAssertEqual(snapshot.cursorStack, ["", "cursor-1", "cursor-2", "cursor-3"])
        XCTAssertTrue(snapshot.isComplete)
    }

    func testReconnectResumesOnlyCurrentSearchExecution() async throws {
        let transport = ArchiveSearchTransportSpy()
        let engine = makeEngine(transport: transport)
        let stream = await engine.searchStates(for: conversation)
        var states = stream.makeAsyncIterator()
        await engine.connectionDidBecomeReady(generation: 6)

        _ = await engine.startSearch(intent(id: "old", query: "old"))
        _ = await states.next()
        let receivedOldRequest = await waitForRequests(1, transport: transport)
        XCTAssertTrue(
            receivedOldRequest,
            "The replaced search must already be on the wire before reconnect semantics are exercised"
        )
        _ = await engine.startSearch(intent(id: "current", query: "current"))
        _ = await states.next()
        let receivedInitialRequests = await waitForRequests(2, transport: transport)
        XCTAssertTrue(receivedInitialRequests)

        await engine.connectionDidDisconnect()
        guard case .retryableFailure(let offline, _) = await states.next() else {
            return XCTFail("Expected current search offline state")
        }
        XCTAssertEqual(offline.clientQueryID, "current")
        await engine.connectionDidBecomeReady(generation: 7)
        guard case .loading(let resumed) = await states.next() else {
            return XCTFail("Expected reconnect loading state")
        }
        XCTAssertEqual(resumed.clientQueryID, "current")
        let receivedResumedRequest = await waitForRequests(3, transport: transport)
        XCTAssertTrue(receivedResumedRequest)

        await transport.resolve(
            at: 0,
            with: .page(cursor: nil, complete: true, messageOrdinal: 0)
        )
        await transport.resolve(
            at: 1,
            with: .page(cursor: nil, complete: true, messageOrdinal: 1)
        )
        await transport.resolve(
            at: 2,
            with: .page(cursor: nil, complete: true, messageOrdinal: 2)
        )
        guard case .results(let result) = await states.next() else {
            return XCTFail("Expected current search reconnect result")
        }
        XCTAssertEqual(result.clientQueryID, "current")
        let requestCount = await transport.requestCount
        let queries = await transport.queries
        let connectionGenerations = await transport.connectionGenerations
        XCTAssertEqual(requestCount, 3)
        XCTAssertEqual(queries, ["old", "current", "current"])
        XCTAssertEqual(connectionGenerations, [6, 6, 7])
    }

    func testReconnectResumesOnlyLatestSearchAcrossConversationsAndIgnoresLateReceipt() async throws {
        let transport = ArchiveSearchTransportSpy()
        let engine = makeEngine(transport: transport)
        let olderConversation = conversation
        let currentConversation = ArchiveConversationKey(
            owner: conversation.owner,
            jid: "mercutio@example.org",
            conversationType: .regular
        )
        let oldStates = await engine.searchStates(for: olderConversation)
        let oldStateRecorder = ArchiveSearchStateRecorder()
        let oldStateTask = Task {
            for await state in oldStates {
                await oldStateRecorder.record(state)
            }
        }
        defer { oldStateTask.cancel() }
        await engine.connectionDidBecomeReady(generation: 8)

        _ = await engine.startSearch(
            ArchiveSearchIntent(
                clientQueryID: "older-conversation-search",
                conversation: olderConversation,
                query: "older"
            )
        )
        let receivedOldRequest = await waitForRequests(1, transport: transport)
        XCTAssertTrue(
            receivedOldRequest,
            "The replaced search must already be on the wire for its later receipt to be meaningful"
        )
        _ = await engine.startSearch(
            ArchiveSearchIntent(
                clientQueryID: "current-conversation-search",
                conversation: currentConversation,
                query: "current"
            )
        )
        let receivedInitialRequests = await waitForRequests(2, transport: transport)
        XCTAssertTrue(receivedInitialRequests)

        await engine.connectionDidDisconnect()
        await engine.connectionDidBecomeReady(generation: 9)
        let receivedCurrentReconnect = await waitForRequests(3, transport: transport)
        XCTAssertTrue(receivedCurrentReconnect)

        let reconnectedQueries = await transport.requests(connectionGeneration: 9)
        XCTAssertEqual(
            reconnectedQueries.map(\.request.query),
            ["current"],
            "Reconnect must resume only the globally latest search execution"
        )
        XCTAssertEqual(
            reconnectedQueries.map(\.request.conversation),
            [Optional(currentConversation)]
        )

        await transport.resolve(
            at: 0,
            with: .page(cursor: nil, complete: true, messageOrdinal: 8)
        )
        for _ in 0..<20 { await Task.yield() }
        let staleResultCount = await oldStateRecorder.resultCount
        XCTAssertEqual(
            staleResultCount,
            0,
            "A receipt owned by the disconnected generation must not publish search results"
        )
    }

    func testGroupAdmissionCompletesBeforeSearchMAMStarts() async throws {
        let groupConversation = ArchiveConversationKey(
            owner: conversation.owner,
            jid: "stage@groups.example.org",
            conversationType: .group
        )
        let admission = ArchiveSearchAdmissionSpy()
        await admission.suspendAdmission()
        let transport = ArchiveSearchTransportSpy()
        let engine = AccountArchiveEngine(
            owner: groupConversation.owner,
            repository: ArchiveSearchRepositoryStub(),
            transport: transport,
            admissionProvider: admission,
            retryClock: .immediate
        )
        let stream = await engine.searchStates(for: groupConversation)
        var states = stream.makeAsyncIterator()
        await engine.connectionDidBecomeReady(generation: 81)

        _ = await engine.startSearch(
            ArchiveSearchIntent(
                clientQueryID: "group-search",
                conversation: groupConversation,
                query: "hello"
            )
        )
        guard case .loading = await states.next() else {
            return XCTFail("Expected group search loading state")
        }
        let receivedAdmission = await waitForAdmissions(1, admission: admission)
        XCTAssertTrue(receivedAdmission)
        let requestCountBeforeAdmission = await transport.requestCount
        XCTAssertEqual(
            requestCountBeforeAdmission,
            0,
            "Canonical group admission must finish before remote search sends MAM"
        )

        await admission.resumeAdmission()
        let receivedRequest = await waitForRequests(1, transport: transport)
        XCTAssertTrue(receivedRequest)
        await transport.resolve(
            at: 0,
            with: .page(cursor: nil, complete: true, messageOrdinal: 1)
        )
        guard case .results = await states.next() else {
            return XCTFail("Expected search results after admission")
        }
        let admissionCount = await admission.admitCount
        XCTAssertEqual(admissionCount, 1)
    }

    func testAccountWideSearchUsesNilJIDScopeAndSkipsConversationAdmission() async throws {
        let admission = ArchiveSearchAdmissionSpy()
        let transport = ArchiveSearchTransportSpy()
        let engine = AccountArchiveEngine(
            owner: conversation.owner,
            repository: ArchiveSearchRepositoryStub(),
            transport: transport,
            admissionProvider: admission,
            retryClock: .immediate
        )
        let scope = ArchiveSearchScope.account(
            owner: conversation.owner,
            conversationType: .group
        )
        let stream = await engine.searchStates(for: scope)
        var states = stream.makeAsyncIterator()
        await engine.connectionDidBecomeReady(generation: 82)

        let generation = await engine.startSearch(
            ArchiveSearchIntent(
                clientQueryID: "global-group-search",
                scope: scope,
                query: "hello"
            )
        )
        XCTAssertEqual(generation, 1)
        guard case .loading = await states.next() else {
            return XCTFail("Expected account-wide loading state")
        }
        let receivedRequest = await waitForRequests(1, transport: transport)
        XCTAssertTrue(receivedRequest)

        let optionalRecorded = await transport.request(at: 0)
        let recorded = try XCTUnwrap(optionalRecorded)
        XCTAssertEqual(recorded.request.scope, scope)
        XCTAssertNil(recorded.request.conversation)
        XCTAssertNil(recorded.request.jid)
        XCTAssertEqual(recorded.request.conversationType, .group)
        let admissionCount = await admission.admitCount
        XCTAssertEqual(admissionCount, 0)
    }

    func testAccountWideScopesShareLogicalQueryGenerationButOwnIndependentPages() async throws {
        let admission = ArchiveSearchAdmissionSpy()
        let transport = ArchiveSearchTransportSpy()
        let engine = AccountArchiveEngine(
            owner: conversation.owner,
            repository: ArchiveSearchRepositoryStub(),
            transport: transport,
            admissionProvider: admission,
            retryClock: .immediate
        )
        let regularScope = ArchiveSearchScope.account(
            owner: conversation.owner,
            conversationType: .regular
        )
        let groupScope = ArchiveSearchScope.account(
            owner: conversation.owner,
            conversationType: .group
        )
        await engine.connectionDidBecomeReady(generation: 83)

        let regularGeneration = await engine.startSearch(
            ArchiveSearchIntent(
                clientQueryID: "global-multi-scope",
                scope: regularScope,
                query: "needle"
            )
        )
        let groupGeneration = await engine.startSearch(
            ArchiveSearchIntent(
                clientQueryID: "global-multi-scope",
                scope: groupScope,
                query: "needle"
            )
        )

        XCTAssertEqual(regularGeneration, 1)
        XCTAssertEqual(groupGeneration, regularGeneration)
        let receivedRequests = await waitForRequests(2, transport: transport)
        XCTAssertTrue(receivedRequests)
        let recordedScopes = await transport.recordedScopes
        XCTAssertEqual(Set(recordedScopes), Set([regularScope, groupScope]))
        let admissionCount = await admission.admitCount
        XCTAssertEqual(admissionCount, 0)
    }

    private func makeEngine(
        transport: ArchiveSearchTransportSpy
    ) -> AccountArchiveEngine {
        AccountArchiveEngine(
            owner: conversation.owner,
            repository: ArchiveSearchRepositoryStub(),
            transport: transport,
            retryClock: .immediate
        )
    }

    private func intent(
        id: String,
        query: String = "hello"
    ) -> ArchiveSearchIntent {
        ArchiveSearchIntent(
            clientQueryID: id,
            conversation: conversation,
            query: query
        )
    }

    private func waitForRequests(
        _ count: Int,
        transport: ArchiveSearchTransportSpy
    ) async -> Bool {
        for _ in 0..<500 {
            if await transport.requestCount >= count { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return await transport.requestCount >= count
    }

    private func waitForAdmissions(
        _ count: Int,
        admission: ArchiveSearchAdmissionSpy
    ) async -> Bool {
        for _ in 0..<500 {
            if await admission.admitCount >= count { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return await admission.admitCount >= count
    }
}

private actor ArchiveSearchAdmissionSpy: ArchiveConversationAdmissionProviding {
    private(set) var admitCount = 0
    private var currentGeneration: UInt64?
    private var shouldSuspend = false
    private var continuation: CheckedContinuation<Void, Never>?

    func suspendAdmission() {
        shouldSuspend = true
    }

    func resumeAdmission() {
        shouldSuspend = false
        continuation?.resume()
        continuation = nil
    }

    func connectionDidBecomeReady(generation: UInt64) {
        currentGeneration = generation
    }

    func connectionDidDisconnect() {
        currentGeneration = nil
        continuation?.resume()
        continuation = nil
    }

    func admit(
        _ conversation: ArchiveConversationKey,
        connectionGeneration: UInt64
    ) async throws -> ArchiveConversationAdmissionResult {
        admitCount += 1
        guard currentGeneration == connectionGeneration else {
            throw ArchiveConversationAdmissionError.staleConnection
        }
        if shouldSuspend {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        return conversation.conversationType == .group ? .admitted : .notRequired
    }
}

private actor ArchiveSearchTransportSpy: ArchiveTransport {
    struct RecordedRequest: Sendable {
        let request: ArchiveSearchTransportRequest
        let priority: ArchiveIntentPriority
    }

    enum Resolution: Sendable {
        case page(cursor: String?, complete: Bool, messageOrdinal: Int)
        case failure(ArchiveTransportError)
    }

    private var requests: [RecordedRequest] = []
    private var continuations:
        [Int: CheckedContinuation<ArchiveSearchTransportReceipt, Error>] = [:]

    var requestCount: Int { requests.count }
    var queries: [String] { requests.map(\.request.query) }
    var connectionGenerations: [UInt64] {
        requests.map(\.request.connectionGeneration)
    }
    var recordedScopes: [ArchiveSearchScope] {
        requests.map(\.request.scope)
    }

    func request(at index: Int) -> RecordedRequest? {
        requests.indices.contains(index) ? requests[index] : nil
    }

    func requests(connectionGeneration: UInt64) -> [RecordedRequest] {
        requests.filter {
            $0.request.connectionGeneration == connectionGeneration
        }
    }

    func request(
        _ request: ArchiveTransportRequest,
        priority: ArchiveIntentPriority
    ) async throws -> ArchiveTransportReceipt {
        throw ArchiveTransportError.protocolViolation
    }

    func promote(
        descriptor: ArchiveIntentDescriptor,
        connectionGeneration: UInt64,
        to priority: ArchiveIntentPriority
    ) async {}

    func searchPage(
        _ request: ArchiveSearchTransportRequest,
        priority: ArchiveIntentPriority
    ) async throws -> ArchiveSearchTransportReceipt {
        let index = requests.count
        requests.append(RecordedRequest(request: request, priority: priority))
        return try await withCheckedThrowingContinuation { continuation in
            continuations[index] = continuation
        }
    }

    func resolve(at index: Int, with resolution: Resolution) {
        guard let continuation = continuations.removeValue(forKey: index),
              requests.indices.contains(index) else {
            return
        }
        let request = requests[index].request
        switch resolution {
        case .failure(let error):
            continuation.resume(throwing: error)
        case .page(let cursor, let complete, let ordinal):
            let messages = [Self.message(
                ordinal: ordinal,
                scope: request.scope
            )]
            continuation.resume(returning: ArchiveSearchTransportReceipt(
                queryID: request.queryID,
                connectionGeneration: request.connectionGeneration,
                messages: messages,
                first: cursor ?? "",
                last: messages[0].archiveID,
                complete: complete,
                deliveredResultCount: messages.count,
                persistedResultCount: messages.count,
                failedPersistenceCount: 0,
                finalReceived: true
            ))
        }
    }

    private static func message(
        ordinal: Int,
        scope: ArchiveSearchScope
    ) -> ArchiveSearchMessage {
        let conversation = scope.conversation ?? ArchiveConversationKey(
            owner: scope.owner,
            jid: "global-result-\(ordinal)@example.org",
            conversationType: scope.conversationType
        )
        return ArchiveSearchMessage(
            primaryID: "search-primary-\(ordinal)",
            archiveID: "\(ordinal + 1)",
            messageID: "search-message-\(ordinal)",
            owner: conversation.owner,
            conversationJID: conversation.jid,
            conversationTypeRaw: conversation.conversationType.rawValue,
            body: "result \(ordinal)",
            date: Date(timeIntervalSince1970: TimeInterval(ordinal)),
            outgoing: false,
            deliveryStateRaw: 0,
            groupAuthorID: nil,
            groupAuthorNickname: nil,
            groupAuthorAvatarURL: nil
        )
    }
}

private actor ArchiveSearchStateRecorder {
    private var states: [ArchiveSearchState] = []

    var resultCount: Int {
        states.reduce(into: 0) { count, state in
            if case .results = state {
                count += 1
            }
        }
    }

    func record(_ state: ArchiveSearchState) {
        states.append(state)
    }
}

private actor ArchiveSearchRepositoryStub: ArchiveCoverageRepository {
    func verifiedAdmission(
        for intent: ArchiveWindowIntent,
        freshnessToken: ArchiveFreshnessToken
    ) async throws -> ArchiveRepositoryAdmission? {
        nil
    }

    func commit(
        _ page: ValidatedArchiveTransportPage,
        request: ArchiveTransportRequest,
        freshnessToken: ArchiveFreshnessToken
    ) async throws -> ArchiveRepositoryCommit {
        throw ArchiveTransportError.protocolViolation
    }

    func commitAnchorWindow(
        intent: ArchiveWindowIntent,
        anchor: ArchiveMaterializedAnchor,
        exactPage: ValidatedArchiveTransportPage,
        olderPage: ValidatedArchiveTransportPage,
        newerPage: ValidatedArchiveTransportPage,
        freshnessToken: ArchiveFreshnessToken
    ) async throws -> ArchiveWindowSnapshot {
        throw ArchiveTransportError.protocolViolation
    }

    func materializedAnchor(
        conversation: ArchiveConversationKey,
        locator: ArchiveWindowLocator,
        candidateArchiveIDs: [String]
    ) async throws -> ArchiveMaterializedAnchor? {
        nil
    }

    func extendLiveEdge(
        for intent: ArchiveWindowIntent,
        primaryID: String,
        freshnessToken: ArchiveFreshnessToken
    ) async throws -> ArchiveWindowSnapshot? {
        nil
    }
}
