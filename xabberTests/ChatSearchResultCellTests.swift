//
//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
//  General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//

import XCTest
import UIKit
@testable import xabber

final class ChatSearchResultCellTests: XCTestCase {
    private let standardBounds = CGRect(x: 0, y: 0, width: 390, height: 64)

    func testReuseIdentifierAndReferenceGeometryAtIPhone16eWidth() {
        let frames = ChatSearchResultCellLayoutPolicy.frames(
            in: standardBounds,
            dateWidth: 48,
            showsStatus: true,
            layoutDirection: .leftToRight,
            contentSizeCategory: .large
        )

        XCTAssertEqual(ChatSearchResultCell.reuseIdentifier, "ChatSearchResultCell")
        XCTAssertEqual(ChatSearchResultCellLayoutPolicy.rowHeight(for: .large), 64)
        XCTAssertEqual(frames.avatar, CGRect(x: 12, y: 10, width: 44, height: 44))
        XCTAssertEqual(frames.sender, CGRect(x: 68, y: 8, width: 237, height: 20))
        XCTAssertEqual(frames.snippet, CGRect(x: 68, y: 32, width: 310, height: 20))
        XCTAssertEqual(frames.status, CGRect(x: 313, y: 10, width: 14, height: 18))
        XCTAssertEqual(frames.date, CGRect(x: 330, y: 10, width: 48, height: 18))
        XCTAssertEqual(frames.separator, CGRect(x: 68, y: 63.5, width: 322, height: 0.5))
        XCTAssertEqual(frames.senderBaselineY, frames.dateBaselineY)
        XCTAssertLessThan(frames.senderBaselineY, frames.snippetBaselineY)
        XCTAssertEqual(frames.date.minX - frames.status.maxX, 3)
    }

    func testRTLLayoutMirrorsAvatarTextDateStatusAndSeparator() {
        let leftToRight = ChatSearchResultCellLayoutPolicy.frames(
            in: standardBounds,
            dateWidth: 48,
            showsStatus: true,
            layoutDirection: .leftToRight,
            contentSizeCategory: .large
        )
        let rightToLeft = ChatSearchResultCellLayoutPolicy.frames(
            in: standardBounds,
            dateWidth: 48,
            showsStatus: true,
            layoutDirection: .rightToLeft,
            contentSizeCategory: .large
        )

        assertMirrored(leftToRight.avatar, rightToLeft.avatar)
        assertMirrored(leftToRight.sender, rightToLeft.sender)
        assertMirrored(leftToRight.snippet, rightToLeft.snippet)
        assertMirrored(leftToRight.status, rightToLeft.status)
        assertMirrored(leftToRight.date, rightToLeft.date)
        assertMirrored(leftToRight.separator, rightToLeft.separator)
        XCTAssertEqual(rightToLeft.status.minX - rightToLeft.date.maxX, 3)
    }

    func testAccessibilityCategoryGrowsRowAndKeepsContentDisjoint() {
        let regularHeight = ChatSearchResultCellLayoutPolicy.rowHeight(for: .large)
        let accessibilityHeight = ChatSearchResultCellLayoutPolicy.rowHeight(
            for: .accessibilityExtraExtraExtraLarge
        )
        let frames = ChatSearchResultCellLayoutPolicy.frames(
            in: CGRect(x: 0, y: 0, width: 390, height: accessibilityHeight),
            dateWidth: 70,
            showsStatus: true,
            layoutDirection: .leftToRight,
            contentSizeCategory: .accessibilityExtraExtraExtraLarge
        )

        XCTAssertGreaterThan(accessibilityHeight, regularHeight)
        XCTAssertFalse(frames.sender.intersects(frames.snippet))
        XCTAssertFalse(frames.sender.intersects(frames.status))
        XCTAssertFalse(frames.sender.intersects(frames.date))
        XCTAssertLessThanOrEqual(frames.avatar.maxY, accessibilityHeight)
        XCTAssertLessThanOrEqual(frames.snippet.maxY, accessibilityHeight)
    }

    func testDateFormatterUsesTodayTimeSameYearNumericDateOlderYearAndLocale() {
        let timeZone = TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let now = makeDate(2026, 7, 13, 16, 30, calendar: calendar)
        let today = makeDate(2026, 7, 13, 9, 5, calendar: calendar)
        let thisYear = makeDate(2026, 2, 3, 9, 5, calendar: calendar)
        let olderYear = makeDate(2025, 2, 3, 9, 5, calendar: calendar)
        let english = ChatSearchResultDateFormatter(
            locale: Locale(identifier: "en_US"),
            calendar: calendar,
            timeZone: timeZone
        )
        let russian = ChatSearchResultDateFormatter(
            locale: Locale(identifier: "ru_RU"),
            calendar: calendar,
            timeZone: timeZone
        )

        XCTAssertEqual(english.presentation(for: today, relativeTo: now).kind, .todayTime)
        XCTAssertEqual(english.presentation(for: thisYear, relativeTo: now).kind, .sameYearDate)
        XCTAssertEqual(english.presentation(for: olderYear, relativeTo: now).kind, .olderYearDate)
        XCTAssertEqual(
            english.string(for: today, relativeTo: now),
            expectedDateText(today, template: "j:mm", locale: english.locale, calendar: calendar, timeZone: timeZone)
        )
        XCTAssertEqual(
            english.string(for: thisYear, relativeTo: now),
            expectedDateText(thisYear, template: "Md", locale: english.locale, calendar: calendar, timeZone: timeZone)
        )
        XCTAssertEqual(
            english.string(for: olderYear, relativeTo: now),
            expectedDateText(olderYear, template: "yMd", locale: english.locale, calendar: calendar, timeZone: timeZone)
        )
        XCTAssertEqual(
            russian.string(for: olderYear, relativeTo: now),
            expectedDateText(olderYear, template: "yMd", locale: russian.locale, calendar: calendar, timeZone: timeZone)
        )
        XCTAssertNotEqual(
            english.string(for: olderYear, relativeTo: now),
            russian.string(for: olderYear, relativeTo: now)
        )
    }

    func testDeliveryPresentationExplicitlyCoversEveryXabberState() {
        let expected: [(ChatSearchResult.DeliveryState, String, String)] = [
            (.pending, "clock", "Pending"),
            (.sent, "checkmark", "Sent"),
            (.delivered, "checkmark.circle", "Delivered"),
            (.read, "checkmark.circle.fill", "Read"),
            (.failed, "exclamationmark.circle.fill", "Failed")
        ]

        for (state, symbol, fallbackLabel) in expected {
            let presentation = ChatSearchResultDeliveryPresentation.presentation(for: state)
            XCTAssertEqual(presentation.systemImageName, symbol)
            XCTAssertEqual(presentation.fallbackAccessibilityLabel, fallbackLabel)
            XCTAssertFalse(presentation.accessibilityLabel.isEmpty)
        }
    }

    func testOutgoingConfigurationUsesLocalizedYouPlainSnippetAndAdjacentStatus() throws {
        let result = makeResult(
            id: .archived("outgoing-1"),
            outgoing: true,
            senderTitle: "Вы",
            snippet: "first test second test",
            deliveryState: .read
        )
        let cell = makeCell()
        cell.frame = standardBounds

        cell.configure(with: result)
        cell.layoutIfNeeded()

        XCTAssertEqual(cell.senderLabel.text, "Вы")
        XCTAssertEqual(cell.snippetLabel.text, "first test second test")
        XCTAssertEqual(cell.snippetLabel.numberOfLines, 1)
        XCTAssertEqual(cell.snippetLabel.lineBreakMode, .byTruncatingTail)
        XCTAssertGreaterThanOrEqual(fontWeight(cell.senderLabel.font), UIFont.Weight.semibold.rawValue)
        XCTAssertFalse(cell.statusImageView.isHidden)
        XCTAssertEqual(cell.dateLabel.frame.minX - cell.statusImageView.frame.maxX, 3, accuracy: 0.5)
        XCTAssertFalse(try hasBackgroundHighlight(cell.snippetLabel.attributedText))
        XCTAssertEqual(cell.backgroundColor, .systemBackground)
        XCTAssertEqual(cell.contentView.backgroundColor, .systemBackground)
    }

    func testIncomingConfigurationNeverShowsOutgoingCheck() {
        let result = makeResult(
            id: .archived("incoming-1"),
            outgoing: false,
            senderTitle: "Andrew Nenakhov",
            deliveryState: .read
        )
        let cell = makeCell()
        cell.frame = standardBounds

        cell.configure(with: result)
        cell.layoutIfNeeded()

        XCTAssertTrue(cell.statusImageView.isHidden)
        XCTAssertNil(cell.statusImageView.image)
        XCTAssertEqual(cell.dateLabel.frame.maxX, standardBounds.maxX - 12, accuracy: 0.5)
    }

    func testGroupMapperCarriesAuthorAvatarAndFallbackInitialsWithoutRealmInCell() throws {
        let item = MessageStorageItem()
        item.primary = "group-primary"
        item.archivedId = "group-archive"
        item.owner = "owner@example.com"
        item.opponent = "room@example.com"
        item.conversationType = .group
        item.body = "group test"
        let author = GroupchatUserStorageItem()
        author.userId = "author-id"
        author.nickname = "Alexey Boldin"
        author.avatarURI = "https://example.com/avatar.jpg"
        item.groupchatCard = author
        let context = ChatSearchResultMappingContext(
            scope: ChatSearchResult.Scope(
                owner: item.owner,
                jid: item.opponent,
                conversationTypeRawValue: item.conversationType.rawValue
            ),
            localizedYou: "You",
            contactDisplayName: "Room"
        )

        let result = try XCTUnwrap(ChatSearchResultMapper.map(item, context: context))

        XCTAssertEqual(result.senderTitle, "Alexey Boldin")
        XCTAssertEqual(result.avatar.identity, "group:owner@example.com|room@example.com|author-id")
        XCTAssertEqual(result.avatar.fallbackTitle, "Alexey Boldin")
        XCTAssertEqual(result.avatar.url, "https://example.com/avatar.jpg")
        XCTAssertEqual(
            result.avatar.source,
            .group(userId: "author-id", conversationJID: "room@example.com", owner: "owner@example.com")
        )
        let cell = makeCell()
        cell.frame = standardBounds
        cell.configure(with: result)
        cell.layoutIfNeeded()
        XCTAssertNotNil(cell.avatarImageView.image)
    }

    func testPrepareForReuseCancelsAvatarAndClearsEveryPresentedValue() {
        let loader = AvatarLoaderSpy()
        let cell = makeCell(loader: loader)
        cell.frame = standardBounds
        cell.configure(with: makeResult(id: .primary("reuse"), outgoing: true))
        XCTAssertEqual(loader.requests.count, 1)

        cell.prepareForReuse()

        XCTAssertTrue(loader.requests[0].cancellation.isCancelled)
        XCTAssertNil(cell.representedAvatarIdentity)
        XCTAssertNil(cell.avatarImageView.image)
        XCTAssertNil(cell.senderLabel.text)
        XCTAssertNil(cell.snippetLabel.text)
        XCTAssertNil(cell.dateLabel.text)
        XCTAssertNil(cell.statusImageView.image)
        XCTAssertTrue(cell.statusImageView.isHidden)
        XCTAssertNil(cell.accessibilityIdentifier)
        XCTAssertNil(cell.accessibilityLabel)
    }

    func testLateAvatarCompletionCannotReplaceNewRepresentedIdentity() {
        let loader = AvatarLoaderSpy()
        let cell = makeCell(loader: loader)
        cell.frame = standardBounds
        let first = makeResult(
            id: .primary("first"),
            outgoing: false,
            senderTitle: "First",
            avatarJID: "first@example.com"
        )
        let second = makeResult(
            id: .primary("second"),
            outgoing: false,
            senderTitle: "Second",
            avatarJID: "second@example.com"
        )

        cell.configure(with: first)
        cell.configure(with: second)
        let secondFallback = cell.avatarImageView.image
        let staleImage = solidImage(color: .red)
        loader.requests[0].completion(staleImage)

        XCTAssertTrue(loader.requests[0].cancellation.isCancelled)
        XCTAssertTrue(cell.avatarImageView.image === secondFallback)

        let currentImage = solidImage(color: .green)
        loader.requests[1].completion(currentImage)
        XCTAssertTrue(cell.avatarImageView.image === currentImage)
    }

    func testSelectedAndHighlightedStatesNeverInstallGenericBlueBackground() {
        let cell = makeCell()
        cell.frame = standardBounds
        cell.configure(with: makeResult(id: .primary("selection"), outgoing: false))

        cell.setHighlighted(true, animated: false)
        XCTAssertEqual(cell.backgroundColor, .systemBackground)
        XCTAssertEqual(cell.contentView.backgroundColor, .systemBackground)
        XCTAssertNil(cell.selectedBackgroundView)

        cell.setSelected(true, animated: false)
        XCTAssertEqual(cell.backgroundColor, .systemBackground)
        XCTAssertEqual(cell.contentView.backgroundColor, .systemBackground)
        XCTAssertNil(cell.selectedBackgroundView)
    }

    func testAccessibilityCombinesRowContentStatusAndStableIdentity() {
        let result = makeResult(
            id: .archived("archive-42"),
            outgoing: true,
            senderTitle: "You",
            snippet: "test message",
            deliveryState: .delivered
        )
        let cell = makeCell()
        cell.frame = standardBounds

        cell.configure(with: result)

        XCTAssertTrue(cell.isAccessibilityElement)
        XCTAssertEqual(cell.accessibilityIdentifier, "chat_search_result_row.archived.archive-42")
        XCTAssertTrue(cell.accessibilityLabel?.contains("You") == true)
        XCTAssertTrue(cell.accessibilityLabel?.contains("test message") == true)
        XCTAssertTrue(cell.accessibilityLabel?.contains(cell.dateLabel.text ?? "missing-date") == true)
        XCTAssertTrue(cell.accessibilityLabel?.contains("Delivered") == true)
        XCTAssertTrue(cell.accessibilityTraits.contains(.button))
        XCTAssertFalse(cell.avatarImageView.isAccessibilityElement)
        XCTAssertFalse(cell.senderLabel.isAccessibilityElement)
        XCTAssertFalse(cell.snippetLabel.isAccessibilityElement)
        XCTAssertFalse(cell.dateLabel.isAccessibilityElement)
        XCTAssertFalse(cell.statusImageView.isAccessibilityElement)
    }

    private func makeCell(
        loader: ChatSearchResultAvatarLoading = AvatarLoaderSpy()
    ) -> ChatSearchResultCell {
        ChatSearchResultCell(
            avatarLoader: loader,
            dateFormatter: ChatSearchResultDateFormatter(
                locale: Locale(identifier: "en_US"),
                calendar: fixedCalendar,
                timeZone: fixedCalendar.timeZone
            ),
            now: { [fixedNow] in fixedNow }
        )
    }

    private func makeResult(
        id: ChatSearchResult.ID,
        outgoing: Bool,
        senderTitle: String = "Andrew Nenakhov",
        snippet: String = "test message",
        deliveryState: ChatSearchResult.DeliveryState = .sent,
        avatarJID: String? = nil
    ) -> ChatSearchResult {
        let identity = avatarJID ?? (outgoing ? "owner@example.com" : "andrew@example.com")
        return ChatSearchResult(
            id: id,
            scope: ChatSearchResult.Scope(
                owner: "owner@example.com",
                jid: "andrew@example.com",
                conversationTypeRawValue: ClientSynchronizationManager.ConversationType.regular.rawValue
            ),
            anchor: ChatSearchResult.Anchor(
                primary: "primary",
                archivedId: "archive",
                messageId: "message",
                authorId: nil,
                date: makeDate(2026, 7, 13, 9, 5, calendar: fixedCalendar)
            ),
            outgoing: outgoing,
            senderTitle: senderTitle,
            body: snippet,
            snippet: snippet,
            deliveryState: deliveryState,
            avatar: ChatSearchResult.Avatar(
                identity: "contact:owner@example.com|\(identity)",
                fallbackTitle: senderTitle,
                url: "https://example.com/\(identity).jpg",
                source: .contact(jid: identity, owner: "owner@example.com")
            )
        )
    }

    private var fixedCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var fixedNow: Date {
        makeDate(2026, 7, 13, 16, 30, calendar: fixedCalendar)
    }

    private func makeDate(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        calendar: Calendar
    ) -> Date {
        calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }

    private func expectedDateText(
        _ date: Date,
        template: String,
        locale: Locale,
        calendar: Calendar,
        timeZone: TimeZone
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    private func assertMirrored(
        _ leftToRight: CGRect,
        _ rightToLeft: CGRect,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(leftToRight.minX + rightToLeft.maxX, standardBounds.width, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(leftToRight.width, rightToLeft.width, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(leftToRight.minY, rightToLeft.minY, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(leftToRight.height, rightToLeft.height, accuracy: 0.001, file: file, line: line)
    }

    private func fontWeight(_ font: UIFont) -> CGFloat {
        let traits = font.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
        return CGFloat((traits?[.weight] as? NSNumber)?.doubleValue ?? Double(UIFont.Weight.regular.rawValue))
    }

    private func hasBackgroundHighlight(_ value: NSAttributedString?) throws -> Bool {
        guard let value, value.length > 0 else { return false }
        var found = false
        value.enumerateAttribute(
            .backgroundColor,
            in: NSRange(location: 0, length: value.length)
        ) { attribute, _, stop in
            if attribute != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    private func solidImage(color: UIColor) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
        return renderer.image { context in
            color.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
    }
}

private final class AvatarLoaderSpy: ChatSearchResultAvatarLoading {
    struct Request {
        let avatar: ChatSearchResult.Avatar
        let size: CGFloat
        let cancellation: Cancellation
        let completion: (UIImage?) -> Void
    }

    final class Cancellation: ChatSearchResultAvatarLoadCancelling {
        private(set) var isCancelled = false

        func cancel() {
            isCancelled = true
        }
    }

    private(set) var requests: [Request] = []

    @discardableResult
    func loadAvatar(
        for avatar: ChatSearchResult.Avatar,
        size: CGFloat,
        completion: @escaping (UIImage?) -> Void
    ) -> ChatSearchResultAvatarLoadCancelling? {
        let cancellation = Cancellation()
        requests.append(Request(
            avatar: avatar,
            size: size,
            cancellation: cancellation,
            completion: completion
        ))
        return cancellation
    }
}
