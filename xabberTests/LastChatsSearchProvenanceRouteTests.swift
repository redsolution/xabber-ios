import XCTest
@testable import xabber

final class LastChatsSearchProvenanceRouteTests: XCTestCase {
    private let conversation = LastChatsSearchConversation(
        owner: "owner@example.com",
        jid: "room@example.com",
        conversationTypeRawValue: ClientSynchronizationManager.ConversationType.group.rawValue
    )
    private let date = Date(timeIntervalSince1970: 1_711_283_200)

    func testSearchDismissalWaitsForCompactPushSourceToDisappear() {
        XCTAssertEqual(
            LastChatsSearchDismissalPolicy.timing(
                for: .opensNewChat,
                route: .currentNavigationPush
            ),
            .afterSourceDidDisappear
        )
    }

    func testSearchDismissalIsImmediateWhenRouteDoesNotCoverSource() {
        XCTAssertEqual(
            LastChatsSearchDismissalPolicy.timing(
                for: .opensNewChat,
                route: .splitDetailReplacement
            ),
            .immediate
        )
        XCTAssertEqual(
            LastChatsSearchDismissalPolicy.timing(
                for: .staysOnSource,
                route: .currentNavigationPush
            ),
            .immediate
        )
    }

    func testTwoMessagesInOneConversationHaveDifferentStableRowIDs() {
        let first = makeMessageProvenance(primary: "message-primary-1", archivedId: "archive-1")
        let second = makeMessageProvenance(primary: "message-primary-2", archivedId: "archive-2")

        XCTAssertNotEqual(first.stableID, second.stableID)
    }

    func testExactRoutePreservesEveryMessageIdentityAndOptionalDate() throws {
        let provenance = makeMessageProvenance(
            primary: "message-primary",
            archivedId: "archive-id",
            messageId: "message-id",
            authorId: "author-id",
            sourceDate: nil,
            fingerprint: "  Exact   BODY  "
        )

        let outcome = LastChatsSearchRouteFactory.outcome(
            for: provenance,
            activeGeneration: provenance.queryGeneration
        )
        guard case .message(let request) = outcome else {
            return XCTFail("Expected an exact message route, got \(outcome)")
        }

        XCTAssertEqual(request.anchor.messagePrimary, "message-primary")
        XCTAssertEqual(request.anchor.archivedId, "archive-id")
        XCTAssertEqual(request.anchor.messageId, "message-id")
        XCTAssertEqual(request.anchor.authorId, "author-id")
        XCTAssertEqual(request.anchor.bodyFingerprint, "exact body")
        XCTAssertNil(request.anchor.sourceDate)
        XCTAssertEqual(request.source, .search)
        XCTAssertFalse(request.markReadOnVisible)
    }

    func testContactResultRoutesToLatestExplicitly() {
        let provenance = LastChatsSearchResultProvenance.latest(
            conversation: conversation,
            provider: .localDirectory,
            queryGeneration: 12
        )

        XCTAssertEqual(
            LastChatsSearchRouteFactory.outcome(for: provenance, activeGeneration: 12),
            .latest(conversation)
        )
    }

    func testStaleGenerationAndMissingMessageIdentityAreTypedUnavailable() {
        let stale = makeMessageProvenance(primary: "primary", archivedId: nil, generation: 11)
        XCTAssertEqual(
            LastChatsSearchRouteFactory.outcome(for: stale, activeGeneration: 12),
            .unavailable(.staleGeneration)
        )

        let missing = makeMessageProvenance(
            primary: nil,
            archivedId: nil,
            messageId: nil,
            sourceDate: nil,
            fingerprint: nil,
            generation: 12
        )
        XCTAssertEqual(
            LastChatsSearchRouteFactory.outcome(for: missing, activeGeneration: 12),
            .unavailable(.missingMessageIdentity)
        )
    }

    func testUnavailablePresentationIsTypedAndAccessible() {
        let presentation = LastChatsSearchUnavailablePresentation.make(reason: .staleGeneration)

        XCTAssertEqual(presentation.reason, .staleGeneration)
        XCTAssertFalse(presentation.title.isEmpty)
        XCTAssertFalse(presentation.message.isEmpty)
        XCTAssertEqual(presentation.accessibilityIdentifier, "chat_search_result_unavailable")
    }

    func testLocalResolutionUsesPrimaryBeforeArchiveAndMessageID() {
        let provenance = makeMessageProvenance(
            primary: "primary-target",
            archivedId: "archive-conflict",
            messageId: "message-conflict",
            authorId: "author-target"
        )
        let candidates = [
            candidate(primary: "archive-candidate", archivedId: "archive-conflict"),
            candidate(primary: "message-candidate", messageId: "message-conflict", authorId: "author-target"),
            candidate(primary: "primary-target")
        ]

        XCTAssertEqual(
            LastChatsSearchLocalResolver.resolve(provenance: provenance, candidates: candidates),
            .matched(candidates[2], source: .primary)
        )
    }

    func testLocalResolutionUsesArchiveBeforeMessageIDWhenPrimaryIsMissing() {
        let provenance = makeMessageProvenance(
            primary: "missing-primary",
            archivedId: "archive-target",
            messageId: "message-conflict",
            authorId: "author-target"
        )
        let messageCandidate = candidate(
            primary: "message-candidate",
            messageId: "message-conflict",
            authorId: "author-target"
        )
        let archiveCandidate = candidate(
            primary: "archive-candidate",
            archivedId: "archive-target"
        )

        XCTAssertEqual(
            LastChatsSearchLocalResolver.resolve(
                provenance: provenance,
                candidates: [messageCandidate, archiveCandidate]
            ),
            .matched(archiveCandidate, source: .archivedID)
        )
    }

    func testMessageIDResolutionHonorsAuthorAndRejectsAmbiguity() {
        let provenance = makeMessageProvenance(
            primary: nil,
            archivedId: nil,
            messageId: "shared-message-id",
            authorId: "target-author"
        )
        let outsideAuthor = candidate(
            primary: "outside-author",
            messageId: "shared-message-id",
            authorId: "other-author"
        )
        let target = candidate(
            primary: "target",
            messageId: "shared-message-id",
            authorId: "target-author"
        )

        XCTAssertEqual(
            LastChatsSearchLocalResolver.resolve(
                provenance: provenance,
                candidates: [outsideAuthor, target]
            ),
            .matched(target, source: .authorMessageID)
        )

        let duplicate = candidate(
            primary: "duplicate",
            messageId: "shared-message-id",
            authorId: "target-author"
        )
        XCTAssertEqual(
            LastChatsSearchLocalResolver.resolve(
                provenance: provenance,
                candidates: [target, duplicate]
            ),
            .unavailable(.ambiguousMessageID, inspectedFallbackCandidateCount: 0)
        )
    }

    func testFingerprintDateResolutionIsBoundedAndRequiresUniqueMatch() {
        let provenance = makeMessageProvenance(
            primary: nil,
            archivedId: nil,
            messageId: nil,
            authorId: "target-author",
            sourceDate: date,
            fingerprint: "same body"
        )
        let target = candidate(
            primary: "target",
            authorId: "target-author",
            sourceDate: date,
            fingerprint: " SAME   BODY "
        )
        XCTAssertEqual(
            LastChatsSearchLocalResolver.resolve(provenance: provenance, candidates: [target]),
            .matched(target, source: .fingerprintDate)
        )

        let duplicate = candidate(
            primary: "duplicate",
            authorId: "target-author",
            sourceDate: date,
            fingerprint: "same body"
        )
        XCTAssertEqual(
            LastChatsSearchLocalResolver.resolve(provenance: provenance, candidates: [target, duplicate]),
            .unavailable(.ambiguousFingerprintDate, inspectedFallbackCandidateCount: 2)
        )

        let overflow = (0..<65).map {
            candidate(
                primary: "candidate-\($0)",
                authorId: "target-author",
                sourceDate: date,
                fingerprint: "not the target"
            )
        }
        XCTAssertEqual(
            LastChatsSearchLocalResolver.resolve(
                provenance: provenance,
                candidates: overflow,
                fallbackCandidateLimit: 64
            ),
            .unavailable(.fallbackCandidateLimitExceeded, inspectedFallbackCandidateCount: 64)
        )
    }

    func testRealmProviderUsesScopedPriorityAndRejectsAmbiguousMessageID() throws {
        let owner = "g17b-\(UUID().uuidString)@example.com"
        let jid = "peer-\(UUID().uuidString)@example.com"
        let realm = try WRealm.safe()
        let primaryTarget = storageMessage(
            primary: "g17b-primary-target-\(UUID().uuidString)",
            owner: owner,
            jid: jid,
            archivedId: "archive-target",
            messageId: "primary-message-id",
            body: "primary body",
            date: date
        )
        let archiveConflict = storageMessage(
            primary: "g17b-archive-conflict-\(UUID().uuidString)",
            owner: owner,
            jid: jid,
            archivedId: "archive-conflict",
            messageId: "duplicate-message-id",
            body: "duplicate one",
            date: date.addingTimeInterval(1)
        )
        let duplicateMessageID = storageMessage(
            primary: "g17b-message-duplicate-\(UUID().uuidString)",
            owner: owner,
            jid: jid,
            archivedId: "archive-duplicate",
            messageId: "duplicate-message-id",
            body: "duplicate two",
            date: date.addingTimeInterval(2)
        )
        try realm.write {
            realm.add([primaryTarget, archiveConflict, duplicateMessageID])
        }
        defer {
            try? realm.write {
                realm.delete(realm.objects(MessageStorageItem.self).filter("owner == %@", owner))
            }
        }

        let diagnostics = ChatLocalHistoryPageProviderDiagnostics()
        let provider = ChatLocalHistoryPageProvider(
            realm: realm,
            owner: owner,
            jid: jid,
            conversationType: .regular,
            diagnostics: diagnostics
        )
        let primaryFirst = provider.searchMessage(
            anchor: ChatMessageAnchorRef(
                messagePrimary: primaryTarget.primary,
                archivedId: archiveConflict.archivedId,
                messageId: archiveConflict.messageId,
                authorId: nil,
                bodyFingerprint: nil,
                sourceDate: nil
            )
        )
        XCTAssertEqual(primaryFirst?.primary, primaryTarget.primary)

        let ambiguousAnchor = ChatMessageAnchorRef(
            messagePrimary: nil,
            archivedId: nil,
            messageId: "duplicate-message-id",
            authorId: nil,
            bodyFingerprint: nil,
            sourceDate: nil
        )
        let ambiguous = provider.searchMessage(anchor: ambiguousAnchor)
        XCTAssertNil(ambiguous)
        guard case .failed(.ambiguous(candidateCount: 2)) = provider.searchMessageResolution(
            anchor: ambiguousAnchor
        ) else {
            return XCTFail("duplicate message IDs must preserve typed ambiguity")
        }
        XCTAssertLessThanOrEqual(diagnostics.maxCandidateCount, 2)
        XCTAssertEqual(diagnostics.fullScanCount, 0)
    }

    func testRealmProviderFingerprintDateFallbackIsBoundedAndUnique() throws {
        let owner = "g17b-fingerprint-\(UUID().uuidString)@example.com"
        let jid = "peer-\(UUID().uuidString)@example.com"
        let realm = try WRealm.safe()
        let target = storageMessage(
            primary: "g17b-fingerprint-target-\(UUID().uuidString)",
            owner: owner,
            jid: jid,
            archivedId: nil,
            messageId: nil,
            body: "  Exact   BODY  ",
            date: date
        )
        try realm.write { realm.add(target) }
        defer {
            try? realm.write {
                realm.delete(realm.objects(MessageStorageItem.self).filter("owner == %@", owner))
            }
        }

        let diagnostics = ChatLocalHistoryPageProviderDiagnostics()
        let provider = ChatLocalHistoryPageProvider(
            realm: realm,
            owner: owner,
            jid: jid,
            conversationType: .regular,
            diagnostics: diagnostics
        )
        let resolved = provider.searchMessage(
            anchor: ChatMessageAnchorRef(
                messagePrimary: nil,
                archivedId: nil,
                messageId: nil,
                authorId: nil,
                bodyFingerprint: "exact body",
                sourceDate: date
            )
        )

        XCTAssertEqual(resolved?.primary, target.primary)
        XCTAssertLessThanOrEqual(
            diagnostics.maxCandidateCount,
            LastChatsSearchLocalResolver.defaultFallbackCandidateLimit + 1
        )
        XCTAssertEqual(diagnostics.fullScanCount, 0)
    }

    func testLegacyTableRouteAndSearchDateNowFallbackAreAbsent() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let legacyRoute = repositoryRoot.appendingPathComponent(
            "xabber/controllers/chats/search/SearchResultsViewController+UITableViewDelegate.swift"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyRoute.path))

        let routeSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabber/controllers/chats/search/SearchResultsViewController.swift"
            ),
            encoding: .utf8
        )
        let factoryStart = try XCTUnwrap(routeSource.range(of: "enum SearchResultOpenRequestFactory"))
        let factoryEnd = try XCTUnwrap(
            routeSource.range(of: "enum SearchRemoteQueryCompletionPolicy", range: factoryStart.upperBound..<routeSource.endIndex)
        )
        let factorySource = routeSource[factoryStart.lowerBound..<factoryEnd.lowerBound]
        XCTAssertFalse(factorySource.contains("Date()"))
        XCTAssertFalse(factorySource.contains("item.date ??"))
    }

    private func makeMessageProvenance(
        primary: String?,
        archivedId: String?,
        messageId: String? = "message-id",
        authorId: String? = "author-id",
        sourceDate: Date? = Date(timeIntervalSince1970: 1_711_283_200),
        fingerprint: String? = "body",
        generation: UInt64 = 12
    ) -> LastChatsSearchResultProvenance {
        LastChatsSearchResultProvenance(
            targetKind: .message,
            conversation: conversation,
            messagePrimary: primary,
            archivedId: archivedId,
            messageId: messageId,
            authorId: authorId,
            sourceDate: sourceDate,
            bodyFingerprint: fingerprint,
            provider: .localMessages,
            queryGeneration: generation
        )
    }

    private func candidate(
        primary: String,
        archivedId: String? = nil,
        messageId: String? = nil,
        authorId: String? = nil,
        sourceDate: Date? = nil,
        fingerprint: String? = nil
    ) -> LastChatsSearchLocalCandidate {
        LastChatsSearchLocalCandidate(
            primary: primary,
            archivedId: archivedId,
            messageId: messageId,
            authorId: authorId,
            sourceDate: sourceDate,
            bodyFingerprint: fingerprint
        )
    }

    private func storageMessage(
        primary: String,
        owner: String,
        jid: String,
        archivedId: String?,
        messageId: String?,
        body: String,
        date: Date
    ) -> MessageStorageItem {
        let item = MessageStorageItem()
        item.primary = primary
        item.owner = owner
        item.opponent = jid
        item.conversationType = .regular
        item.messageType = MessageStorageItem.MessageDisplayType.text.rawValue
        item.archivedId = archivedId ?? ""
        item.messageId = messageId ?? ""
        item.body = body
        item.date = date
        item.isDeleted = false
        return item
    }
}
