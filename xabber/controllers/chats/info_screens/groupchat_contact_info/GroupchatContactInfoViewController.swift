//
//  Copyright (c) Xabber
//

import Foundation
import UIKit
import CocoaLumberjack

extension GroupMemberRole {
    var localized: String {
        switch self {
        case .owner:
            return "Owner".localizeString(id: "groupchat_personal_status_owner", arguments: [])
        case .admin:
            return "Administrator".localizeString(id: "groupchat_personal_status_administrator", arguments: [])
        case .member, .none:
            return "Member".localizeString(id: "groupchat_personal_status_member", arguments: [])
        }
    }
}

/// Canonical member-card projection for a Xabber Group.
///
/// The controller deliberately keeps only immutable protocol values. Realm is
/// observed through `GroupRepository`; mutations go through `GroupchatService`.
class GroupchatContactInfoViewController: SimpleBaseViewController {
    class Datasource {
        enum Kind { case text, selection, status, button }

        var kind: Kind
        var title: String
        var subtitle: String?
        var key: String?
        var disabled: Bool
        var childs: [Datasource]

        init(
            _ kind: Kind,
            title: String,
            subtitle: String? = nil,
            key: String? = nil,
            disabled: Bool = false,
            childs: [Datasource] = []
        ) {
            self.kind = kind
            self.title = title
            self.subtitle = subtitle?.isEmpty == true ? nil : subtitle
            self.key = key
            self.disabled = disabled
            self.childs = childs
        }
    }

    static func canonicalSections(_ sections: [Datasource]) -> [Datasource] {
        sections.filter { !$0.childs.isEmpty }
    }

    open var userId = ""
    open var shouldResetNavbar = false

    internal let headerView = InfoScreenHeaderView(frame: .zero)
    internal let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .insetGrouped)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.register(UITableViewCell.self, forCellReuseIdentifier: "ButtonCell")
        view.register(StatusInfoCell.self, forCellReuseIdentifier: StatusInfoCell.cellName)
        return view
    }()

    internal var datasource: [Datasource] = []

    internal var isIncognitoGroup = false
    internal var isMyProfile = false
    internal var canBlock = false
    internal var canChangeBadge = false
    internal var canChangeNickname = false
    internal var canChangeAvatars = false
    internal var canChangeUserPermissions: Bool?
    internal var userRole: GroupMemberRole = .member
    internal var userOnline = false
    internal var onlineCount = 0
    internal var userBadge = ""
    internal var userNickname = ""
    internal var userJid: String?
    internal var isBlocked = false
    internal var isKicked = false

    internal var repository: GroupRepository?
    internal var projectionObservation: GroupRepositoryObservation?
    internal var currentProjection: GroupRepositoryProjection?
    internal var currentMember: GroupMember?
    internal var currentBlocklist: [String] = []
    internal var hasLoadedMembers = false
    internal var refreshTask: Task<Void, Never>?

    internal let lastSeenDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd-yyyy HH:mm"
        return formatter
    }()

    override func loadDatasource() {
        super.loadDatasource()
        startProjectionIfNeeded()
        refreshCanonicalMember()
    }

    override func configure() {
        super.configure()
        view.addSubview(tableView)
        tableView.fillSuperview()
        tableView.delegate = self
        tableView.dataSource = self
        tableView.tableHeaderView = headerView
        headerView.delegate = self
        configureHeaderButtons()
        navigationItem.setRightBarButton(nil, animated: false)
    }

    override func subscribe() {
        super.subscribe()
        startProjectionIfNeeded()
    }

    override func unsubscribe() {
        refreshTask?.cancel()
        refreshTask = nil
        projectionObservation?.invalidate()
        projectionObservation = nil
        repository = nil
        super.unsubscribe()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reloadDatasource),
            name: .newMaskSelected,
            object: nil
        )
    }

    override func reloadDatasource() {
        headerView.setMask()
        if let currentProjection { apply(currentProjection) }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        subscribe()
        refreshCanonicalMember()
        navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
        navigationController?.navigationBar.shadowImage = UIImage()
        headerView.applyHeaderLayout(to: tableView, width: view.bounds.width)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        unsubscribe()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if shouldResetNavbar {
            navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
            navigationController?.navigationBar.shadowImage = nil
        }
    }

    deinit {
        refreshTask?.cancel()
        projectionObservation?.invalidate()
    }

    internal func refreshCanonicalMember() {
        refreshTask?.cancel()
        guard let account = AccountManager.shared.find(for: owner) else { return }
        refreshTask = Task { @MainActor [weak self, weak account] in
            guard let self, let account else { return }
            do {
                async let snapshotRequest = account.groupchatService.refreshGroup(groupJID: jid)
                async let membersRequest = account.groupchatService.refreshMembers(groupJID: jid)
                async let blocklistRequest = account.groupchatService.refreshBlocklist(groupJID: jid)
                let (snapshot, members, blocklist) = try await (
                    snapshotRequest,
                    membersRequest,
                    blocklistRequest
                )
                guard !Task.isCancelled else { return }
                let repository: GroupRepository
                if let existingRepository = self.repository {
                    repository = existingRepository
                } else {
                    repository = GroupRepository(realm: try WRealm.safe())
                }
                self.repository = repository
                try repository.applySnapshot(snapshot, owner: owner, groupJID: jid)
                try repository.replaceMembers(members, owner: owner, groupJID: jid)
                var projection = try repository.projection(owner: owner, groupJID: jid)
                if let selfMemberID = projection.selfMemberID {
                    let permissionSet = try await account.groupchatService.getPermissions(
                        groupJID: jid,
                        scope: .direct,
                        targetMemberID: selfMemberID
                    )
                    try repository.replacePermissionSet(permissionSet, owner: owner, groupJID: jid)
                    projection = try repository.projection(owner: owner, groupJID: jid)
                }
                hasLoadedMembers = true
                currentBlocklist = blocklist
                apply(projection)
            } catch is CancellationError {
                return
            } catch {
                DDLogDebug("GroupchatContactInfoViewController refresh: \(error.localizedDescription)")
            }
        }
    }

    internal func applyModerationState(
        members: [GroupMember]?,
        blocklist: [String]?
    ) throws {
        if let members {
            hasLoadedMembers = true
            try repository?.replaceMembers(members, owner: owner, groupJID: jid)
        }
        if let blocklist {
            currentBlocklist = blocklist
        }
        if let projection = try repository?.projection(owner: owner, groupJID: jid) {
            apply(projection)
        }
    }

    internal func presentCanonicalError(_ error: Error) {
        DDLogDebug("GroupchatContactInfoViewController: \(error.localizedDescription)")
        let message: String
        if let partial = error as? GroupModerationPartialFailure {
            message = "Moderation partially completed (\(partial.failedStage.rawValue))"
        } else {
            message = "Internal error".localizeString(id: "message_manager_error_internal", arguments: [])
        }
        view.makeToast(message)
    }

    internal func reportUser() {
        let controller = AbuseReportViewController()
        controller.configureUserReport(
            owner: owner,
            jid: jid,
            reportedUserJid: userJid ?? userId,
            roomJid: jid,
            conversationType: .group
        )
        showModal(controller, parent: self)
    }

    private func startProjectionIfNeeded() {
        guard repository == nil else { return }
        do {
            let repository = GroupRepository(realm: try WRealm.safe())
            self.repository = repository
            projectionObservation = try repository.observeProjection(
                owner: owner,
                groupJID: jid
            ) { [weak self] projection in
                DispatchQueue.main.async { self?.apply(projection) }
            }
        } catch {
            DDLogDebug("GroupchatContactInfoViewController: \(error.localizedDescription)")
        }
    }

    private func configureHeaderButtons() {
        headerView.configureButtons {
            let chat = InfoHeaderButton(frame: CGRect(width: 72, height: 40))
            chat.configure(icon: "bubble", title: "Chat")
            chat.addTarget(self, action: #selector(self.onFirstButtonPressed), for: .touchUpInside)

            let messages = InfoHeaderButton(frame: CGRect(width: 72, height: 40))
            messages.configure(icon: "text.bubble", title: "Messages")
            messages.addTarget(self, action: #selector(self.onSecondButtonPressed), for: .touchUpInside)

            let badge = InfoHeaderButton(frame: CGRect(width: 72, height: 40))
            badge.configure(icon: "person.text.rectangle", title: "Badge")
            badge.addTarget(self, action: #selector(self.onThirdButtonPressed), for: .touchUpInside)

            let moderation = InfoHeaderButton(frame: CGRect(width: 72, height: 40))
            moderation.configure(icon: "person.crop.circle.badge.xmark", title: "Manage", forceStrong: false)
            moderation.addTarget(self, action: #selector(self.onFourthButtonPressed), for: .touchUpInside)
            return [chat, messages, badge, moderation]
        }
    }

    private func apply(_ projection: GroupRepositoryProjection) {
        currentProjection = projection
        let authoritativeMember = projection.state.member(id: userId)
        if let authoritativeMember { currentMember = authoritativeMember }
        let member = authoritativeMember ?? currentMember
        let selfMemberID = projection.selfMemberID
        let capabilities = projection.capabilities

        isMyProfile = selfMemberID == userId
        isIncognitoGroup = projection.state.snapshot.privacy == .incognito
        isKicked = hasLoadedMembers && authoritativeMember == nil
        userJid = member?.jid
        userRole = member?.role ?? .member
        userBadge = member?.badge ?? ""
        userNickname = member?.nickname?.isNotEmpty == true ? member!.nickname! : userId
        userOnline = false
        onlineCount = projection.state.snapshot.presentCount ?? 0

        let normalizedJID = member?.jid.map(GroupStorageKey.bareJID)
        isBlocked = normalizedJID.map { target in
            currentBlocklist.contains { GroupStorageKey.bareJID($0) == target }
        } ?? false

        canChangeBadge = capabilities.changeUserInfo && !isKicked
        canChangeNickname = capabilities.changeUserInfo && !isKicked
        // The server accepts URL metadata only. This screen has no member-card
        // URL upload endpoint, therefore inline and clear actions stay hidden.
        canChangeAvatars = false
        canChangeUserPermissions = capabilities.changePermissions && !isMyProfile && !isKicked
        canBlock = capabilities.blockUsers
            && !isMyProfile
            && member?.role != .owner
            && member?.jid != nil

        datasource = Self.canonicalSections(makeDatasource(member: member))
        configureHeader(member: member)
        configureHeaderButtonVisibility(member: member)
        navigationItem.setRightBarButton(nil, animated: false)
        tableView.reloadData()
    }

    private func makeDatasource(member: GroupMember?) -> [Datasource] {
        var details: [Datasource] = [
            Datasource(.text, title: "Role".localizeString(id: "vcard_role", arguments: []), key: "gcc_role")
        ]
        if let badge = member?.badge?.trimmingCharacters(in: .whitespacesAndNewlines), badge.isNotEmpty {
            details.append(
                Datasource(
                    .text,
                    title: "Badge".localizeString(id: "groupchat_member_badge", arguments: []),
                    subtitle: badge,
                    key: "gcc_badge"
                )
            )
        }
        details.append(Datasource(.status, title: ""))

        var result = [Datasource(.text, title: "", key: "gcc_status", childs: details)]
        if !isMyProfile {
            result.append(
                Datasource(
                    .text,
                    title: "Safety".localizeString(id: "report_safety_section", arguments: []),
                    childs: [
                        Datasource(
                            .button,
                            title: "Report User".localizeString(id: "report_user_action", arguments: []),
                            key: "report_user"
                        )
                    ]
                )
            )
        }
        return result
    }

    private func configureHeader(member: GroupMember?) {
        let subtitle: String
        if isMyProfile {
            subtitle = "This is you".localizeString(id: "this_is_you", arguments: [])
        } else if let lastSeen = member?.lastSeen {
            subtitle = lastSeenText(lastSeen)
        } else {
            subtitle = "Offline".localizeString(id: "account_state_offline", arguments: [])
        }
        headerView.configure(
            avatarUrl: member?.avatar?.url,
            owner: owner,
            jid: jid,
            titleColor: .label,
            title: userNickname,
            subtitle: subtitle,
            thirdLine: nil
        )
    }

    private func configureHeaderButtonVisibility(member: GroupMember?) {
        guard headerView.buttons.count == 4 else { return }
        headerView.buttons[0].isHidden = isMyProfile || (isIncognitoGroup ? member?.allowsPeerToPeer != true : member?.jid == nil)
        // Per-author message search was never implemented by the canonical service.
        headerView.buttons[1].isHidden = true
        headerView.buttons[2].isHidden = !canChangeBadge
        headerView.buttons[3].isHidden = !(canBlock || isBlocked)
    }

    private func lastSeenText(_ date: Date) -> String {
        let now = Date()
        let interval = abs(now.timeIntervalSince(date))
        if interval < 60 {
            return "last seen just now".localizeString(id: "chat_seen_just_now", arguments: [])
        }
        if interval < 60 * 60 {
            let minutes = Int(interval / 60)
            return "last seen \(minutes) minutes ago".localizeString(
                id: "chat_seen_minutes_ago",
                arguments: ["\(minutes)"]
            )
        }
        lastSeenDateFormatter.dateFormat = interval < 24 * 60 * 60
            ? "'last seen at 'HH:mm"
            : "'last seen 'd MMM yyyy"
        return lastSeenDateFormatter.string(from: date)
    }
}
