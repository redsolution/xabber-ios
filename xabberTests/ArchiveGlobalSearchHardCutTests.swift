import Foundation
import XCTest

final class ArchiveGlobalSearchHardCutTests: XCTestCase {
    func testSearchControllersHaveNoMessageArchiveManagerRuntime() throws {
        let searchChatList = try read(
            "xabber/controllers/chats/search/search_chat_list/SearchChatListViewController.swift"
        )
        let searchResults = try read(
            "xabber/controllers/chats/search/SearchResultsViewController.swift"
        )

        for (path, source) in [
            ("SearchChatListViewController.swift", searchChatList),
            ("SearchResultsViewController.swift", searchResults),
        ] {
            XCTAssertFalse(source.contains("scheduleSearchText("), path)
            XCTAssertFalse(source.contains("requestPendingSearchContinuation("), path)
            XCTAssertFalse(source.contains("MessageArchiveManager.RequestCallbacks"), path)
            XCTAssertFalse(source.contains(".mam.searchText("), path)
            XCTAssertTrue(source.contains("archiveEngine"), path)
        }
    }

    func testMessageArchiveManagerContainsNoLegacySearchSessionOwner() throws {
        let manager = try read(
            "xabber/xmpp/messages/message_archive/MessageArchiveManager.swift"
        )
        let legacySession = sourceRoot.appendingPathComponent(
            "xabber/xmpp/messages/message_archive/ChatSearchArchiveSession.swift"
        )
        let forbidden = [
            "func scheduleSearchText(",
            "func searchText(",
            "func requestPendingSearchContinuation(",
            "func cancelSearch(queryId:",
            "ChatSearchArchiveSession",
            "searchArchiveSessionsByQueryId",
            "pendingSearchContinuationsByQueryId",
            "onSearchTerminal",
            "onSearchContinuationAvailable",
            "onSearchContinuationStarted",
        ]

        XCTAssertEqual(
            forbidden.filter(manager.contains),
            [],
            "AccountArchiveEngine must be the sole owner of search pagination"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: legacySession.path),
            "The obsolete manager-owned search session shell must be deleted"
        )
    }

    func testGlobalSearchUsesAccountArchiveEngineAndExplicitContinuation() throws {
        let searchResults = try read(
            "xabber/controllers/chats/search/SearchResultsViewController.swift"
        )

        XCTAssertTrue(searchResults.contains("ArchiveSearchScope.account("))
        XCTAssertTrue(searchResults.contains("archiveEngine.searchStates(for:"))
        XCTAssertTrue(searchResults.contains("archiveEngine.startSearch("))
        XCTAssertTrue(searchResults.contains("archiveEngine.requestNextSearchPage("))
        XCTAssertFalse(searchResults.contains("loadFull: true"))
    }

    func testNotificationsDoNotBypassSchedulerWhenOwningAccountIsAbsent() throws {
        let source = try read(
            "xabber/xmpp/notifications/XMPPNotificationsManager.swift"
        )
        let updateBody = try XCTUnwrap(
            source.slice(
                from: "public func update(_ stream: XMPPStream)",
                to: "private final func performLatestSync("
            )
        )

        XCTAssertTrue(updateBody.contains("guard let account = AccountManager.shared.find(for: self.owner)"))
        XCTAssertTrue(updateBody.contains("account.xmppTaskScheduler.enqueueAccountTask("))
        XCTAssertFalse(updateBody.contains("runLatestSync(stream, {})"))
    }

    private func read(_ relativePath: String) throws -> String {
        try String(
            contentsOf: sourceRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private extension String {
    func slice(from start: String, to end: String) -> String? {
        guard let startRange = range(of: start),
              let endRange = range(
                  of: end,
                  range: startRange.upperBound..<endIndex
              ) else {
            return nil
        }
        return String(self[startRange.lowerBound..<endRange.lowerBound])
    }
}
