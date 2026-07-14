//
//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License.
//

import Foundation

enum ChatSearchLocalizationKey: String, CaseIterable {
    case searchField = "chat_search_field"
    case searchTitle = "chat_search_title"
    case done = "chat_search_done"
    case close = "chat_search_close"
    case apply = "chat_search_apply"
    case calendar = "chat_search_calendar"
    case chooseMonthYear = "chat_search_choose_month_year"
    case previousMonth = "chat_search_previous_month"
    case nextMonth = "chat_search_next_month"
    case showAsList = "chat_search_show_as_list"
    case showAsChat = "chat_search_show_as_chat"
    case currentOfTotal = "chat_search_current_of_total"
    case noMessages = "chat_search_no_messages"
    case resultsEmpty = "chat_search_results_empty"
    case resultsError = "chat_search_results_error"
    case retry = "chat_search_results_retry"
    case resultsLoading = "chat_search_results_loading"
    case outgoingSenderYou = "chat_search_sender_you"
    case earlierResult = "chat_search_earlier_result"
    case laterResult = "chat_search_later_result"
    case previousResult = "chat_search_accessibility_previous_result"
    case nextResult = "chat_search_accessibility_next_result"
    case olderMessage = "chat_search_accessibility_older_message"
    case newerMessage = "chat_search_accessibility_newer_message"
    case noOlderResults = "chat_search_accessibility_no_older_results"
    case noNewerResults = "chat_search_accessibility_no_newer_results"
    case resultsListAccessibility = "chat_search_accessibility_results_list"
    case resultsCountAccessibility = "chat_search_accessibility_results_count"
    case resultJumpHint = "chat_search_accessibility_result_jump_hint"
    case monthYearPickerAccessibility = "chat_search_accessibility_month_year_picker"
    case selected = "selected"
    case today = "today"
    case loading = "chat_search_loading"
    case clear = "chat_search_clear"
    case cancel = "chat_search_cancel"
    case announcementNoMessages = "chat_search_announcement_no_messages"
    case announcementSearchError = "chat_search_announcement_error"
    case announcementRetry = "chat_search_announcement_retry"
    case deliveryPending = "chat_search_delivery_pending"
    case deliverySent = "chat_search_delivery_sent"
    case deliveryDelivered = "chat_search_delivery_delivered"
    case deliveryRead = "chat_search_delivery_read"
    case deliveryFailed = "chat_search_delivery_failed"

    static let visibleSearchFlowKeys: [Self] = [
        .searchField,
        .searchTitle,
        .done,
        .close,
        .apply,
        .calendar,
        .chooseMonthYear,
        .previousMonth,
        .nextMonth,
        .showAsList,
        .showAsChat,
        .currentOfTotal,
        .noMessages,
        .resultsEmpty,
        .resultsError,
        .retry,
        .resultsLoading,
        .outgoingSenderYou,
        .earlierResult,
        .laterResult,
        .previousResult,
        .nextResult,
        .olderMessage,
        .newerMessage,
        .noOlderResults,
        .noNewerResults,
        .resultsListAccessibility,
        .resultsCountAccessibility,
        .resultJumpHint,
        .monthYearPickerAccessibility,
        .selected,
        .today,
        .loading,
        .clear,
        .cancel,
        .announcementNoMessages,
        .announcementSearchError,
        .announcementRetry,
        .deliveryPending,
        .deliverySent,
        .deliveryDelivered,
        .deliveryRead,
        .deliveryFailed
    ]

    var developmentFallback: String {
        switch self {
        case .searchField:
            return "Search this chat"
        case .searchTitle:
            return "Search"
        case .done:
            return "Done"
        case .close:
            return "Close"
        case .apply:
            return "Apply"
        case .calendar:
            return "Calendar"
        case .chooseMonthYear:
            return "Choose month and year"
        case .previousMonth:
            return "Previous month"
        case .nextMonth:
            return "Next month"
        case .showAsList:
            return "Show as List"
        case .showAsChat:
            return "Show as Chat"
        case .currentOfTotal:
            return "%@ of %@"
        case .noMessages, .announcementNoMessages:
            return "No messages"
        case .resultsEmpty:
            return "No messages found"
        case .resultsError, .announcementSearchError:
            return "Search failed"
        case .retry:
            return "Try Again"
        case .resultsLoading:
            return "Loading messages"
        case .outgoingSenderYou:
            return "You"
        case .earlierResult:
            return "Earlier result"
        case .laterResult:
            return "Later result"
        case .previousResult:
            return "Previous result"
        case .nextResult:
            return "Next result"
        case .olderMessage:
            return "Older message"
        case .newerMessage:
            return "Newer message"
        case .noOlderResults:
            return "No older results"
        case .noNewerResults:
            return "No newer results"
        case .resultsListAccessibility:
            return "Search results"
        case .resultsCountAccessibility:
            return "Search results count"
        case .resultJumpHint:
            return "Double tap to jump to this message"
        case .monthYearPickerAccessibility:
            return "Month and year picker"
        case .selected:
            return "Selected"
        case .today:
            return "Today"
        case .loading:
            return "Loading"
        case .clear:
            return "Clear"
        case .cancel:
            return "Cancel"
        case .announcementRetry:
            return "Retrying search"
        case .deliveryPending:
            return "Pending"
        case .deliverySent:
            return "Sent"
        case .deliveryDelivered:
            return "Delivered"
        case .deliveryRead:
            return "Read"
        case .deliveryFailed:
            return "Failed"
        }
    }
}

enum ChatSearchPluralResourceForm: Int, CaseIterable {
    case item0 = 0
    case item1 = 1
    case item2 = 2
    case item3 = 3
    case item4 = 4
    case item5 = 5

    var resourceIndex: Int { rawValue }

    var resourceKey: String {
        "plurals.chat_search_messages.item_\(rawValue)"
    }

    func fallbackTemplate(locale: Locale) -> String {
        let isRussian = locale.languageCode == "ru"
        if isRussian {
            switch self {
            case .item0:
                return "%@ сообщение"
            case .item1:
                return "%@ сообщения"
            case .item2, .item3, .item4, .item5:
                return "%@ сообщений"
            }
        }
        return self == .item0 ? "%@ message" : "%@ messages"
    }
}

struct ChatSearchLocalization {
    typealias Lookup = (_ key: String, _ developmentFallback: String) -> String

    let locale: Locale
    private let lookup: Lookup
    private let formatterCache: ChatSearchFormatterCache

    init(
        locale: Locale,
        lookup: @escaping Lookup,
        formatterCache: ChatSearchFormatterCache = .shared
    ) {
        self.locale = locale
        self.lookup = lookup
        self.formatterCache = formatterCache
    }

    init(
        locale: Locale,
        bundle: Bundle,
        formatterCache: ChatSearchFormatterCache = .shared
    ) {
        let localizedBundle = Self.localizedBundle(for: locale, in: bundle)
        self.init(
            locale: locale,
            lookup: { key, fallback in
                let value = localizedBundle.localizedString(
                    forKey: key,
                    value: fallback,
                    table: nil
                )
                return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? fallback
                    : value
            },
            formatterCache: formatterCache
        )
    }

    static func production(
        locale: Locale? = nil,
        bundle: Bundle = .main,
        formatterCache: ChatSearchFormatterCache = .shared
    ) -> Self {
        let resolvedLocale = locale ?? productionLocale(bundle: bundle)
        return Self(
            locale: resolvedLocale,
            bundle: bundle,
            formatterCache: formatterCache
        )
    }

    func text(
        _ key: ChatSearchLocalizationKey,
        arguments: [CVarArg] = []
    ) -> String {
        let fallback = key.developmentFallback
        let localized = nonempty(lookup(key.rawValue, fallback), fallback: fallback)
        guard !arguments.isEmpty else {
            return localized
        }
        return String(format: localized, locale: locale, arguments: arguments)
    }

    func messageCount(_ count: Int) -> String {
        let count = max(0, count)
        guard count > 0 else {
            return text(.noMessages)
        }
        let form = pluralResourceForm(for: count)
        let fallback = form.fallbackTemplate(locale: locale)
        let template = nonempty(lookup(form.resourceKey, fallback), fallback: fallback)
        let number = formatterCache.numberString(max(0, count), locale: locale)
        return String(format: template, locale: locale, arguments: [number])
    }

    func currentPosition(zeroBasedIndex: Int, total: Int) -> String? {
        guard total > 0, (0..<total).contains(zeroBasedIndex) else {
            return nil
        }
        let current = formatterCache.numberString(zeroBasedIndex + 1, locale: locale)
        let total = formatterCache.numberString(total, locale: locale)
        return text(.currentOfTotal, arguments: [current, total])
    }

    func pluralResourceForm(for count: Int) -> ChatSearchPluralResourceForm {
        let count = abs(count)
        let language = locale.languageCode ?? "en"
        let modulo10 = count % 10
        let modulo100 = count % 100

        switch language {
        case "ar":
            if count == 0 { return .item0 }
            if count == 1 { return .item1 }
            if count == 2 { return .item2 }
            if (3...10).contains(modulo100) { return .item3 }
            if (11...99).contains(modulo100) { return .item4 }
            return .item5
        case "ru", "uk", "be", "sr", "hr", "bs":
            if modulo10 == 1 && modulo100 != 11 { return .item0 }
            if (2...4).contains(modulo10) && !(12...14).contains(modulo100) { return .item1 }
            if modulo10 == 0 || (5...9).contains(modulo10) || (11...14).contains(modulo100) {
                return .item2
            }
            return .item3
        case "pl":
            if count == 1 { return .item0 }
            if (2...4).contains(modulo10) && !(12...14).contains(modulo100) { return .item1 }
            return .item2
        case "cs", "sk":
            if count == 1 { return .item0 }
            if (2...4).contains(count) { return .item1 }
            return .item2
        case "sl":
            if modulo100 == 1 { return .item0 }
            if modulo100 == 2 { return .item1 }
            if modulo100 == 3 || modulo100 == 4 { return .item2 }
            return .item3
        case "fr", "pt":
            return count == 0 || count == 1 ? .item0 : .item1
        default:
            return count == 1 ? .item0 : .item1
        }
    }

    private func nonempty(_ value: String, fallback: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : value
    }

    private static func productionLocale(bundle: Bundle) -> Locale {
        if let selected = TranslationsManager.shared.currentLang {
            let direct = selected.replacingOccurrences(of: "_", with: "-")
            if bundle.path(forResource: direct, ofType: "lproj") != nil ||
                bundle.path(forResource: selected, ofType: "lproj") != nil {
                return Locale(identifier: direct)
            }
            return Locale(
                identifier: TranslationsManager.shared.prepareLanCode(language: selected)
            )
        }
        return .autoupdatingCurrent
    }

    private static func localizedBundle(for locale: Locale, in bundle: Bundle) -> Bundle {
        let candidates = [
            locale.identifier,
            locale.identifier.replacingOccurrences(of: "_", with: "-"),
            locale.languageCode,
            "en"
        ].compactMap { $0 }

        for candidate in candidates {
            if let path = bundle.path(forResource: candidate, ofType: "lproj"),
               let localized = Bundle(path: path) {
                return localized
            }
        }
        return bundle
    }
}

struct ChatSearchFormattingContext: Hashable {
    let localeIdentifier: String
    let calendarIdentifier: Calendar.Identifier
    let timeZoneIdentifier: String
    let firstWeekday: Int
    let minimumDaysInFirstWeek: Int

    init(locale: Locale, calendar: Calendar, timeZone: TimeZone) {
        localeIdentifier = locale.identifier
        calendarIdentifier = calendar.identifier
        timeZoneIdentifier = timeZone.identifier
        firstWeekday = calendar.firstWeekday
        minimumDaysInFirstWeek = calendar.minimumDaysInFirstWeek
    }

    var locale: Locale { Locale(identifier: localeIdentifier) }

    var calendar: Calendar {
        var calendar = Calendar(identifier: calendarIdentifier)
        calendar.locale = locale
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .autoupdatingCurrent
        calendar.firstWeekday = firstWeekday
        calendar.minimumDaysInFirstWeek = minimumDaysInFirstWeek
        return calendar
    }

    var timeZone: TimeZone {
        TimeZone(identifier: timeZoneIdentifier) ?? .autoupdatingCurrent
    }
}

struct ChatSearchResultDatePresentation: Equatable {
    enum Kind: Equatable {
        case todayTime
        case sameYearDate
        case olderYearDate
    }

    let kind: Kind
    let text: String
}

final class ChatSearchFormatterCache {
    enum DateRole: Hashable {
        case resultTime
        case resultSameYear
        case resultOlderYear
        case monthTitle
        case fullDate
        case symbols

        var template: String? {
            switch self {
            case .resultTime:
                return "j:mm"
            case .resultSameYear:
                return "Md"
            case .resultOlderYear:
                return "yMd"
            case .monthTitle:
                return "LLLL yyyy"
            case .fullDate:
                return "yMMMMd"
            case .symbols:
                return nil
            }
        }
    }

    static let shared = ChatSearchFormatterCache()

    private struct DateKey: Hashable {
        let role: DateRole
        let context: ChatSearchFormattingContext
    }

    private let lock = NSLock()
    private var dateFormatters: [DateKey: DateFormatter] = [:]
    private var numberFormatters: [String: NumberFormatter] = [:]

    var cachedFormatterCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return dateFormatters.count + numberFormatters.count
    }

    func removeAll() {
        lock.lock()
        dateFormatters.removeAll(keepingCapacity: false)
        numberFormatters.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    func dateString(
        _ date: Date,
        role: DateRole,
        context: ChatSearchFormattingContext
    ) -> String {
        lock.lock()
        defer { lock.unlock() }
        return dateFormatter(role: role, context: context).string(from: date)
    }

    func weekdaySymbols(context: ChatSearchFormattingContext) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let formatter = dateFormatter(role: .symbols, context: context)
        let symbols = formatter.shortStandaloneWeekdaySymbols ??
            formatter.shortWeekdaySymbols ??
            []
        guard symbols.count == 7 else { return symbols }
        let firstIndex = max(0, min(6, context.firstWeekday - 1))
        return Array(symbols[firstIndex...] + symbols[..<firstIndex])
    }

    func pickerMonthSymbols(context: ChatSearchFormattingContext) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let formatter = dateFormatter(role: .symbols, context: context)
        let symbols = formatter.standaloneMonthSymbols ?? formatter.monthSymbols ?? []
        return symbols.count == 12 ? symbols : (1...12).map(String.init)
    }

    func numberString(_ value: Int, locale: Locale) -> String {
        lock.lock()
        defer { lock.unlock() }
        let key = locale.identifier
        let formatter: NumberFormatter
        if let cached = numberFormatters[key] {
            formatter = cached
        } else {
            let created = NumberFormatter()
            created.locale = locale
            created.numberStyle = .decimal
            created.maximumFractionDigits = 0
            numberFormatters[key] = created
            formatter = created
        }
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    func dateFormatterIdentity(
        for role: DateRole,
        context: ChatSearchFormattingContext
    ) -> ObjectIdentifier {
        lock.lock()
        defer { lock.unlock() }
        return ObjectIdentifier(dateFormatter(role: role, context: context))
    }

    private func dateFormatter(
        role: DateRole,
        context: ChatSearchFormattingContext
    ) -> DateFormatter {
        let key = DateKey(role: role, context: context)
        if let cached = dateFormatters[key] {
            return cached
        }
        let formatter = DateFormatter()
        formatter.locale = context.locale
        formatter.calendar = context.calendar
        formatter.timeZone = context.timeZone
        if let template = role.template {
            formatter.setLocalizedDateFormatFromTemplate(template)
        }
        dateFormatters[key] = formatter
        return formatter
    }
}

struct ChatSearchFormatting {
    let context: ChatSearchFormattingContext
    private let cache: ChatSearchFormatterCache

    init(
        locale: Locale,
        calendar: Calendar,
        timeZone: TimeZone,
        cache: ChatSearchFormatterCache = .shared
    ) {
        context = ChatSearchFormattingContext(
            locale: locale,
            calendar: calendar,
            timeZone: timeZone
        )
        self.cache = cache
    }

    func resultDate(for date: Date, relativeTo now: Date) -> ChatSearchResultDatePresentation {
        let calendar = context.calendar
        let kind: ChatSearchResultDatePresentation.Kind
        let role: ChatSearchFormatterCache.DateRole
        if calendar.isDate(date, inSameDayAs: now) {
            kind = .todayTime
            role = .resultTime
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            kind = .sameYearDate
            role = .resultSameYear
        } else {
            kind = .olderYearDate
            role = .resultOlderYear
        }
        return ChatSearchResultDatePresentation(
            kind: kind,
            text: cache.dateString(date, role: role, context: context)
        )
    }

    func monthTitle(for date: Date) -> String {
        cache.dateString(date, role: .monthTitle, context: context)
    }

    func fullDate(for date: Date) -> String {
        cache.dateString(date, role: .fullDate, context: context)
    }

    func weekdaySymbols() -> [String] {
        cache.weekdaySymbols(context: context)
    }

    func pickerMonthSymbols() -> [String] {
        cache.pickerMonthSymbols(context: context)
    }
}
