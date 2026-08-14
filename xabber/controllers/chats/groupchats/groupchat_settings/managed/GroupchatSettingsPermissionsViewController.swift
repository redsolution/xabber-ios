import UIKit
import RxSwift
import RxCocoa
import RxRelay
import MaterialComponents.MDCPalettes
import CocoaLumberjack

struct GroupPermissionEditorRow: Equatable, Sendable {
    let permission: GroupPermission
    var status: Bool
    var seconds: UInt64?
    var changed: Bool
}

enum GroupPermissionMutationBuilder {
    static func partial(
        scope: GroupPermissionScope,
        targetMemberID: String?,
        rows: [GroupPermissionEditorRow]
    ) -> GroupPermissionSet? {
        if scope == .newbies { return nil }
        if scope == .direct,
           targetMemberID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            return nil
        }
        let permissions = rows
            .filter(\.changed)
            .compactMap { mutationPermission(from: $0, scope: scope) }
        guard !permissions.isEmpty else { return nil }
        return GroupPermissionSet(
            scope: scope,
            target: scope == .direct ? targetMemberID : nil,
            permissions: permissions
        )
    }

    static func newbiesReplacement(
        rows: [GroupPermissionEditorRow]
    ) -> GroupPermissionSet {
        GroupPermissionSet(
            scope: .newbies,
            permissions: rows.compactMap {
                mutationPermission(from: $0, scope: .newbies)
            }
        )
    }

    static func durationSeconds(
        for permission: GroupPermission,
        now: UInt64 = UInt64(Date().timeIntervalSince1970)
    ) -> UInt64? {
        if let expires = permission.expires {
            return expires > now ? expires - now : nil
        }
        return permission.seconds
    }

    private static func mutationPermission(
        from row: GroupPermissionEditorRow,
        scope: GroupPermissionScope
    ) -> GroupPermission? {
        guard row.permission.name.lowercased() != GroupMemberRole.owner.rawValue else {
            return nil
        }
        return GroupPermission(
            name: row.permission.name,
            level: row.permission.level,
            status: row.status,
            seconds: scope == .defaults ? nil : row.seconds,
            expires: nil,
            tag: row.permission.tag,
            fixed: row.permission.fixed,
            display: row.permission.display
        )
    }
}

class GroupchatSettingsPermissionsViewController: SimpleBaseViewController {
    final class SettingsSwitchCell: UITableViewCell {
        static let cellName = "CanonicalGroupPermissionSwitchCell"
        private let titleLabel = UILabel()
        let switchView = UISwitch()
        private var key = ""
        private var originalStatus = false
        var onSwitchValueChanged: ((String, Bool) -> Void)?

        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            let stack = UIStackView(arrangedSubviews: [titleLabel, switchView])
            stack.axis = .horizontal
            stack.alignment = .center
            stack.spacing = 8
            contentView.addSubview(stack)
            stack.fillSuperviewWithOffset(top: 4, bottom: 4, left: 16, right: 16)
            titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
            switchView.addTarget(self, action: #selector(onChange), for: .valueChanged)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func configure(
            title: String,
            isOn: Bool,
            key: String,
            originalStatus: Bool,
            isEnabled: Bool
        ) {
            titleLabel.text = title
            switchView.isOn = isOn
            switchView.isEnabled = isEnabled
            self.key = key
            self.originalStatus = originalStatus
            let changed = originalStatus != isOn
            switchView.onTintColor = changed ? .systemGreen : MDCPalette.green.tint100
        }

        @objc private func onChange(_ sender: UISwitch) {
            switchView.onTintColor = sender.isOn == originalStatus
                ? MDCPalette.green.tint100
                : .systemGreen
            onSwitchValueChanged?(key, sender.isOn)
        }
    }

    final class MemberCell: UITableViewCell {
        static let cellName = "CanonicalGroupPermissionMemberCell"

        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: .subtitle, reuseIdentifier: reuseIdentifier)
            accessoryType = .disclosureIndicator
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func configure(_ member: GroupMember) {
            textLabel?.text = member.nickname?.isEmpty == false ? member.nickname : member.id
            let role = member.role?.rawValue ?? GroupMemberRole.member.rawValue
            detailTextLabel?.text = member.jid.map { "\(role) · \($0)" } ?? role
        }
    }

    final class Datasource {
        enum Kind { case permission, button, member }

        let kind: Kind
        let key: String
        let title: String
        var editorRow: GroupPermissionEditorRow?
        let badge: String?
        let member: GroupMember?

        init(permission: GroupPermission) {
            kind = .permission
            key = permission.name
            title = permission.display ?? permission.name
            editorRow = GroupPermissionEditorRow(
                permission: permission,
                status: permission.status,
                seconds: nil,
                changed: false
            )
            badge = nil
            member = nil
        }

        init(button key: String, title: String, badge: String?) {
            kind = .button
            self.key = key
            self.title = title
            self.badge = badge
            editorRow = nil
            member = nil
        }

        init(member: GroupMember) {
            kind = .member
            key = member.id
            title = member.nickname ?? member.id
            self.member = member
            editorRow = nil
            badge = nil
        }
    }

    private var datasource: [[Datasource]] = [[], [], []]
    private(set) var defaultPermissions: [GroupPermission] = []
    private var repository: GroupRepository?
    private var projectionObservation: GroupRepositoryObservation?
    private var refreshTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var canEditDefaults = false
    private let changesObserver = BehaviorRelay<Bool>(value: false)

    private let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .insetGrouped)
        view.register(SettingsSwitchCell.self, forCellReuseIdentifier: SettingsSwitchCell.cellName)
        view.register(GroupchatSettingsViewControllerT.SettingsItemCell.self, forCellReuseIdentifier: GroupchatSettingsViewControllerT.SettingsItemCell.cellName)
        view.register(MemberCell.self, forCellReuseIdentifier: MemberCell.cellName)
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
            DDLogDebug("GroupchatSettingsPermissionsViewController: \(#function). \(error.localizedDescription)")
        }
    }

    override func setupSubviews() {
        super.setupSubviews()
        view.addSubview(tableView)
        tableView.fillSuperview()
    }

    override func configure() {
        super.configure()
        title = "Permissions"
        tableView.dataSource = self
        tableView.delegate = self
        cancelBarButton.action = #selector(onCancel)
        cancelBarButton.target = self
        saveBarButton.action = #selector(onSave)
        saveBarButton.target = self
        resetBarButton.action = #selector(onReset)
        resetBarButton.target = self
        resetBarButton.accessibilityIdentifier = "groupchat_permissions_reset_defaults"
    }

    override func subscribe() {
        super.subscribe()
        changesObserver
            .asObservable()
            .distinctUntilChanged()
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] hasChanges in
                self?.updateNavigationItems(hasChanges: hasChanges)
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
            DDLogDebug("GroupchatSettingsPermissionsViewController: \(#function). \(error.localizedDescription)")
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
        canEditDefaults = projection.capabilities.changeDefaultPermissions
        guard force || !changesObserver.value else { return }
        let defaults = projection.state.permissionSets.first { $0.scope == .defaults }
        let newbies = projection.state.permissionSets.first { $0.scope == .newbies }
        defaultPermissions = defaults?.permissions.filter {
            $0.name.lowercased() != GroupMemberRole.owner.rawValue
        } ?? []
        let directTargets = Set(
            projection.state.permissionSets.compactMap { set in
                set.scope == .direct && !set.permissions.isEmpty ? set.target : nil
            }
        )
        datasource = [
            defaultPermissions.map { Datasource(permission: $0) },
            [
                Datasource(
                    button: "newbies",
                    title: "Permissions for new members",
                    badge: "\(newbies?.permissions.count ?? 0) / \(defaultPermissions.count)"
                )
            ],
            projection.state.members
                .filter { directTargets.contains($0.id) }
                .map { Datasource(member: $0) }
        ]
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
                async let members = account.groupchatService.refreshMembers(groupJID: self.jid)
                let values = try await (defaults, newbies, members)
                let repository: GroupRepository
                if let existingRepository = self.repository {
                    repository = existingRepository
                } else {
                    repository = GroupRepository(realm: try WRealm.safe())
                }
                self.repository = repository
                try repository.replacePermissionSet(values.0, owner: self.owner, groupJID: self.jid)
                try repository.replacePermissionSet(values.1, owner: self.owner, groupJID: self.jid)
                try repository.replaceMembers(values.2, owner: self.owner, groupJID: self.jid)
            } catch is CancellationError {
                return
            } catch {
                DDLogDebug("GroupchatSettingsPermissionsViewController: \(#function). \(error.localizedDescription)")
            }
        }
    }

    @objc private func onCancel() {
        navigationController?.popViewController(animated: true)
    }

    @objc private func onSave() {
        guard saveTask == nil,
              canEditDefaults,
              let mutation = GroupPermissionMutationBuilder.partial(
                scope: .defaults,
                targetMemberID: nil,
                rows: datasource[0].compactMap(\.editorRow)
              ),
              let account = AccountManager.shared.find(for: owner) else {
            return
        }
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
                    permissions: mutation
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
        guard saveTask == nil, canEditDefaults else { return }
        let alert = UIAlertController(
            title: "Reset".localizeString(
                id: "groupchat_permissions_reset_action",
                arguments: []
            ),
            message: "Restore the built-in default group permissions?".localizeString(
                id: "groupchat_permissions_reset_defaults_confirmation",
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
            self?.performDefaultReset()
        })
        present(alert, animated: true)
    }

    private func performDefaultReset() {
        guard saveTask == nil,
              canEditDefaults,
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
                let authoritative = try await account.groupchatService.resetDefaultPermissions(
                    groupJID: self.jid
                )
                let repository: GroupRepository
                if let currentRepository = self.repository {
                    repository = currentRepository
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
            hasChanges ? saveBarButton : (canEditDefaults ? resetBarButton : nil),
            animated: true
        )
    }

    private func onSwitchChanged(key: String, value: Bool) {
        guard let item = datasource[0].first(where: { $0.key == key }),
              var row = item.editorRow,
              !row.permission.fixed else {
            return
        }
        row.status = value
        row.changed = value != row.permission.status
        item.editorRow = row
        changesObserver.accept(datasource[0].contains { $0.editorRow?.changed == true })
    }
}

extension GroupchatSettingsPermissionsViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        datasource[indexPath.section][indexPath.row].kind == .member ? 64 : 52
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let item = datasource[indexPath.section][indexPath.row]
        switch item.kind {
        case .member:
            guard let member = item.member else { return }
            let controller = GroupchatSettingsRestrictUserViewController()
            controller.userId = member.id
            controller.jid = jid
            controller.owner = owner
            navigationController?.pushViewController(controller, animated: true)
        case .button where item.key == "newbies":
            let controller = GroupchatSettingsNewbiesPermissionsViewController()
            controller.jid = jid
            controller.owner = owner
            controller.baselinePermissions = defaultPermissions
            navigationController?.pushViewController(controller, animated: true)
        case .button, .permission:
            break
        }
    }
}

extension GroupchatSettingsPermissionsViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int { datasource.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        datasource[section].count
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch section {
        case 0:
            return "Default permissions apply to members unless a personal permission overrides them."
        case 1:
            return "New-member permissions replace the full temporary permission set."
        default:
            return nil
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = datasource[indexPath.section][indexPath.row]
        switch item.kind {
        case .permission:
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: SettingsSwitchCell.cellName,
                for: indexPath
            ) as? SettingsSwitchCell,
                  let row = item.editorRow else {
                fatalError("Unexpected permission cell")
            }
            cell.configure(
                title: item.title,
                isOn: row.status,
                key: item.key,
                originalStatus: row.permission.status,
                isEnabled: canEditDefaults && !row.permission.fixed
            )
            cell.onSwitchValueChanged = { [weak self] key, value in
                self?.onSwitchChanged(key: key, value: value)
            }
            cell.selectionStyle = .none
            return cell
        case .button:
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: GroupchatSettingsViewControllerT.SettingsItemCell.cellName,
                for: indexPath
            ) as? GroupchatSettingsViewControllerT.SettingsItemCell else {
                fatalError("Unexpected permission navigation cell")
            }
            cell.configure(title: item.title, badge: item.badge ?? "", icon: "person.badge.clock")
            return cell
        case .member:
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: MemberCell.cellName,
                for: indexPath
            ) as? MemberCell,
                  let member = item.member else {
                fatalError("Unexpected member cell")
            }
            cell.configure(member)
            return cell
        }
    }
}
