import XCTest
@testable import xabber

final class NewlyCreatedGroupChatPresentationTests: XCTestCase {

    func testUnsyncedNewlyCreatedGroupUsesEmptyInsteadOfBlockingSkeleton() {
        let standard = ChatBootstrapLoadingReducer.resolve(.init(
            messageCount: 0,
            isSynced: false,
            isInitialArchiveLoaded: false,
            isInitialBootstrapInFlight: true,
            hasPendingInitialAnchorRequest: false,
            allowsStaleLocalHistory: false,
            hasTerminalFailure: false
        ))

        XCTAssertEqual(standard, .blockingArchive)
        XCTAssertEqual(
            ChatInitialPresentationContextPolicy.loadingState(
                standard: standard,
                context: .newlyCreatedGroup,
                localMessageCount: 0
            ),
            .empty
        )
    }

    func testNewlyCreatedGroupUsesContentAsSoonAsCreateEventIsLocal() {
        XCTAssertEqual(
            ChatInitialPresentationContextPolicy.loadingState(
                standard: .blockingArchive,
                context: .newlyCreatedGroup,
                localMessageCount: 1
            ),
            .content
        )
    }

    func testOrdinaryUnsyncedGroupKeepsBlockingSkeleton() {
        XCTAssertEqual(
            ChatInitialPresentationContextPolicy.loadingState(
                standard: .blockingArchive,
                context: .standard,
                localMessageCount: 0
            ),
            .blockingArchive
        )
    }

    func testNewlyCreatedGroupNeverChoosesSkeletonFirstOrTimeoutSkeleton() {
        XCTAssertFalse(
            ChatInitialPresentationContextPolicy.shouldUseSkeletonFirstFrame(
                strategy: .skeletonFirst,
                context: .newlyCreatedGroup,
                isDatasourceEmpty: true
            )
        )
        XCTAssertEqual(
            ChatInitialPresentationContextPolicy.timeoutFallback(
                context: .newlyCreatedGroup,
                hasRealRows: false
            ),
            .empty
        )

        XCTAssertTrue(
            ChatInitialPresentationContextPolicy.shouldUseSkeletonFirstFrame(
                strategy: .skeletonFirst,
                context: .standard,
                isDatasourceEmpty: true
            )
        )
        XCTAssertEqual(
            ChatInitialPresentationContextPolicy.timeoutFallback(
                context: .standard,
                hasRealRows: false
            ),
            .skeleton
        )
    }

    func testSuccessfulCreateConfiguresBothNavigationPaths() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let flowURL = repositoryRoot.appendingPathComponent(
            "xabber/controllers/chats/create_new_entity/new_group/CreateNewGroupViewController+Flow.swift"
        )
        let source = try String(contentsOf: flowURL, encoding: .utf8)

        XCTAssertEqual(
            source.components(
                separatedBy: "prepareForNewlyCreatedGroupPresentation()"
            ).count - 1,
            2
        )
        XCTAssertFalse(
            source.contains(
                "conversationType: .group, configure: nil"
            )
        )
    }
}
