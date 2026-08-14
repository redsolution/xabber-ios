import Foundation
import UIKit
import CocoaLumberjack

final class GroupchatMembersListViewController: SimpleBaseViewController {
    final class ButtonTableCell: UITableViewCell {
        static let cellName = "ButtonTableCell"
        private let titleLabel = UILabel()

        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            titleLabel.textColor = .tintColor
            contentView.addSubview(titleLabel)
            titleLabel.fillSuperviewWithOffset(top: 0, bottom: 0, left: 16, right: 16)
            accessoryType = .disclosureIndicator
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func configure(title: String) {
            titleLabel.text = title
        }
    }

    struct Datasource: Equatable {
        let member: GroupMember
        let isMe: Bool
        let canPromote: Bool
        let canRestrict: Bool
        let canEdit: Bool
        let canKick: Bool

        var displayName: String {
            member.nickname?.isNotEmpty == true
                ? member.nickname!
                : (member.jid ?? member.id)
        }

        var subtitle: String {
            guard let lastSeen = member.lastSeen else {
                return member.jid ?? "Offline".localizeString(id: "unavailable", arguments: [])
            }
            return DateFormatter.localizedString(
                from: lastSeen,
                dateStyle: .medium,
                timeStyle: .short
            )
        }
    }

    var permissionScope = "member"
    var canPromote = true
    var canRestrict = true
    var canEdit = true
    var canKick = true

    private let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .insetGrouped)
        view.register(CommonMemberTableCell.self, forCellReuseIdentifier: CommonMemberTableCell.cellName)
        view.register(ButtonTableCell.self, forCellReuseIdentifier: ButtonTableCell.cellName)
        return view
    }()
    private var datasource: [Datasource] = []
    private var repository: GroupRepository?
    private var observation: GroupRepositoryObservation?
    private var projection: GroupRepositoryProjection?
    private var refreshTask: Task<Void, Never>?
    private var isPromoteAdmin = false

    func configurePromoteAdmin() {
        isPromoteAdmin = true
    }

    override func setupSubviews() {
        super.setupSubviews()
        view.addSubview(tableView)
        tableView.fillSuperview()
    }

    override func configure() {
        super.configure()
        tableView.delegate = self
        tableView.dataSource = self
        if isPromoteAdmin {
            title = "Select user"
        } else if permissionScope == "owner,admin" {
            title = "Administrators"
        } else if permissionScope == "member" {
            title = "Members".localizeString(id: "group_settings__members_list__header", arguments: [])
        } else {
            title = "Members".localizeString(id: "group_settings__members_list__header", arguments: [])
        }
    }

    override func subscribe() {
        super.subscribe()
        do {
            let repository = GroupRepository(realm: try WRealm.safe())
            self.repository = repository
            observation = try repository.observeProjection(
                owner: owner,
                groupJID: jid
            ) { [weak self] projection in
                DispatchQueue.main.async {
                    self?.apply(projection)
                }
            }
            refreshMembers()
        } catch {
            present(error: error)
        }
    }

    override func unsubscribe() {
        refreshTask?.cancel()
        refreshTask = nil
        observation?.invalidate()
        observation = nil
        repository = nil
        super.unsubscribe()
    }

    private func refreshMembers() {
        refreshTask?.cancel()
        guard let account = AccountManager.shared.find(for: owner) else {
            present(error: GroupchatServiceError.notPrepared)
            return
        }
        refreshTask = Task { @MainActor [weak self, weak account] in
            guard let self, let account else { return }
            do {
                let members = try await account.groupchatService.refreshMembers(groupJID: jid)
                try repository?.replaceMembers(members, owner: owner, groupJID: jid)
            } catch is CancellationError {
                return
            } catch {
                present(error: error)
            }
        }
    }

    private func apply(_ projection: GroupRepositoryProjection) {
        self.projection = projection
        let allowedRoles = canonicalRoles(from: permissionScope)
        let capabilities = projection.capabilities
        datasource = projection.state.members
            .filter { allowedRoles.contains($0.role ?? .none) }
            .map { member in
                let isMe = member.id == projection.selfMemberID
                return Datasource(
                    member: member,
                    isMe: isMe,
                    canPromote: !isMe && canPromote && capabilities.createAdmins,
                    canRestrict: !isMe && canRestrict && capabilities.changePermissions,
                    canEdit: !isMe && canEdit && capabilities.changeUserInfo,
                    canKick: !isMe && canKick && capabilities.blockUsers && member.jid?.isNotEmpty == true
                )
            }
            .sorted { lhs, rhs in
                if lhs.isMe != rhs.isMe { return lhs.isMe }
                let lhsRank = roleRank(lhs.member.role)
                let rhsRank = roleRank(rhs.member.role)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
        tableView.reloadData()
    }

    private func canonicalRoles(from scope: String) -> Set<GroupMemberRole> {
        let roles = Set(scope.split(separator: ",").compactMap { GroupMemberRole(rawValue: String($0)) })
        return roles.isEmpty ? [.owner, .admin, .member] : roles
    }

    private func roleRank(_ role: GroupMemberRole?) -> Int {
        switch role {
        case .owner: return 0
        case .admin: return 1
        case .member: return 2
        case .some(.none), nil: return 3
        }
    }

    private func openMember(_ memberID: String) {
        let controller = GroupchatContactInfoViewController()
        controller.owner = owner
        controller.jid = jid
        controller.userId = memberID
        navigationController?.pushViewController(controller, animated: true)
    }

    private func kick(_ item: Datasource) {
        guard let account = AccountManager.shared.find(for: owner) else { return }
        Task { @MainActor [weak self, weak account] in
            guard let self, let account else { return }
            view.makeToastActivity(.center)
            defer { view.hideToastActivity() }
            do {
                let members = try await account.groupchatService.kickMember(
                    groupJID: jid,
                    member: item.member
                )
                try repository?.replaceMembers(members, owner: owner, groupJID: jid)
            } catch let partial as GroupModerationPartialFailure {
                do {
                    if let members = partial.members {
                        try repository?.replaceMembers(
                            members,
                            owner: owner,
                            groupJID: jid
                        )
                    }
                } catch {
                    DDLogDebug("Group kick projection: \(error.localizedDescription)")
                }
                present(error: partial)
            } catch {
                present(error: error)
            }
        }
    }

    private func createPrivateChat(_ memberID: String) {
        guard let account = AccountManager.shared.find(for: owner) else { return }
        Task { @MainActor [weak self, weak account] in
            guard let self, let account else { return }
            view.makeToastActivity(.center)
            defer { view.hideToastActivity() }
            do {
                let snapshot = try await CanonicalGroupP2PFlow.createOrJoin(
                    owner: owner,
                    parentJID: jid,
                    repository: GroupRepository(realm: try WRealm.safe()),
                    create: {
                        try await account.groupchatService.createP2P(
                            parentJID: self.jid,
                            memberID: memberID
                        )
                    },
                    joinExisting: {
                        try account.groupchatService.sendJoin(groupJID: $0)
                    }
                )
                guard let p2pJID = snapshot.jid else {
                    throw GroupchatServiceError.missingCreatedGroupJID
                }
                let chat = ChatViewController()
                chat.owner = owner
                chat.jid = p2pJID
                chat.conversationType = .group
                showDetail(chat, currentVc: self)
            } catch {
                present(error: error)
            }
        }
    }

    private func present(error: Error) {
        DDLogDebug("GroupchatMembersListViewController: \(error.localizedDescription)")
        ErrorMessagePresenter().present(
            in: self,
            message: CanonicalGroupMembershipLifecycle.localizedErrorMessage(error),
            animated: true,
            completion: nil
        )
    }
}

extension GroupchatMembersListViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        permissionScope == "owner,admin" && !isPromoteAdmin ? 2 : 1
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        permissionScope == "owner,admin" && !isPromoteAdmin && section == 0 ? 1 : datasource.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if permissionScope == "owner,admin" && !isPromoteAdmin && indexPath.section == 0 {
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: ButtonTableCell.cellName,
                for: indexPath
            ) as? ButtonTableCell else { fatalError("ButtonTableCell is not registered") }
            cell.configure(title: "Add Administrator")
            return cell
        }
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: CommonMemberTableCell.cellName,
            for: indexPath
        ) as? CommonMemberTableCell else { fatalError("CommonMemberTableCell is not registered") }
        let item = datasource[indexPath.row]
        cell.configure(
            avatarUrl: item.member.avatar?.url,
            jid: jid,
            owner: owner,
            userId: item.member.id,
            title: item.displayName,
            badge: item.member.badge ?? "",
            isMe: item.isMe,
            subtitle: item.subtitle,
            status: .offline,
            entity: .contact,
            role: item.member.role == .owner
                ? .owner
                : (item.member.role == .admin ? .admin : .member)
        )
        return cell
    }
}

extension GroupchatMembersListViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat { 64 }
    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat { 0 }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if permissionScope == "owner,admin" && !isPromoteAdmin && indexPath.section == 0 {
            let controller = GroupchatMembersListViewController()
            controller.permissionScope = "member"
            controller.jid = jid
            controller.owner = owner
            controller.configurePromoteAdmin()
            navigationController?.pushViewController(controller, animated: true)
            return
        }
        let item = datasource[indexPath.row]
        if isPromoteAdmin || permissionScope == "owner,admin" {
            let controller = GroupchatSettingsPromoteAdminViewController()
            controller.userId = item.member.id
            controller.jid = jid
            controller.owner = owner
            navigationController?.pushViewController(controller, animated: true)
        } else {
            openMember(item.member.id)
        }
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard !(permissionScope == "owner,admin" && indexPath.section == 0), !isPromoteAdmin else { return nil }
        let item = datasource[indexPath.row]
        var actions: [UIContextualAction] = []

        let info = UIContextualAction(style: .normal, title: "Information") { [weak self] _, _, completion in
            self?.openMember(item.member.id)
            completion(true)
        }
        info.backgroundColor = .systemBlue
        actions.append(info)

        if item.canKick {
            let kick = UIContextualAction(style: .destructive, title: "Kick") { [weak self] _, _, completion in
                self?.kick(item)
                completion(true)
            }
            actions.append(kick)
        }
        if item.canRestrict {
            let restrict = UIContextualAction(style: .normal, title: "Restrict") { [weak self] _, _, completion in
                guard let self else { completion(false); return }
                let controller = GroupchatSettingsRestrictUserViewController()
                controller.userId = item.member.id
                controller.jid = jid
                controller.owner = owner
                navigationController?.pushViewController(controller, animated: true)
                completion(true)
            }
            restrict.backgroundColor = .systemYellow
            actions.append(restrict)
        }
        if item.canPromote {
            let promote = UIContextualAction(style: .normal, title: "Promote") { [weak self] _, _, completion in
                guard let self else { completion(false); return }
                let controller = GroupchatSettingsPromoteAdminViewController()
                controller.userId = item.member.id
                controller.jid = jid
                controller.owner = owner
                navigationController?.pushViewController(controller, animated: true)
                completion(true)
            }
            promote.backgroundColor = .systemBlue
            actions.append(promote)
        }
        return UISwipeActionsConfiguration(actions: actions)
    }

    func tableView(
        _ tableView: UITableView,
        leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard !(permissionScope == "owner,admin" && indexPath.section == 0), !isPromoteAdmin else { return nil }
        let item = datasource[indexPath.row]
        guard !item.isMe else { return nil }
        if let realJID = item.member.jid {
            let direct = UIContextualAction(style: .normal, title: "Chat") { [weak self] _, _, completion in
                guard let self else { completion(false); return }
                let chat = ChatViewController()
                chat.owner = owner
                chat.jid = realJID
                chat.conversationType = ClientSynchronizationManager.ConversationType(
                    rawValue: CommonConfigManager.shared.config.locked_conversation_type
                ) ?? .regular
                showDetail(chat, currentVc: self)
                completion(true)
            }
            return UISwipeActionsConfiguration(actions: [direct])
        }
        guard item.member.allowsPeerToPeer else { return nil }
        let privateChat = UIContextualAction(style: .normal, title: "Chat") { [weak self] _, _, completion in
            self?.createPrivateChat(item.member.id)
            completion(true)
        }
        return UISwipeActionsConfiguration(actions: [privateChat])
    }
}
