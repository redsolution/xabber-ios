import XCTest
@testable import xabber

final class TextMessageCellGranularUpdateTests: XCTestCase {
    func testChromeOnlyPlanDoesNotBindTextLayoutAttachmentsAvatarOrMedia() {
        let plan = ChatMessageCellUpdatePlan(changeMask: [.chrome])

        XCTAssertEqual(plan.operations, [.cellBindChrome])
        XCTAssertEqual(plan.mediaRequestCount, 0)
        XCTAssertFalse(plan.rebuildsText)
        XCTAssertFalse(plan.invalidatesLayout)
        XCTAssertFalse(plan.rebindsAttachments)
        XCTAssertFalse(plan.reloadsAvatar)
    }

    func testContentPlansBindOnlyRequestedComponents() {
        XCTAssertEqual(
            ChatMessageCellUpdatePlan(changeMask: [.text]).operations,
            [.cellBindText]
        )
        XCTAssertEqual(
            ChatMessageCellUpdatePlan(changeMask: [.layout]).operations,
            [.cellBindLayout]
        )
        XCTAssertEqual(
            ChatMessageCellUpdatePlan(changeMask: [.attachments]).operations,
            [.cellBindAttachments]
        )
        XCTAssertEqual(
            ChatMessageCellUpdatePlan(changeMask: [.avatar]).operations,
            [.cellBindAvatar]
        )
    }

    func testAttachmentPlanCountsOneMediaBindingButChromePlanCountsZero() {
        XCTAssertEqual(
            ChatMessageCellUpdatePlan(changeMask: [.attachments]).mediaRequestCount,
            1
        )
        XCTAssertEqual(
            ChatMessageCellUpdatePlan(changeMask: [.chrome]).mediaRequestCount,
            0
        )
    }

    func testTextCellChromeUpdateSourceDoesNotTouchHeavyContentViews() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabber/controllers/chats/chat/messages_kit/Views/Cells/TextMessageCell.swift"
            ),
            encoding: .utf8
        )
        let body = try XCTUnwrap(functionBody(named: "applyChromeUpdate", in: source))

        [
            "messageLabel.configure",
            "imagesView.updateContent",
            "videosView.updateContent",
            "audiosView.updateContent",
            "filesView.updateContent",
            "forwardsContainer.updateContent",
            "configureAvatar"
        ].forEach {
            XCTAssertFalse(body.contains($0), "chrome-only update performs heavy bind: \($0)")
        }
        XCTAssertTrue(body.contains("changeMask: [.chrome]"))
    }

    func testMessageContentCellMaskedBaseUpdateDoesNotRedispatchToFullBind() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabber/controllers/chats/chat/messages_kit/Views/Cells/MessageContentCell.swift"
            ),
            encoding: .utf8
        )
        let signature = "changeMask: ChatMessageChangeMask"
        let signatureRange = try XCTUnwrap(source.range(of: signature))
        let body = try XCTUnwrap(functionBody(startingAt: signatureRange.lowerBound, in: source))

        XCTAssertTrue(body.contains("applyBaseContent"))
        XCTAssertFalse(body.contains("reconfigureContent(with:"))
    }

    private func functionBody(named name: String, in source: String) -> String? {
        guard let nameRange = source.range(of: "func \(name)") else { return nil }
        return functionBody(startingAt: nameRange.lowerBound, in: source)
    }

    private func functionBody(startingAt start: String.Index, in source: String) -> String? {
        guard let openBrace = source[start...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = openBrace
        while index < source.endIndex {
            switch source[index] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(source[openBrace...index])
                }
            default:
                break
            }
            index = source.index(after: index)
        }
        return nil
    }
}
