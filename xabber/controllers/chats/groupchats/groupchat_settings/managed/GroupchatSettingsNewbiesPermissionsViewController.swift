import UIKit
import RxSwift
import RxCocoa
import RxRelay
import MaterialComponents.MDCPalettes
import CocoaLumberjack

class GroupchatSettingsNewbiesPermissionsViewController: SimpleBaseViewController {
    final class PermissionCell: UITableViewCell {
        static let cellName = "CanonicalNewbiePermissionCell"
        private let titleLabel = UILabel()
        private let durationButton = UIButton(type: .system)
        private let switchView = UISwitch()
        private var key = ""
        var onSwitchChanged: ((String, Bool) -> Void)?
        var onDurationRequested: ((String) -> Void)?

        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            let stack = UIStackView(arrangedSubviews: [titleLabel, durationButton, switchView])
            stack.axis = .horizontal
            stack.alignment = .center
            stack.spacing = 8
            contentView.addSubview(stack)
            stack.fillSuperviewWithOffset(top: 4, bottom: 4, left: 16, right: 16)
            titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
            durationButton.addTarget(self, action: #selector(onDuration), for: .touchUpInside)
            switchView.addTarget(self, action: #selector(onSwitch), for: .valueChanged)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func configure(
            title: String,
            key: String,
            status: Bool,
            originalStatus: Bool,
            seconds: UInt64?,
            isEnabled: Bool
        ) {
            titleLabel.text = title
            self.key = key
            switchView.isOn = status
            switchView.isEnabled = isEnabled
            durationButton.isEnabled = isEnabled
            durationButton.setTitle(Self.durationTitle(seconds), for: .normal)
            switchView.onTintColor = status == originalStatus
                ? MDCPalette.green.tint100
                : .systemGreen
        }

        private static func durationTitle(_ seconds: UInt64?) -> String {
            guard let seconds else { return "Forever" }
            let days = seconds / 86_400
            let hours = (seconds % 86_400) / 3_600
            let minutes = (seconds % 3_600) / 60
            let values = [
                days > 0 ? "\(days)d" : nil,
                hours > 0 ? "\(hours)h" : nil,
                minutes > 0 ? "\(minutes)m" : nil
            ].compactMap { $0 }
            return values.isEmpty ? "Forever" : values.joined(separator: " ")
        }

        @objc private func onSwitch(_ sender: UISwitch) {
            onSwitchChanged?(key, sender.isOn)
        }

        @objc private func onDuration() {
            onDurationRequested?(key)
        }
    }

    final class DurationCell: UITableViewCell {
        static let cellName = "CanonicalNewbieDurationCell"

        func configure(title: String) {
            textLabel?.text = title
        }
    }

    final class Datasource {
        let key: String
        let title: String
        var editorRow: GroupPermissionEditorRow

        init(permission: GroupPermission) {
            key = Self.key(for: permission)
            title = permission.display ?? permission.name
            editorRow = GroupPermissionEditorRow(
                permission: permission,
                status: permission.status,
                seconds: GroupPermissionMutationBuilder.durationSeconds(for: permission),
                changed: false
            )
        }

        static func key(for permission: GroupPermission) -> String {
            "\(permission.level ?? ""):\(permission.name)"
        }
    }

    var baselinePermissions: [GroupPermission] = []
    private var datasource: [Datasource] = []
    private var repository: GroupRepository?
    private var projectionObservation: GroupRepositoryObservation?
    private var refreshTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var selectedDurationSeconds: UInt64? = 3_600
    private var canEdit = false
    private var canReset = false
    private let changesObserver = BehaviorRelay<Bool>(value: false)

    private let durations: [(key: String, title: String, seconds: UInt64?)] = [
        ("forever", "Forever", nil),
        ("1_hour", "1 Hour", 3_600),
        ("4_hours", "4 Hours", 14_400),
        ("1_day", "1 Day", 86_400),
        ("1_week", "1 Week", 604_800),
        ("2_weeks", "2 Weeks", 1_209_600),
        ("custom", "Custom", nil)
    ]

    private let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .insetGrouped)
        view.register(PermissionCell.self, forCellReuseIdentifier: PermissionCell.cellName)
        view.register(DurationCell.self, forCellReuseIdentifier: DurationCell.cellName)
        return view
    }()
    private let saveBarButton = UIBarButtonItem(systemItem: .save)
    private let cancelBarButton = UIBarButtonItem(systemItem: .cancel)
    private let resetBarButton = UIBarButtonItem(
        title: "Reset".localizeString(
            id: "groupchat_permissions_reset_action",
            arguments: []
        ),
        style: .plain,
        target: nil,
        action: nil
    )

    override func loadDatasource() {
        super.loadDatasource()
        do {
            let repository = GroupRepository(realm: try WRealm.safe())
            self.repository = repository
            apply(try repository.projection(owner: owner, groupJID: jid), force: true)
        } catch {
            DDLogDebug("GroupchatSettingsNewbiesPermissionsViewController: \(#function). \(error.localizedDescription)")
            rebuildRows(newbies: [])
        }
    }

    override func setupSubviews() {
        super.setupSubviews()
        view.addSubview(tableView)
        tableView.fillSuperview()
    }

    override func configure() {
        super.configure()
        title = "Permissions for new members"
        tableView.dataSource = self
        tableView.delegate = self
        cancelBarButton.action = #selector(onCancel)
        cancelBarButton.target = self
        saveBarButton.action = #selector(onSave)
        saveBarButton.target = self
        resetBarButton.action = #selector(onReset)
        resetBarButton.target = self
        resetBarButton.accessibilityIdentifier = "groupchat_permissions_reset_newbies"
    }

    override func subscribe() {
        super.subscribe()
        changesObserver
            .asObservable()
            .distinctUntilChanged()
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] changed in
                self?.updateNavigationItems(hasChanges: changed)
            })
            .disposed(by: bag)

        do {
            let repository: GroupRepository
            if let existingRepository = self.repository {
                repository = existingRepository
            } else {
                repository = GroupRepository(realm: try WRealm.safe())
            }
            self.repository = repository
            projectionObservation?.invalidate()
            projectionObservation = try repository.observeProjection(
                owner: owner,
                groupJID: jid
            ) { [weak self] projection in
                DispatchQueue.main.async {
                    self?.apply(projection, force: false)
                }
            }
        } catch {
            DDLogDebug("GroupchatSettingsNewbiesPermissionsViewController: \(#function). \(error.localizedDescription)")
        }
    }

    override func onAppear() {
        super.onAppear()
        refreshAuthoritativeState()
    }

    deinit {
        refreshTask?.cancel()
        saveTask?.cancel()
        projectionObservation?.invalidate()
    }

    private func apply(_ projection: GroupRepositoryProjection, force: Bool) {
        canEdit = projection.capabilities.changeDefaultPermissions
        guard force || !changesObserver.value else { return }
        if let defaults = projection.state.permissionSets.first(where: { $0.scope == .defaults }) {
            baselinePermissions = defaults.permissions
        }
        let newbies = projection.state.permissionSets
            .first(where: { $0.scope == .newbies })?.permissions ?? []
        canReset = canEdit && !newbies.isEmpty
        rebuildRows(newbies: newbies)
    }

    private func rebuildRows(newbies: [GroupPermission]) {
        let allowedBaseline = baselinePermissions.filter {
            $0.name.lowercased() != GroupMemberRole.owner.rawValue
        }
        let templates = allowedBaseline.isEmpty ? newbies : allowedBaseline
        datasource = templates.compactMap { baseline in
            guard baseline.name.lowercased() != GroupMemberRole.owner.rawValue else { return nil }
            let key = Datasource.key(for: baseline)
            let effective = newbies.first { Datasource.key(for: $0) == key } ?? baseline
            return Datasource(permission: effective)
        }
        changesObserver.accept(false)
        updateNavigationItems(hasChanges: false)
        tableView.reloadData()
    }

    private func refreshAuthoritativeState() {
        guard refreshTask == nil,
              let account = AccountManager.shared.find(for: owner) else {
            return
        }
        refreshTask = Task { [weak self, weak account] in
            guard let self, let account else { return }
            defer { self.refreshTask = nil }
            do {
                async let defaults = account.groupchatService.getPermissions(
                    groupJID: self.jid,
                    scope: GroupPermissionScope.defaults
                )
                async let newbies = account.groupchatService.getPermissions(
                    groupJID: self.jid,
                    scope: GroupPermissionScope.newbies
                )
                let values = try await (defaults, newbies)
                let repository: GroupRepository
                if let existingRepository = self.repository {
                    repository = existingRepository
                } else {
                    repository = GroupRepository(realm: try WRealm.safe())
                }
                self.repository = repository
                try repository.replacePermissionSet(values.0, owner: self.owner, groupJID: self.jid)
                try repository.replacePermissionSet(values.1, owner: self.owner, groupJID: self.jid)
            } catch is CancellationError {
                return
            } catch {
                DDLogDebug("GroupchatSettingsNewbiesPermissionsViewController: \(#function). \(error.localizedDescription)")
            }
        }
    }

    @objc private func onCancel() {
        navigationController?.popViewController(animated: true)
    }

    @objc private func onSave() {
        guard saveTask == nil,
              canEdit,
              changesObserver.value,
              let account = AccountManager.shared.find(for: owner) else {
            return
        }
        let replacement = GroupPermissionMutationBuilder.newbiesReplacement(
            rows: datasource.map(\.editorRow)
        )
        tableView.isUserInteractionEnabled = false
        saveBarButton.isEnabled = false
        saveTask = Task { [weak self, weak account] in
            guard let self, let account else { return }
            defer {
                self.saveTask = nil
                self.tableView.isUserInteractionEnabled = true
                self.saveBarButton.isEnabled = true
            }
            do {
                let authoritative = try await account.groupchatService.setPermissions(
                    groupJID: self.jid,
                    permissions: replacement
                )
                let repository: GroupRepository
                if let existingRepository = self.repository {
                    repository = existingRepository
                } else {
                    repository = GroupRepository(realm: try WRealm.safe())
                }
                self.repository = repository
                try repository.replacePermissionSet(authoritative, owner: self.owner, groupJID: self.jid)
                ToastPresenter().presentSuccess(message: "Changes saved")
                self.navigationController?.popViewController(animated: true)
            } catch is CancellationError {
                return
            } catch {
                ToastPresenter().presentError(message: "Error: \(error.localizedDescription)")
            }
        }
    }

    @objc private func onReset() {
        guard saveTask == nil, canReset else { return }
        let alert = UIAlertController(
            title: "Reset".localizeString(
                id: "groupchat_permissions_reset_action",
                arguments: []
            ),
            message: "Remove all temporary permissions for new members?".localizeString(
                id: "groupchat_permissions_reset_newbies_confirmation",
                arguments: []
            ),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: "Cancel".localizeString(id: "cancel", arguments: []),
            style: .cancel
        ))
        alert.addAction(UIAlertAction(
            title: "Reset".localizeString(
                id: "groupchat_permissions_reset_action",
                arguments: []
            ),
            style: .destructive
        ) { [weak self] _ in
            self?.performNewbiesReset()
        })
        present(alert, animated: true)
    }

    private func performNewbiesReset() {
        guard saveTask == nil,
              canReset,
              let account = AccountManager.shared.find(for: owner) else {
            return
        }
        tableView.isUserInteractionEnabled = false
        resetBarButton.isEnabled = false
        saveTask = Task { [weak self, weak account] in
            guard let self, let account else { return }
            defer {
                self.saveTask = nil
                self.tableView.isUserInteractionEnabled = true
                self.resetBarButton.isEnabled = true
            }
            do {
                let authoritative = try await account.groupchatService.resetNewbiesPermissions(
                    groupJID: self.jid
                )
                let repository: GroupRepository
                if let existingRepository = self.repository {
                    repository = existingRepository
                } else {
                    repository = GroupRepository(realm: try WRealm.safe())
                }
                self.repository = repository
                try repository.replacePermissionSet(
                    authoritative,
                    owner: self.owner,
                    groupJID: self.jid
                )
                ToastPresenter().presentSuccess(
                    message: "Permissions reset".localizeString(
                        id: "groupchat_permissions_reset_success",
                        arguments: []
                    )
                )
            } catch is CancellationError {
                return
            } catch {
                ToastPresenter().presentError(message: "Error: \(error.localizedDescription)")
            }
        }
    }

    private func updateNavigationItems(hasChanges: Bool) {
        navigationItem.setLeftBarButton(
            hasChanges ? cancelBarButton : navigationItem.backBarButtonItem,
            animated: true
        )
        navigationItem.setRightBarButton(
            hasChanges ? saveBarButton : (canReset ? resetBarButton : nil),
            animated: true
        )
    }

    private func updateRow(key: String, mutation: (inout GroupPermissionEditorRow) -> Void) {
        guard let item = datasource.first(where: { $0.key == key }),
              !item.editorRow.permission.fixed else {
            return
        }
        mutation(&item.editorRow)
        item.editorRow.changed = item.editorRow.status != item.editorRow.permission.status
            || item.editorRow.seconds != GroupPermissionMutationBuilder.durationSeconds(
                for: item.editorRow.permission
            )
        changesObserver.accept(datasource.contains { $0.editorRow.changed })
        tableView.reloadRows(
            at: [IndexPath(row: datasource.firstIndex(where: { $0 === item })!, section: 0)],
            with: .none
        )
    }

    private func presentDurationPicker(key: String?) {
        let picker = TimePickerPresenter()
        picker.delegate = self
        picker.present(
            in: self,
            title: "Select custom duration",
            message: "\n\n\n\n\n\n",
            cancel: "Cancel",
            animated: true,
            key: key
        )
    }
}

extension GroupchatSettingsNewbiesPermissionsViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat { 52 }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 1 else { return }
        let duration = durations[indexPath.row]
        if duration.key == "custom" {
            presentDurationPicker(key: nil)
            return
        }
        selectedDurationSeconds = duration.seconds
        datasource.filter { $0.editorRow.changed }.forEach {
            $0.editorRow.seconds = duration.seconds
        }
        changesObserver.accept(datasource.contains { $0.editorRow.changed })
        tableView.reloadSections(IndexSet(integer: 0), with: .none)
    }
}

extension GroupchatSettingsNewbiesPermissionsViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int { 2 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? datasource.count : durations.count
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 0
            ? "These temporary permissions are sent as one full replacement set."
            : nil
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 {
            let item = datasource[indexPath.row]
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: PermissionCell.cellName,
                for: indexPath
            ) as? PermissionCell else {
                fatalError("Unexpected newbie permission cell")
            }
            cell.configure(
                title: item.title,
                key: item.key,
                status: item.editorRow.status,
                originalStatus: item.editorRow.permission.status,
                seconds: item.editorRow.seconds,
                isEnabled: canEdit && !item.editorRow.permission.fixed
            )
            cell.onSwitchChanged = { [weak self] key, value in
                self?.updateRow(key: key) { row in
                    row.status = value
                    if value != row.permission.status,
                       row.seconds == nil {
                        row.seconds = self?.selectedDurationSeconds
                    }
                }
            }
            cell.onDurationRequested = { [weak self] key in
                self?.presentDurationPicker(key: key)
            }
            cell.selectionStyle = .none
            return cell
        }

        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: DurationCell.cellName,
            for: indexPath
        ) as? DurationCell else {
            fatalError("Unexpected duration cell")
        }
        cell.configure(title: durations[indexPath.row].title)
        return cell
    }
}

extension GroupchatSettingsNewbiesPermissionsViewController: TimePickerAlertControllerDelegate {
    func timePickerAlertControllerDidCancel() {}

    func timePickerAlertControllerDidSet(
        key: String?,
        days: Int?,
        hours: Int?,
        minutes: Int?
    ) {
        let seconds = UInt64(max(0, days ?? 0)) * 86_400
            + UInt64(max(0, hours ?? 0)) * 3_600
            + UInt64(max(0, minutes ?? 0)) * 60
        let normalized = seconds > 0 ? seconds : nil
        if let key {
            updateRow(key: key) { $0.seconds = normalized }
        } else {
            selectedDurationSeconds = normalized
            datasource.filter { $0.editorRow.changed }.forEach {
                $0.editorRow.seconds = normalized
            }
            changesObserver.accept(datasource.contains { $0.editorRow.changed })
            tableView.reloadSections(IndexSet(integer: 0), with: .none)
        }
    }
}
