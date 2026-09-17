import Foundation

final class LocalizationRuntime {
    static let shared = LocalizationRuntime(
        initialBundleProvider: LprojBundleProvider(resourceBundle: .main),
        missingKeyHandler: LocalizationRuntime.defaultMissingKeyHandler
    )

    let service: LocalizationService

    private struct State {
        var preferenceStore: LanguagePreferenceStoring?
        var bundleProvider: LocalizedBundleProviding
        var revision: UInt64
    }

    private let stateLock = NSLock()
    private var state: State

    init(
        initialBundleProvider provider: LocalizedBundleProviding,
        preferredLanguages: [String] = Locale.preferredLanguages,
        locale: Locale = .current,
        calendar: Calendar = .current,
        timeZone: TimeZone = .current,
        missingKeyHandler: LocalizationMissingKeyHandler? = nil
    ) {
        let initialContext = LanguageResolver.makeContext(
            selection: .system,
            preferredLanguages: preferredLanguages,
            baseLocale: locale,
            calendar: calendar,
            timeZone: timeZone,
            bundleProvider: provider,
            revision: 0
        )
        state = State(
            preferenceStore: nil,
            bundleProvider: provider,
            revision: 0
        )
        service = LocalizationService(
            context: initialContext,
            missingKeyHandler: missingKeyHandler
        )
    }

    var context: LocalizationContext {
        service.context
    }

    var selection: AppLanguageSelection {
        context.selection
    }

    @discardableResult
    func bootstrap(
        appGroupSuiteName: String?,
        resourceBundle: Bundle = .main,
        preferredLanguages: [String] = Locale.preferredLanguages,
        locale: Locale = .current,
        calendar: Calendar = .current,
        timeZone: TimeZone = .current
    ) -> LocalizationContext {
        let preferenceStore = appGroupSuiteName.flatMap {
            LanguagePreferenceStore.appGroup(suiteName: $0)
        }
        return bootstrap(
            preferenceStore: preferenceStore,
            bundleProvider: LprojBundleProvider(resourceBundle: resourceBundle),
            preferredLanguages: preferredLanguages,
            locale: locale,
            calendar: calendar,
            timeZone: timeZone
        )
    }

    @discardableResult
    func bootstrap(
        preferenceStore: LanguagePreferenceStoring?,
        bundleProvider: LocalizedBundleProviding,
        preferredLanguages: [String] = Locale.preferredLanguages,
        locale: Locale = .current,
        calendar: Calendar = .current,
        timeZone: TimeZone = .current
    ) -> LocalizationContext {
        let selection = preferenceStore?.loadSelection() ?? .system

        stateLock.lock()
        state.preferenceStore = preferenceStore
        state.bundleProvider = bundleProvider
        let installed = installContextWithoutLock(
            selection: selection,
            preferredLanguages: preferredLanguages,
            locale: locale,
            calendar: calendar,
            timeZone: timeZone,
            forceRevision: state.revision == 0
        )
        stateLock.unlock()
        return installed
    }

    @discardableResult
    func refresh(
        preferredLanguages: [String] = Locale.preferredLanguages,
        locale: Locale = .current,
        calendar: Calendar = .current,
        timeZone: TimeZone = .current
    ) -> LocalizationContext {
        stateLock.lock()
        let selection = state.preferenceStore?.loadSelection() ?? .system
        let installed = installContextWithoutLock(
            selection: selection,
            preferredLanguages: preferredLanguages,
            locale: locale,
            calendar: calendar,
            timeZone: timeZone,
            forceRevision: false
        )
        stateLock.unlock()
        return installed
    }

    @discardableResult
    func saveSelection(
        _ selection: AppLanguageSelection,
        preferredLanguages: [String] = Locale.preferredLanguages,
        locale: Locale = .current,
        calendar: Calendar = .current,
        timeZone: TimeZone = .current
    ) -> Bool {
        stateLock.lock()
        guard let preferenceStore = state.preferenceStore,
              preferenceStore.saveSelection(selection) else {
            stateLock.unlock()
            return false
        }
        _ = installContextWithoutLock(
            selection: selection,
            preferredLanguages: preferredLanguages,
            locale: locale,
            calendar: calendar,
            timeZone: timeZone,
            forceRevision: false
        )
        stateLock.unlock()
        return true
    }

    @discardableResult
    func replaceContext(
        selection: AppLanguageSelection,
        preferredLanguages: [String] = Locale.preferredLanguages,
        locale: Locale = .current,
        calendar: Calendar = .current,
        timeZone: TimeZone = .current
    ) -> LocalizationContext {
        stateLock.lock()
        let installed = installContextWithoutLock(
            selection: selection,
            preferredLanguages: preferredLanguages,
            locale: locale,
            calendar: calendar,
            timeZone: timeZone,
            forceRevision: false
        )
        stateLock.unlock()
        return installed
    }

    @discardableResult
    func replaceContext(_ context: LocalizationContext) -> LocalizationContext {
        stateLock.lock()
        let nextRevision = state.revision &+ 1
        let installed = context.replacingRevision(nextRevision)
        state.revision = nextRevision
        service.replaceContext(installed)
        stateLock.unlock()
        return installed
    }

    private func installContextWithoutLock(
        selection: AppLanguageSelection,
        preferredLanguages: [String],
        locale: Locale,
        calendar: Calendar,
        timeZone: TimeZone,
        forceRevision: Bool
    ) -> LocalizationContext {
        let current = service.context
        let nextRevision = state.revision &+ 1
        let candidate = LanguageResolver.makeContext(
            selection: selection,
            preferredLanguages: preferredLanguages,
            baseLocale: locale,
            calendar: calendar,
            timeZone: timeZone,
            bundleProvider: state.bundleProvider,
            revision: nextRevision
        )

        if !forceRevision && candidate.isSemanticallyEquivalent(to: current) {
            return current
        }

        state.revision = nextRevision
        service.replaceContext(candidate)
        return candidate
    }

    private static var defaultMissingKeyHandler: LocalizationMissingKeyHandler? {
#if DEBUG
        return { key, language, reason in
            NSLog(
                "[Localization] key=%@ locale=%@ reason=%@",
                key,
                language.rawValue,
                reason.rawValue
            )
        }
#else
        return nil
#endif
    }
}

enum L10n {
    static var context: LocalizationContext {
        LocalizationRuntime.shared.context
    }

    static var formatters: LocalizationFormatterFactory {
        LocalizationRuntime.shared.service.formatters
    }

    static func text(
        _ key: String,
        fallback: String,
        table: String? = nil
    ) -> String {
        LocalizationRuntime.shared.service.text(
            key: key,
            fallback: fallback,
            table: table
        )
    }

    static func format(
        _ key: String,
        fallback: String,
        arguments: [CVarArg],
        table: String? = nil
    ) -> String {
        LocalizationRuntime.shared.service.format(
            key: key,
            fallback: fallback,
            arguments: arguments,
            table: table
        )
    }

    static func legacyFormat(
        _ key: String,
        fallback: String,
        arguments: [String],
        table: String? = nil
    ) -> String {
        LocalizationRuntime.shared.service.legacyFormat(
            key: key,
            fallback: fallback,
            arguments: arguments,
            table: table
        )
    }

    static func plural(
        _ key: String,
        count: Int,
        fallback: String,
        arguments: [CVarArg] = [],
        table: String? = nil
    ) -> String {
        LocalizationRuntime.shared.service.plural(
            key: key,
            count: count,
            fallback: fallback,
            arguments: arguments,
            table: table
        )
    }

    static func attributedMarkdown(
        _ key: String,
        fallback: String,
        arguments: [CVarArg] = [],
        table: String? = nil
    ) -> NSAttributedString {
        LocalizationRuntime.shared.service.attributedMarkdown(
            key: key,
            fallback: fallback,
            arguments: arguments,
            table: table
        )
    }
}
