//
//  ChatSearchLocalizationTests.swift
//  xabberTests
//
//  Created by Codex on 14.07.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import XCTest
import UIKit
@testable import xabber

@MainActor
final class ChatSearchLocalizationTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0)!

    func testEveryVisibleSearchFlowKeyResolvesForEnglishAndRussianWithoutBlankCopy() {
        let english = ChatSearchLocalization(locale: Locale(identifier: "en"), bundle: .main)
        let russian = ChatSearchLocalization(locale: Locale(identifier: "ru"), bundle: .main)

        for key in ChatSearchLocalizationKey.visibleSearchFlowKeys {
            XCTAssertFalse(english.text(key).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, key.rawValue)
            XCTAssertFalse(russian.text(key).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, key.rawValue)
        }

        XCTAssertEqual(english.text(.showAsList), "Show as List")
        XCTAssertEqual(english.text(.showAsChat), "Show as Chat")
        XCTAssertEqual(english.text(.searchTitle), "Search")
        XCTAssertEqual(english.text(.done), "Done")
        XCTAssertEqual(english.text(.outgoingSenderYou), "You")

        XCTAssertEqual(russian.text(.showAsList), "Показать списком")
        XCTAssertEqual(russian.text(.showAsChat), "Показать в чате")
        XCTAssertEqual(russian.text(.searchTitle), "Поиск")
        XCTAssertEqual(russian.text(.done), "Готово")
        XCTAssertEqual(russian.text(.outgoingSenderYou), "Вы")
    }

    func testMessageCountUsesProjectPluralResourceFormsForEnglishAndRussian() {
        let english = ChatSearchLocalization(locale: Locale(identifier: "en"), bundle: .main)
        let russian = ChatSearchLocalization(locale: Locale(identifier: "ru"), bundle: .main)

        XCTAssertEqual(english.messageCount(0), "No messages")
        XCTAssertEqual(english.messageCount(1), "1 message")
        XCTAssertEqual(english.messageCount(2), "2 messages")
        XCTAssertEqual(english.messageCount(100), "100 messages")

        XCTAssertEqual(russian.messageCount(0), "Нет сообщений")
        XCTAssertEqual(russian.messageCount(1), "1 сообщение")
        XCTAssertEqual(russian.messageCount(2), "2 сообщения")
        XCTAssertEqual(russian.messageCount(5), "5 сообщений")
        XCTAssertEqual(russian.messageCount(21), "21 сообщение")
        XCTAssertEqual(russian.messageCount(22), "22 сообщения")
        XCTAssertEqual(russian.messageCount(25), "25 сообщений")
        XCTAssertEqual(russian.messageCount(111), "111 сообщений")

        XCTAssertEqual(Set(ChatSearchPluralResourceForm.allCases.map(\.resourceIndex)), Set(0...5))
        for form in ChatSearchPluralResourceForm.allCases {
            XCTAssertFalse(form.fallbackTemplate(locale: Locale(identifier: "en")).isEmpty)
            XCTAssertFalse(form.fallbackTemplate(locale: Locale(identifier: "ru")).isEmpty)
        }
    }

    func testCurrentOfTotalIsLocaleAwareAndNeverProducesZeroPosition() {
        let english = ChatSearchLocalization(locale: Locale(identifier: "en_US"), bundle: .main)
        let russian = ChatSearchLocalization(locale: Locale(identifier: "ru_RU"), bundle: .main)

        XCTAssertEqual(english.currentPosition(zeroBasedIndex: 0, total: 3), "1 of 3")
        XCTAssertEqual(russian.currentPosition(zeroBasedIndex: 0, total: 3), "1 из 3")
        XCTAssertNil(english.currentPosition(zeroBasedIndex: -1, total: 3))
        XCTAssertNil(english.currentPosition(zeroBasedIndex: 3, total: 3))
        XCTAssertNil(english.currentPosition(zeroBasedIndex: 0, total: 0))
        XCTAssertFalse(english.currentPosition(zeroBasedIndex: -1, total: 3)?.contains("0") == true)
    }

    func testCompactResultDatesUseInjectedLocaleCalendarAndTimeZone() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let cache = ChatSearchFormatterCache()
        let now = date(2026, 7, 13, 16, 30, calendar: calendar)
        let sameYear = date(2026, 2, 3, 9, 5, calendar: calendar)
        let olderYear = date(2025, 2, 3, 9, 5, calendar: calendar)
        let english = ChatSearchFormatting(
            locale: Locale(identifier: "en_US"),
            calendar: calendar,
            timeZone: utc,
            cache: cache
        )
        let russian = ChatSearchFormatting(
            locale: Locale(identifier: "ru_RU"),
            calendar: calendar,
            timeZone: utc,
            cache: cache
        )

        XCTAssertEqual(english.resultDate(for: sameYear, relativeTo: now).kind, .sameYearDate)
        XCTAssertEqual(english.resultDate(for: olderYear, relativeTo: now).kind, .olderYearDate)
        XCTAssertNotEqual(
            english.resultDate(for: olderYear, relativeTo: now).text,
            russian.resultDate(for: olderYear, relativeTo: now).text
        )
        XCTAssertFalse(english.resultDate(for: sameYear, relativeTo: now).text.contains("test"))
    }

    func testCalendarMonthTitleAndWeekdaysUseInjectedLocaleAndCalendarOrder() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        calendar.firstWeekday = 2
        let date = date(2026, 7, 13, 12, 0, calendar: calendar)
        let cache = ChatSearchFormatterCache()
        let english = ChatSearchFormatting(
            locale: Locale(identifier: "en_US"),
            calendar: calendar,
            timeZone: utc,
            cache: cache
        )
        let russian = ChatSearchFormatting(
            locale: Locale(identifier: "ru_RU"),
            calendar: calendar,
            timeZone: utc,
            cache: cache
        )

        XCTAssertTrue(english.monthTitle(for: date).localizedCaseInsensitiveContains("July"))
        XCTAssertTrue(russian.monthTitle(for: date).localizedCaseInsensitiveContains("июл"))
        XCTAssertEqual(english.weekdaySymbols().count, 7)
        XCTAssertEqual(russian.weekdaySymbols().count, 7)
        XCTAssertTrue(english.weekdaySymbols()[0].localizedCaseInsensitiveContains("Mon"))
        XCTAssertTrue(russian.weekdaySymbols()[0].localizedCaseInsensitiveContains("пн"))
    }

    func testOutgoingAndEarlierLaterTermsComeFromLocalizedCatalog() {
        let english = ChatSearchLocalization(locale: Locale(identifier: "en"), bundle: .main)
        let russian = ChatSearchLocalization(locale: Locale(identifier: "ru"), bundle: .main)

        XCTAssertEqual(english.text(.outgoingSenderYou), "You")
        XCTAssertEqual(english.text(.earlierResult), "Earlier result")
        XCTAssertEqual(english.text(.laterResult), "Later result")
        XCTAssertEqual(russian.text(.outgoingSenderYou), "Вы")
        XCTAssertEqual(russian.text(.earlierResult), "Более ранний результат")
        XCTAssertEqual(russian.text(.laterResult), "Более поздний результат")
    }

    func testEmptyErrorAndRetryAnnouncementsUseDistinctKeys() {
        let localization = ChatSearchLocalization(locale: Locale(identifier: "en"), bundle: .main)
        let keys: [ChatSearchLocalizationKey] = [
            .resultsEmpty,
            .resultsError,
            .retry,
            .announcementNoMessages,
            .announcementSearchError,
            .announcementRetry
        ]

        XCTAssertEqual(Set(keys.map(\.rawValue)).count, keys.count)
        XCTAssertEqual(localization.text(.resultsEmpty), "No messages found")
        XCTAssertEqual(localization.text(.resultsError), "Search failed")
        XCTAssertEqual(localization.text(.retry), "Try Again")
        XCTAssertEqual(localization.text(.announcementNoMessages), "No messages")
        XCTAssertEqual(localization.text(.announcementSearchError), "Search failed")
        XCTAssertEqual(localization.text(.announcementRetry), "Retrying search")
    }

    func testMissingTranslationUsesDeterministicNonemptyDevelopmentFallback() {
        let localization = ChatSearchLocalization(
            locale: Locale(identifier: "zz_ZZ"),
            lookup: { _, fallback in fallback }
        )

        for key in ChatSearchLocalizationKey.visibleSearchFlowKeys {
            XCTAssertEqual(localization.text(key), key.developmentFallback)
            XCTAssertFalse(localization.text(key).isEmpty)
        }
        XCTAssertEqual(localization.messageCount(2), "2 messages")
    }

    func testFormatterCacheReusesOnlyCompatibleLocaleCalendarAndTimeZoneConfigurations() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let cache = ChatSearchFormatterCache()
        let enUTC = ChatSearchFormattingContext(
            locale: Locale(identifier: "en_US"),
            calendar: calendar,
            timeZone: utc
        )
        let ruUTC = ChatSearchFormattingContext(
            locale: Locale(identifier: "ru_RU"),
            calendar: calendar,
            timeZone: utc
        )
        let enNewYork = ChatSearchFormattingContext(
            locale: Locale(identifier: "en_US"),
            calendar: calendar,
            timeZone: TimeZone(identifier: "America/New_York")!
        )

        let first = cache.dateFormatterIdentity(for: .resultSameYear, context: enUTC)
        XCTAssertEqual(first, cache.dateFormatterIdentity(for: .resultSameYear, context: enUTC))
        XCTAssertNotEqual(first, cache.dateFormatterIdentity(for: .resultSameYear, context: ruUTC))
        XCTAssertNotEqual(first, cache.dateFormatterIdentity(for: .resultSameYear, context: enNewYork))
    }

    func testLocaleChangesVisibleCopyWithoutChangingStableResultOrCalendarIdentity() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        calendar.firstWeekday = 2
        let clock = FixedClock(now: date(2026, 7, 13, 12, 0, calendar: calendar))
        let englishModel = ChatSearchCalendarModel(
            calendar: calendar,
            locale: Locale(identifier: "en_US"),
            clock: clock
        )
        let russianModel = ChatSearchCalendarModel(
            calendar: calendar,
            locale: Locale(identifier: "ru_RU"),
            clock: clock
        )
        let item = MessageStorageItem()
        item.owner = "owner@example.com"
        item.opponent = "andrew@example.com"
        item.conversationType = .regular
        item.primary = "primary"
        item.archivedId = "archive"
        item.messageId = "message"
        item.outgoing = true
        item.body = "test"
        item.date = clock.now
        let scope = ChatSearchResult.Scope(
            owner: item.owner,
            jid: item.opponent,
            conversationTypeRawValue: item.conversationType.rawValue
        )
        let english = try XCTUnwrap(ChatSearchResultMapper.map(
            item,
            context: .init(scope: scope, localizedYou: "You", contactDisplayName: "Andrew")
        ))
        let russian = try XCTUnwrap(ChatSearchResultMapper.map(
            item,
            context: .init(scope: scope, localizedYou: "Вы", contactDisplayName: "Andrew")
        ))

        XCTAssertEqual(english.id, russian.id)
        XCTAssertEqual(english.scope, russian.scope)
        XCTAssertEqual(english.anchor, russian.anchor)
        XCTAssertNotEqual(english.senderTitle, russian.senderTitle)
        XCTAssertEqual(
            englishModel.snapshot.daySlots.map(\.id),
            russianModel.snapshot.daySlots.map(\.id)
        )
        XCTAssertNotEqual(englishModel.snapshot.monthTitle, russianModel.snapshot.monthTitle)
    }

    private func date(
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
}

private struct FixedClock: ChatSearchCalendarClock {
    let now: Date
}
