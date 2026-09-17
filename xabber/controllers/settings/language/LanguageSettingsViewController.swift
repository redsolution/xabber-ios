//
//  LanguageSettingsViewController.swift
//  xabber
//

import UIKit

struct LanguageSettingsRow: Equatable {
    let selection: AppLanguageSelection
    let title: String
    let accessibilityIdentifier: String
    let accessibilityLanguage: String?

    static func makeRows(systemTitle: String) -> [LanguageSettingsRow] {
        let system = LanguageSettingsRow(
            selection: .system,
            title: systemTitle,
            accessibilityIdentifier: "settings.language.system",
            accessibilityLanguage: nil
        )
        let fixed = SupportedLanguage.allCases.map { language in
            LanguageSettingsRow(
                selection: .fixed(language),
                title: language.nativeDisplayName,
                accessibilityIdentifier: "settings.language.\(language.accessibilityIdentifierSuffix)",
                accessibilityLanguage: language.rawValue
            )
        }
        return [system] + fixed
    }

    static func title(
        for selection: AppLanguageSelection,
        systemTitle: String
    ) -> String {
        switch selection {
        case .system:
            return systemTitle
        case let .fixed(language):
            return language.nativeDisplayName
        }
    }
}

final class LanguageSettingsViewController: UIViewController {
    typealias SelectionApplier = (AppLanguageSelection, UIViewController) -> Bool

    let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private(set) var rows: [LanguageSettingsRow] = []

    private let selectionProvider: () -> AppLanguageSelection
    private let selectionApplier: SelectionApplier
    private let systemTitleProvider: () -> String

    convenience init() {
        self.init(
            selectionProvider: { LocalizationRuntime.shared.selection },
            selectionApplier: { selection, source in
                LocalizationApplicationCoordinator.shared.apply(
                    selection: selection,
                    sourceViewController: source
                )
            },
            systemTitleProvider: {
                L10n.text("settings_language_system", fallback: "System")
            }
        )
    }

    init(
        selectionProvider: @escaping () -> AppLanguageSelection,
        selectionApplier: @escaping SelectionApplier,
        systemTitleProvider: @escaping () -> String
    ) {
        self.selectionProvider = selectionProvider
        self.selectionApplier = selectionApplier
        self.systemTitleProvider = systemTitleProvider
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.text(
            "settings__dialog_change_language__header",
            fallback: "Choose language"
        )
        view.backgroundColor = .systemGroupedBackground

        rows = LanguageSettingsRow.makeRows(systemTitle: systemTitleProvider())
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 56
        tableView.accessibilityIdentifier = "settings.language.list"
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
}

extension LanguageSettingsViewController: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int { 1 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let reuseIdentifier = "LanguageSettingsCell"
        let cell = tableView.dequeueReusableCell(withIdentifier: reuseIdentifier)
            ?? UITableViewCell(style: .default, reuseIdentifier: reuseIdentifier)
        let row = rows[indexPath.row]
        let isSelected = row.selection == selectionProvider()

        cell.textLabel?.text = row.title
        cell.textLabel?.font = .preferredFont(forTextStyle: .body)
        cell.textLabel?.adjustsFontForContentSizeCategory = true
        cell.textLabel?.numberOfLines = 0
        cell.textLabel?.textAlignment = .natural
        cell.accessoryType = isSelected ? .checkmark : .none
        cell.accessibilityIdentifier = row.accessibilityIdentifier
        cell.accessibilityLabel = row.title
        cell.accessibilityLanguage = row.accessibilityLanguage
        if isSelected {
            cell.accessibilityTraits.insert(.selected)
        } else {
            cell.accessibilityTraits.remove(.selected)
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let selection = rows[indexPath.row].selection
        guard selection != selectionProvider() else { return }

        if !selectionApplier(selection, self) {
            tableView.reloadData()
        }
    }
}
