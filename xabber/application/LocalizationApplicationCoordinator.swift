//
//  LocalizationApplicationCoordinator.swift
//  xabber
//

import UIKit

/// Owns the UIKit side effects of changing the process-wide localization context.
/// The localization core remains Foundation-only; rebuilding scenes is deliberately
/// kept at this boundary.
final class LocalizationApplicationCoordinator {
    typealias SelectionProvider = () -> AppLanguageSelection
    typealias SelectionSaver = (AppLanguageSelection) -> Bool
    typealias DependentStateRefresher = () -> Void
    typealias RootRebuilder = (UIWindow?) -> Void

    static let shared = LocalizationApplicationCoordinator()

    private let selectionProvider: SelectionProvider
    private let selectionSaver: SelectionSaver
    private let dependentStateRefresher: DependentStateRefresher
    private let rootRebuilder: RootRebuilder

    convenience init() {
        self.init(
            selectionProvider: { LocalizationRuntime.shared.selection },
            selectionSaver: { LocalizationRuntime.shared.saveSelection($0) },
            dependentStateRefresher: {
                (UIApplication.shared.delegate as? AppDelegate)?
                    .refreshLocalizationDependentState()
            },
            rootRebuilder: { sourceWindow in
                AppRootCoordinator.rebuildAllForLocalizationChange(
                    sourceWindow: sourceWindow
                )
            }
        )
    }

    init(
        selectionProvider: @escaping SelectionProvider,
        selectionSaver: @escaping SelectionSaver,
        dependentStateRefresher: @escaping DependentStateRefresher,
        rootRebuilder: @escaping RootRebuilder
    ) {
        self.selectionProvider = selectionProvider
        self.selectionSaver = selectionSaver
        self.dependentStateRefresher = dependentStateRefresher
        self.rootRebuilder = rootRebuilder
    }

    @discardableResult
    func apply(
        selection: AppLanguageSelection,
        sourceViewController: UIViewController
    ) -> Bool {
        apply(
            selection: selection,
            sourceWindow: sourceViewController.viewIfLoaded?.window
        )
    }

    @discardableResult
    func apply(
        selection: AppLanguageSelection,
        sourceWindow: UIWindow?
    ) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard selection != selectionProvider() else {
            return true
        }
        guard selectionSaver(selection) else {
            return false
        }

        dependentStateRefresher()
        rootRebuilder(sourceWindow)
        return true
    }
}
