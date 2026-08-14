import Foundation
import UIKit
import RealmSwift
import DeepDiff
import CocoaLumberjack

enum GroupchatInfoActionExitPolicy {
    static func resolve(
        currentController: UIViewController,
        presentingViewController: UIViewController?,
        exitAction: NavigationExitAction
    ) -> ContactInfoActionExitResolution {
        if exitAction == .dismissModal {
            guard let presentingViewController else {
                return ContactInfoActionExitResolution(action: .ignore, routePresenter: nil)
            }
            return ContactInfoActionExitResolution(
                action: .dismissThenPerform,
                routePresenter: presentingViewController
            )
        }
        return ContactInfoActionExitResolution(
            action: .performImmediately,
            routePresenter: currentController
        )
    }
}

enum GroupchatInfoAccessibilityIdentifiers {
    static let searchButton = ChatSearchAccessibilityIdentifier.groupInfoEntry
}

final class GroupchatInfoViewController: SimpleBaseViewController {
    final class Datasource: DiffAware, Equatable, Hashable {
        enum Kind { case text, info, contact, button, danger, jid }

        let kind: Kind
        let title: String
        var subtitle: String?
        let key: String?
        let icon: String?
        var childs: [Datasource]

        typealias DiffId = String
        var diffId: String { key ?? title }

        init(
            _ kind: Kind,
            title: String,
            subtitle: String? = nil,
            icon: String? = nil,
            key: String? = nil,
            childs: [Datasource] = []
        ) {
            self.kind = kind
            self.title = title
            self.subtitle = subtitle?.isEmpty == true ? nil : subtitle
            self.icon = icon
            self.key = key
            self.childs = childs
        }

        static func == (lhs: Datasource, rhs: Datasource) -> Bool {
            lhs.key == rhs.key && lhs.title == rhs.title && lhs.kind == rhs.kind
                && lhs.subtitle == rhs.subtitle && lhs.childs == rhs.childs
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(key ?? title)
        }

        static func compareContent(_ a: Datasource, _ b: Datasource) -> Bool { a == b }
    }

    struct MemberRow {
        let userId: String
        let isOnline: Bool
    }

    var leftMenuDelegate: LeftMenuSelectRootScreenDelegate?
    var chatStateDelegate: ChangeChatStateProtocol?

    let headerView = InfoScreenHeaderView(frame: .zero)
    let footerView: InfoScreenFooterView = {
        let view = InfoScreenFooterView(frame: .zero)
        view.isGroupChat = true
        return view
    }()
    let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .insetGrouped)
        view.register(XMPPIDInfoScreenYableViewCell.self, forCellReuseIdentifier: XMPPIDInfoScreenYableViewCell.cellName)
        view.register(UITableViewCell.self, forCellReuseIdentifier: "ButtonCell")
        view.register(UITableViewCell.self, forCellReuseIdentifier: "InfoCell")
        view.register(CommonMemberTableCell.self, forCellReuseIdentifier: CommonMemberTableCell.cellName)
        view.register(StatusInfoCell.self, forCellReuseIdentifier: StatusInfoCell.cellName)
        view.register(EditCirclesCell.self, forCellReuseIdentifier: EditCirclesCell.cellName)
        return view
    }()
    let searchButton: UIBarButtonItem = {
        let item = UIBarButtonItem(image: imageLiteral("magnifyingglass"), style: .plain, target: nil, action: nil)
        item.accessibilityIdentifier = GroupchatInfoAccessibilityIdentifiers.searchButton
        item.accessibilityLabel = "Search".localizeString(id: "search", arguments: [])
        return item
    }()
    let showQRCodeButton = UIBarButtonItem(
        image: imageLiteral("qrcode")?.withRenderingMode(.alwaysTemplate),
        style: .plain,
        target: nil,
        action: nil
    )

    var contacts: [MemberRow]?
    var datasource: [Datasource] = []
    var nickname = ""
    var membersCount = 0
    var lastPresentContacts = 0
    var onlineContacts = 0
    var blockedCount = 0
    var invitationsCount = 0
    var isBlocked = false
    var isMuted = false
    var canInvite = false
    var canChangeAvatar = false
    var canChangeStatus = false
    var isIncognitoChat = false
    var canBeChanged = false
    var currentStatus: ResourceStatus = .offline
    var currentVerboseStatus = "Offline".localizeString(id: "unavailable", arguments: [])
    var isTemporaryStatus = false
    var shouldResetNavbar = false
    var circles: [String] = []

    private var repository: GroupRepository?
    private var observation: GroupRepositoryObservation?
    private var refreshTask: Task<Void, Never>?
    var currentProjection: GroupRepositoryProjection?

    override func loadDatasource() {
        super.loadDatasource()
        startProjectionIfNeeded()
        refreshCanonicalState()
    }

    override func configure() {
        super.configure()
        view.addSubview(tableView)
        tableView.fillSuperview()
        tableView.delegate = self
        tableView.dataSource = self
        tableView.tableHeaderView = headerView
        headerView.delegate = self

        searchButton.target = self
        searchButton.action = #selector(onSearchButtonTouchUpInside)
        showQRCodeButton.target = self
        showQRCodeButton.action = #selector(showQRCode)
        navigationItem.setRightBarButtonItems([searchButton], animated: false)

        headerView.configureButtons {
            let write = InfoHeaderButton(frame: CGRect(width: 72, height: 40))
            write.configure(icon: "bubble", title: "Chat")
            write.addTarget(self, action: #selector(self.onWriteButtonTouchUpInside), for: .touchUpInside)

            let invite = InfoHeaderButton(frame: CGRect(width: 72, height: 40))
            invite.configure(icon: "xabber.person.plus", title: "Invite")
            invite.addTarget(self, action: #selector(self.onInviteButtonTouchUpInside), for: .touchUpInside)

            let sound = InfoHeaderButton(frame: CGRect(width: 72, height: 40))
            sound.configure(icon: "bell", title: "Sound", forceStrong: false)
            sound.addTarget(self, action: #selector(self.onNotifyButtonTouchUpInside), for: .touchUpInside)

            let leave = InfoHeaderButton(frame: CGRect(width: 72, height: 40))
            leave.configure(
                icon: "xabber.figure.exit",
                title: "Exit".localizeString(id: "exit", arguments: []),
                forceStrong: false
            )
            leave.addTarget(self, action: #selector(self.onLeaveHeaderButtonTouchUpInside), for: .touchUpInside)
            return [write, invite, sound, leave]
        }
    }

    override func subscribe() {
        super.subscribe()
        startProjectionIfNeeded()
    }

    override func unsubscribe() {
        refreshTask?.cancel()
        refreshTask = nil
        observation?.invalidate()
        observation = nil
        repository = nil
        super.unsubscribe()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        subscribe()
        refreshCanonicalState()
        tableView.fillSuperview()
        headerView.applyHeaderLayout(to: tableView, width: view.bounds.width)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationItem.backButtonDisplayMode = .minimal
        unsubscribe()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        footerView.imagesButton.isSelected = true
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

    deinit {
        refreshTask?.cancel()
        observation?.invalidate()
    }

    private func startProjectionIfNeeded() {
        guard repository == nil else { return }
        do {
            let repository = GroupRepository(realm: try WRealm.safe())
            self.repository = repository
            observation = try repository.observeProjection(owner: owner, groupJID: jid) { [weak self] projection in
                DispatchQueue.main.async { self?.apply(projection) }
            }
        } catch {
            DDLogDebug("GroupchatInfoViewController: \(error.localizedDescription)")
        }
    }

    private func refreshCanonicalState() {
        refreshTask?.cancel()
        guard let account = AccountManager.shared.find(for: owner) else { return }
        refreshTask = Task { @MainActor [weak self, weak account] in
            guard let self, let account else { return }
            do {
                async let snapshotRequest = account.groupchatService.refreshGroup(groupJID: jid)
                async let membersRequest = account.groupchatService.refreshMembers(groupJID: jid)
                async let invitesRequest = account.groupchatService.refreshInvites(groupJID: jid)
                async let blocklistRequest = account.groupchatService.refreshBlocklist(groupJID: jid)
                let (snapshot, members, invites, blocklist) = try await (
                    snapshotRequest,
                    membersRequest,
                    invitesRequest,
                    blocklistRequest
                )
                guard !Task.isCancelled else { return }
                let repository: GroupRepository
                if let existingRepository = self.repository {
                    repository = existingRepository
                } else {
                    repository = GroupRepository(realm: try WRealm.safe())
                    self.repository = repository
                }
                try repository.applySnapshot(snapshot, owner: owner, groupJID: jid)
                try repository.replaceMembers(members, owner: owner, groupJID: jid)
                let projection = try repository.projection(owner: owner, groupJID: jid)
                if let selfMemberID = projection.selfMemberID {
                    let permissions = try await account.groupchatService.getPermissions(
                        groupJID: jid,
                        scope: .direct,
                        targetMemberID: selfMemberID
                    )
                    try repository.replacePermissionSet(permissions, owner: owner, groupJID: jid)
                }
                invitationsCount = invites.count
                blockedCount = blocklist.count
                apply(try repository.projection(owner: owner, groupJID: jid))
            } catch is CancellationError {
                return
            } catch {
                DDLogDebug("GroupchatInfoViewController refresh: \(error.localizedDescription)")
            }
        }
    }

    private func apply(_ projection: GroupRepositoryProjection) {
        currentProjection = projection
        let snapshot = projection.state.snapshot
        let members = projection.state.members
        let capabilities = projection.capabilities
        contacts = members.map { MemberRow(userId: $0.id, isOnline: false) }
        membersCount = snapshot.memberCount ?? members.count
        onlineContacts = snapshot.presentCount ?? 0
        lastPresentContacts = onlineContacts
        canInvite = capabilities.addMembers
        canChangeAvatar = capabilities.changeGroupInfo
        canChangeStatus = capabilities.changeGroupInfo
        canBeChanged = capabilities.changeGroupInfo || capabilities.changeGroupSettings
        isIncognitoChat = snapshot.privacy == .incognito
        nickname = snapshot.info?.name?.isNotEmpty == true ? snapshot.info!.name! : jid
        currentVerboseStatus = snapshot.info?.status?.isNotEmpty == true
            ? snapshot.info!.status!
            : "Offline".localizeString(id: "unavailable", arguments: [])
        currentStatus = projection.state.isActive ? .online : .offline

        loadLocalCircles()
        datasource = makeDatasource(snapshot: snapshot)
        configureHeader(snapshot: snapshot)
        configureNavigation(capabilities: capabilities)
        tableView.reloadData()
    }

    private func makeDatasource(snapshot: GroupSnapshot) -> [Datasource] {
        var result: [Datasource] = [
            Datasource(.text, title: "XMPP ID".localizeString(id: "jid", arguments: []), childs: [
                Datasource(.jid, title: jid, subtitle: jid)
            ]),
            Datasource(.text, title: "About".localizeString(id: "about", arguments: []), childs: [
                Datasource(
                    .info,
                    title: snapshot.info?.description?.isNotEmpty == true
                        ? snapshot.info!.description!
                        : "No description".localizeString(id: "no_description", arguments: []),
                    key: "gc_descr"
                ),
                Datasource(.text, title: "Set status".localizeString(id: "status_editor", arguments: []), key: "gc_set_status")
            ]),
            Datasource(.text, title: "Circles", childs: [
                Datasource(.button, title: "Circles".localizeString(id: "contact_circle", arguments: []), key: "gc_circles")
            ]),
            Datasource(.text, title: "", key: "section_members", childs: [
                Datasource(
                    .button,
                    title: "Members",
                    subtitle: onlineContacts > 0
                        ? "\(membersCount) (\(onlineContacts) online)"
                        : "\(membersCount)",
                    key: "members"
                )
            ])
        ]

        let mediaCounts = localMediaCounts()
        result.append(Datasource(.text, title: "", key: "chat_files", childs: [
            Datasource(.button, title: "Images", subtitle: String(mediaCounts.images), key: "images"),
            Datasource(.button, title: "Videos", subtitle: String(mediaCounts.videos), key: "videos"),
            Datasource(.button, title: "Files", subtitle: String(mediaCounts.files), key: "files"),
            Datasource(.button, title: "Voice", subtitle: String(mediaCounts.voice), key: "voice")
        ]))
        result.append(Datasource(.text, title: "Safety".localizeString(id: "report_safety_section", arguments: []), childs: [
            Datasource(.button, title: "Report Room".localizeString(id: "report_room_action", arguments: []), icon: "exclamationmark.circle", key: "report_room")
        ]))
        return result
    }

    private func configureHeader(snapshot: GroupSnapshot) {
        let subtitle: String
        if membersCount == 0 {
            subtitle = "No members".localizeString(id: "groupchats_no_members", arguments: [])
        } else if membersCount == 1 {
            subtitle = "1 member".localizeString(id: "groupchats_one_member", arguments: [])
        } else {
            subtitle = "\(membersCount) members".localizeString(
                id: "groupchats_some_members",
                arguments: ["\(membersCount)"]
            )
        }
        headerView.configure(
            avatarUrl: snapshot.info?.avatar?.url,
            owner: owner,
            jid: jid,
            titleColor: .label,
            title: nickname,
            subtitle: subtitle,
            thirdLine: nil
        )
    }

    private func configureNavigation(capabilities: GroupCapabilities) {
        if capabilities.changeGroupInfo || capabilities.changeGroupSettings {
            let edit = UIBarButtonItem(
                image: imageLiteral("slider.horizontal.3"),
                style: .plain,
                target: self,
                action: #selector(onEditButtonTouchUpInside)
            )
            navigationItem.setRightBarButtonItems([edit, searchButton], animated: false)
        } else {
            navigationItem.setRightBarButtonItems([searchButton], animated: false)
        }
    }

    private func loadLocalCircles() {
        guard let realm = try? WRealm.safe() else { return }
        circles = realm.object(
            ofType: RosterStorageItem.self,
            forPrimaryKey: RosterStorageItem.genPrimary(jid: jid, owner: owner)
        )?.groups.toArray().sorted() ?? []
    }

    private func localMediaCounts() -> (images: Int, videos: Int, files: Int, voice: Int) {
        guard let realm = try? WRealm.safe() else { return (0, 0, 0, 0) }
        let all = realm.objects(MessageMediaAttachmentStorageItem.self)
            .filter(
                "owner == %@ AND jid == %@ AND conversationType_ == %@",
                owner,
                jid,
                ClientSynchronizationManager.ConversationType.group.rawValue
            )
        return (
            all.filter("kind_ == %@", MessageMediaAttachmentStorageItem.Kind.image.rawValue).count,
            all.filter("kind_ == %@", MessageMediaAttachmentStorageItem.Kind.video.rawValue).count,
            all.filter("kind_ == %@", MessageMediaAttachmentStorageItem.Kind.file.rawValue).count,
            all.filter("kind_ == %@", MessageMediaAttachmentStorageItem.Kind.voice.rawValue).count
        )
    }

    @objc func onInviteButtonTouchUpInside(_ sender: InfoHeaderButton) { onInvite() }
    @objc func onWriteButtonTouchUpInside(_ sender: InfoHeaderButton) { openChat() }
    @objc func onSearchButtonTouchUpInside(_ sender: UIBarButtonItem) { openSearch() }
    @objc func onNotifyButtonTouchUpInside(_ sender: InfoHeaderButton) { onChangeNotifications() }

    func reportRoom() {
        let controller = AbuseReportViewController()
        controller.configureRoomReport(owner: owner, roomJid: jid)
        showModal(controller, parent: self)
    }

}
