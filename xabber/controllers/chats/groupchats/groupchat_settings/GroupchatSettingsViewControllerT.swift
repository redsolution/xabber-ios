//
//  GroupchatSettingsViewControllerT.swift
//  xabber
//
//  Created by Игорь Болдин on 27.10.2025.
//  Copyright © 2025 Igor Boldin. All rights reserved.
//

import Foundation
import AVFoundation
import UIKit
import RxSwift
import RxCocoa
import RxRelay
import MaterialComponents.MDCPalettes
import CocoaLumberjack

struct GroupchatSettingsCanonicalModel: Equatable, Sendable {
    let name: String
    let description: String
    let status: String
    let avatarURL: String?
    let membership: GroupMembership?
    let enabledDefaultPermissionCount: Int
    let defaultPermissionCount: Int
    let administratorCount: Int
    let outgoingInviteCount: Int
    let blockedCount: Int
    let isActive: Bool
    let canEditInfo: Bool
    let canEditSettings: Bool
    let canEditDefaultPermissions: Bool
    let canManageAdmins: Bool
    let canInvite: Bool
    let canBlock: Bool
    let canDelete: Bool

    var shouldRefreshPermissions: Bool { isActive }

    static func authoritativeInfoPatch(_ info: GroupInfo) -> GroupPatch {
        GroupPatch(
            info: .value(
                GroupInfoPatch(
                    name: .value(info.name),
                    description: .value(info.description),
                    avatar: .value(info.avatar),
                    status: .value(info.status)
                )
            )
        )
    }

    init(
        projection: GroupRepositoryProjection,
        outgoingInviteCount: Int,
        blockedCount: Int
    ) {
        let snapshot = projection.state.snapshot
        let defaults = projection.state.permissionSets.first { $0.scope == .defaults }
        let selfRole = projection.selfMemberID.flatMap { projection.state.member(id: $0)?.role }
        let capabilities = projection.capabilities
        let active = projection.state.isActive

        name = snapshot.info?.name ?? ""
        description = snapshot.info?.description ?? ""
        status = snapshot.info?.status ?? ""
        avatarURL = snapshot.info?.avatar?.url
        membership = snapshot.settings?.membership
        enabledDefaultPermissionCount = defaults?.permissions.filter(\.status).count ?? 0
        defaultPermissionCount = defaults?.permissions.count ?? 0
        administratorCount = projection.state.members.filter {
            $0.role == .owner || $0.role == .admin
        }.count
        self.outgoingInviteCount = outgoingInviteCount
        self.blockedCount = blockedCount
        isActive = active
        canEditInfo = active && capabilities.changeGroupInfo
        canEditSettings = active && capabilities.changeGroupSettings
        canEditDefaultPermissions = active && capabilities.changeDefaultPermissions
        canManageAdmins = active && capabilities.createAdmins
        canInvite = active && capabilities.addMembers
        canBlock = active && capabilities.blockUsers
        canDelete = active && selfRole == .owner
    }
}

class GroupchatSettingsViewControllerT: SimpleBaseViewController {
    
    class HeaderView: UIView {
        
        internal let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.spacing = 4
            stack.alignment = .center
            stack.distribution = .fill
            
            return stack
        }()
        
        internal let imageButton: RoundedAvatarButton = {
            let button = RoundedAvatarButton(frame: CGRect(square: 128),
                                             avatarMaskResourceName: AccountMasksManager.shared.mask128pt)
            button.layer.masksToBounds = true
            button.contentVerticalAlignment = .center
            button.contentHorizontalAlignment = .center
            button.imageView?.contentMode = .scaleAspectFill
            button.contentMode = .scaleAspectFill
            button.backgroundColor = .secondarySystemBackground
            
            return button
        }()
        
        internal let actionButton: UIButton = {
            var conf = UIButton.Configuration.plain()
            conf.title = "Set new photo"
            conf.baseForegroundColor = .tintColor
            conf.buttonSize = .medium
            
            let button = UIButton(configuration: conf, primaryAction: nil)
            
            return button
        }()
        
        internal func activateConstraints() {
            self.stack.fillSuperview()
            NSLayoutConstraint.activate([
                imageButton.heightAnchor.constraint(equalToConstant: 128),
                imageButton.widthAnchor.constraint(equalToConstant: 128),
                actionButton.heightAnchor.constraint(equalToConstant: 44),
                actionButton.widthAnchor.constraint(equalTo: stack.widthAnchor)
            ])
        }
        
        internal func setupSubviews() {
            self.addSubview(stack)
            self.stack.addArrangedSubview(self.imageButton)
            self.stack.addArrangedSubview(self.actionButton)
            self.activateConstraints()
            self.imageButton.addTarget(self, action: #selector(onAvatarButtonTouchUpInside), for: .touchUpInside)
            self.actionButton.addTarget(self, action: #selector(onAvatarButtonTouchUpInside), for: .touchUpInside)
        }
        
        open var avatarButtonTouchUpCallback: (() -> Void)? = nil
        
        @objc
        internal func onAvatarButtonTouchUpInside(_ sender: AnyObject) {
            self.avatarButtonTouchUpCallback?()
        }
        
        internal var currentUrl: String? = nil
        
        internal func configure(avatarUrl: String?, username: String, jid: String, owner: String) {
            if currentUrl != avatarUrl {
                DefaultAvatarManager.shared.getAvatar(url: avatarUrl, jid: jid, owner: owner, size: 128) { image in
                    if let image = image {
                        self.imageButton.setImage(image, for: .normal)
                        self.currentUrl = avatarUrl
                    } else {
                        self.imageButton.setImage(UIImageView.getDefaultAvatar(for: username, owner: owner, size: 128), for: .normal)
                    }
                }
            }
            
        }
        
        override init(frame: CGRect) {
            super.init(frame: frame)
            self.setupSubviews()
        }
        
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            self.setupSubviews()
        }
    }
    
    class SettingsTableHeaderCell: UITableViewCell {
        static let cellName: String = "SettingsTableHeaderCell"
        
        internal let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.spacing = 4
            stack.alignment = .center
            stack.distribution = .fill
            
            return stack
        }()
        
        internal let imageButton: RoundedAvatarButton = {
            let button = RoundedAvatarButton(frame: CGRect(square: 128),
                                             avatarMaskResourceName: AccountMasksManager.shared.mask128pt)
            button.layer.masksToBounds = true
            button.contentVerticalAlignment = .center
            button.contentHorizontalAlignment = .center
            button.imageView?.contentMode = .scaleAspectFit
            button.contentMode = .scaleAspectFit
            button.backgroundColor = .secondarySystemBackground
            
            return button
        }()
        
        internal let actionButton: UIButton = {
            var conf = UIButton.Configuration.plain()
            conf.title = "Set new photo"
            conf.baseForegroundColor = .tintColor
            conf.buttonSize = .medium
            
            let button = UIButton(configuration: conf, primaryAction: nil)
            
            return button
        }()
        
        internal func activateConstraints() {
            self.stack.fillSuperview()
            NSLayoutConstraint.activate([
                imageButton.heightAnchor.constraint(equalToConstant: 128),
                imageButton.widthAnchor.constraint(equalToConstant: 128),
                actionButton.heightAnchor.constraint(equalToConstant: 44),
                actionButton.widthAnchor.constraint(equalTo: stack.widthAnchor)
            ])
        }
        
        internal func setupSubviews() {
            self.contentView.addSubview(stack)
            self.stack.addArrangedSubview(self.imageButton)
            self.stack.addArrangedSubview(self.actionButton)
            self.activateConstraints()
        }
        
        internal var currentUrl: String? = nil
        
        internal func configure(avatarUrl: String?, username: String, jid: String, owner: String) {
            if currentUrl != avatarUrl {
                DefaultAvatarManager.shared.getAvatar(url: avatarUrl, jid: jid, owner: owner, size: 128) { image in
                    if let image = image {
                        self.imageButton.setImage(image, for: .normal)
                        self.currentUrl = avatarUrl
                    } else {
                        self.imageButton.setImage(UIImageView.getDefaultAvatar(for: username, owner: owner, size: 128), for: .normal)
                    }
                }
            }
            
        }
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            setupSubviews()
        }
        
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setupSubviews()
        }
    }
    
    class SettingsTextFieldCell: UITableViewCell {
        static let cellName: String = "SettingsTextFieldCell"
        
        var isChanged: Bool = false
        var key: String = ""
        
        var stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.alignment = .leading
            stack.spacing = 8
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 4, bottom: 4, left: 20, right: 16)
            
            return stack
        }()
        
        var field: UITextField = {
            let field = UITextField()
            
            field.autocorrectionType = .default
            field.clearButtonMode = .never
            field.autocapitalizationType = .sentences
            field.spellCheckingType = .yes
            field.keyboardType = .default
            field.returnKeyType = .done
            
            return field
        }()
        
        var callback: ((String, String?) -> Void)? = nil
        
        private func activateConstraints() {
            field.heightAnchor.constraint(equalToConstant: 30).isActive = true
            field.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 0.95).isActive = true
        }
        
        func configure(_ title: String, value: String?, key: String) {
            field.text = value
            field.placeholder = title
            field.clearButtonMode = .always
            field.addTarget(self, action: #selector(fieldDidChange), for: .editingChanged)
            self.key = key
        }
        
        func configureField(_ block: ((UITextField) -> Void)) {
            block(field)
        }
        
        private func setupSubviews() {
            contentView.addSubview(stack)
            selectionStyle = .none
            stack.fillSuperview()
            stack.addArrangedSubview(field)
            backgroundColor = .systemBackground
            activateConstraints()
        }
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            setupSubviews()
        }
        
        required init?(coder aDecoder: NSCoder) {
            super.init(coder: aDecoder)
            setupSubviews()
        }
        
        override func awakeFromNib() {
            super.awakeFromNib()
        }
        
        override func setSelected(_ selected: Bool, animated: Bool) {
            super.setSelected(selected, animated: animated)
        }
        
        @objc
        internal func fieldDidChange(_ sender: UITextField) {
            callback?(self.key, sender.text)
        }
    }
    
    class SettingsMultilineTextFieldCell: UITableViewCell {
        static let cellName: String = "SettingsMultilineTextFieldCell"
    }
    
    class SettingsItemCell: UITableViewCell {
        static let cellName: String = "SettingsItemCell"
        
        let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.distribution = .fill
            stack.alignment = .center
            stack.layoutMargins = UIEdgeInsets(top: 2, bottom: 0, left: 16, right: 16)
            stack.isLayoutMarginsRelativeArrangement = true
            
            return stack
        }()
        
        let titleLabel: UILabel = {
            let label = UILabel()
            
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            
            return label
        }()
        
        let badgeView: UIButton = {
            let view = UIButton()

            return view
        }()
        
        func configure(title: String, badge: String, icon: String) {
            self.titleLabel.text = title
            self.imageView?.image = (UIImage(named: icon) ?? UIImage(systemName: icon))?.withRenderingMode(.alwaysTemplate)
            self.badgeView.setTitle(badge, for: .normal)
            self.badgeView.isHidden = false/*badge == "0" ? true : false*/
            var configuration = UIButton.Configuration.filled()
            configuration.title = badge
            configuration.baseBackgroundColor = .clear
            configuration.baseForegroundColor = .secondaryLabel
            configuration.buttonSize = .mini
            configuration.cornerStyle = .capsule
            self.badgeView.configuration = configuration
            self.badgeView.updateConfiguration()
            self.badgeView.setNeedsLayout()
            self.badgeView.layoutIfNeeded()
        }
        
        func setupSubviews() {
            self.contentView.addSubview(stack)
            self.stack.fillSuperviewWithOffset(top: 0, bottom: 4, left: 56, right: 4)
            self.stack.addArrangedSubview(self.titleLabel)
            self.stack.addArrangedSubview(self.badgeView)
            self.accessoryType = .disclosureIndicator
        }
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            self.setupSubviews()
        }
        
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            self.setupSubviews()
        }
        
        public final func updateTimer(day: Int?, hour: Int?, mins: Int?) {
            var customString = ""
            if let value = day, value > 0 {
                customString += "\(value)d "
            } else if let value = hour, value > 0 {
                customString += "\(value)h "
            } else if let value = mins, value > 0 {
                customString += "\(value)m"
            }
            
            var conf = UIButton.Configuration.plain()
            conf.attributedTitle = AttributedString(NSAttributedString(string: customString, attributes: [
                .font: UIFont.systemFont(ofSize: 13)
            ]))
            self.badgeView.configuration = conf
            self.badgeView.updateConfiguration()
            self.badgeView.sizeToFit()
            self.stack.layoutSubviews()
        }
        
    }
    
    class SettingsDeleteButtonCell: UITableViewCell {
        static let cellName: String = "SettingsDeleteButtonCell"
        
        internal let titleLabel: UILabel = {
            let label = UILabel(frame: .zero)
            
            label.textColor = .systemRed
            label.textAlignment = .center
            
            return label
        }()
        
        internal func activateConstraints() {
            titleLabel.fillSuperview()
        }
        
        internal func setupSubviews() {
            self.contentView.addSubview(titleLabel)
            activateConstraints()
        }
        
        internal func configure(title: String) {
            self.titleLabel.text = title
        }
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            setupSubviews()
        }
        
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setupSubviews()
        }
    }
    
    class Datasource {
        enum Kind {
            case header
            case textField
            case multilineTextField
            case item
            case delete
        }
        
        var kind: Kind
        var title: String
        var subtitle: String?
        var icon: String?
        var key: String
        var value: String
        
        init(kind: Kind, title: String, subtitle: String? = nil, icon: String? = nil, key: String, value: String) {
            self.kind = kind
            self.title = title
            self.subtitle = subtitle
            self.icon = icon
            self.key = key
            self.value = value
        }
        
    }
    
    internal var datasource: [[Datasource]] = []

    private var repository: GroupRepository?
    private var projectionObservation: GroupRepositoryObservation?
    private var projection: GroupRepositoryProjection?
    private var canonicalModel: GroupchatSettingsCanonicalModel?
    private var outgoingInviteTargets: [String] = []
    private var blockedTargets: [String] = []
    private var refreshTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var deleteTask: Task<Void, Never>?

    private func canonicalRepository() throws -> GroupRepository {
        if let repository {
            return repository
        }
        let repository = GroupRepository(realm: try WRealm.safe())
        self.repository = repository
        return repository
    }
    
    var leftMenuDelegate: LeftMenuSelectRootScreenDelegate? = nil
    
    internal let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .insetGrouped)
        
        view.register(SettingsTableHeaderCell.self, forCellReuseIdentifier: SettingsTableHeaderCell.cellName)
        view.register(SettingsDeleteButtonCell.self, forCellReuseIdentifier: SettingsDeleteButtonCell.cellName)
        view.register(SettingsItemCell.self, forCellReuseIdentifier: SettingsItemCell.cellName)
        view.register(SettingsTextFieldCell.self, forCellReuseIdentifier: SettingsTextFieldCell.cellName)
        view.register(SettingsMultilineTextFieldCell.self, forCellReuseIdentifier: SettingsMultilineTextFieldCell.cellName)
        
        return view
    }()
    
    internal let saveBarButton: UIBarButtonItem = {
        let button = UIBarButtonItem(systemItem: .save)
        
        return button
    }()
    
    internal var cancelBarButton: UIBarButtonItem = {
        let button = UIBarButtonItem(systemItem: .cancel)
        
        return button
    }()
    
    internal let headerView: HeaderView = {
        let view = HeaderView(frame: CGRect(x: 0, y: -44, width: .zero, height: 176))
        
        return view
    }()
    
    override func loadDatasource() {
        super.loadDatasource()
        do {
            let repository = try canonicalRepository()
            apply(
                try repository.projection(owner: owner, groupJID: jid),
                force: true
            )
        } catch {
            DDLogDebug("GroupchatSettingsViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    override func setupSubviews() {
        super.setupSubviews()
        self.view.addSubview(self.tableView)
        self.tableView.fillSuperviewWithOffset(top: -24, bottom: 0, left: 0, right: 0)
        self.tableView.tableHeaderView = self.headerView
        NSLayoutConstraint.activate([
            self.headerView.widthAnchor.constraint(equalTo: self.tableView.widthAnchor),
            self.headerView.heightAnchor.constraint(equalToConstant: 176)
        ])
    }
    
    override func configure() {
        super.configure()
        self.tableView.dataSource = self
        self.tableView.delegate = self
        self.cancelBarButton.action = #selector(onCancelButtonTouchUpInside)
        self.cancelBarButton.target = self
        self.saveBarButton.action = #selector(onSaveButtonTouchUpInside)
        self.saveBarButton.target = self
    }

    override func onAppear() {
        super.onAppear()
        refreshAuthoritativeState()
    }
    
    internal var changesObserver: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    
    var titleObserver: BehaviorRelay<String?> = BehaviorRelay(value: nil)
    var descriptionObserver: BehaviorRelay<String?> = BehaviorRelay(value: nil)
    var statusObserver: BehaviorRelay<String?> = BehaviorRelay(value: nil)
    
    var storedTitle: String? = nil
    var storedDescription: String? = nil
    var storedStatus: String? = nil

    override func subscribe() {
        super.subscribe()
        self.titleObserver
            .asObservable()
            .debounce(.milliseconds(100), scheduler: MainScheduler.asyncInstance)
            .subscribe { [weak self] value in
                guard let self else { return }
                if value != self.storedTitle {
                    self.changesObserver.accept(true)
                } else {
                    self.updateChangesState()
                }
            }
            .disposed(by: self.bag)
        
        
        self.descriptionObserver
            .asObservable()
            .debounce(.milliseconds(100), scheduler: MainScheduler.asyncInstance)
            .subscribe { [weak self] value in
                guard let self else { return }
                if value != self.storedDescription {
                    self.changesObserver.accept(true)
                } else {
                    self.updateChangesState()
                }
            }
            .disposed(by: self.bag)

        self.statusObserver
            .asObservable()
            .debounce(.milliseconds(100), scheduler: MainScheduler.asyncInstance)
            .subscribe { [weak self] value in
                guard let self else { return }
                if value != self.storedStatus {
                    self.changesObserver.accept(true)
                } else {
                    self.updateChangesState()
                }
            }
            .disposed(by: self.bag)
        
        self.changesObserver
            .asObservable()
            .distinctUntilChanged()
            .debounce(.milliseconds(100), scheduler: MainScheduler.asyncInstance)
            .subscribe { [weak self] value in
                guard let self else { return }
                if value {
                    self.navigationItem.setLeftBarButton(self.cancelBarButton, animated: true)
                    self.navigationItem.setRightBarButton(self.saveBarButton, animated: true)
                } else {
                    self.navigationItem.setLeftBarButton(self.navigationItem.backBarButtonItem, animated: true)
                    self.navigationItem.setRightBarButton(nil, animated: true)
                }
            }
            .disposed(by: self.bag)

        do {
            let repository = try canonicalRepository()
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
            DDLogDebug("GroupchatSettingsViewController: \(#function). \(error.localizedDescription)")
        }
    }

    override func unsubscribe() {
        refreshTask?.cancel()
        refreshTask = nil
        saveTask?.cancel()
        saveTask = nil
        deleteTask?.cancel()
        deleteTask = nil
        projectionObservation?.invalidate()
        projectionObservation = nil
        repository = nil
        super.unsubscribe()
    }

    deinit {
        refreshTask?.cancel()
        saveTask?.cancel()
        deleteTask?.cancel()
        projectionObservation?.invalidate()
    }

    @objc
    internal func onCancelButtonTouchUpInside(_ sender: AnyObject) {
        if let projection {
            apply(projection, force: true)
        } else {
            titleObserver.accept(storedTitle)
            descriptionObserver.accept(storedDescription)
            statusObserver.accept(storedStatus)
            changesObserver.accept(false)
        }
    }

    @objc
    internal func onSaveButtonTouchUpInside(_ sender: AnyObject) {
        guard saveTask == nil,
              canonicalModel?.canEditInfo == true,
              let account = AccountManager.shared.find(for: owner) else {
            return
        }
        datasource.first?.enumerated().compactMap {
            tableView.cellForRow(at: IndexPath(row: $0.offset, section: 0)) as? SettingsTextFieldCell
        }.forEach { $0.field.resignFirstResponder() }

        let requestedInfo = GroupInfo(
            name: titleObserver.value ?? "",
            description: descriptionObserver.value ?? "",
            status: statusObserver.value ?? ""
        )
        tableView.isUserInteractionEnabled = false
        saveBarButton.isEnabled = false
        saveTask = Task { @MainActor [weak self, weak account] in
            guard let self, let account else { return }
            defer {
                self.tableView.isUserInteractionEnabled = true
                self.saveBarButton.isEnabled = true
                self.saveTask = nil
            }
            do {
                let authoritative = try await account.groupchatService.updateInfo(
                    groupJID: self.jid,
                    info: requestedInfo
                )
                let repository = try self.canonicalRepository()
                let patch = GroupchatSettingsCanonicalModel.authoritativeInfoPatch(authoritative)
                try repository.applyPatch(patch, owner: self.owner, groupJID: self.jid)
                let projection = try repository.projection(owner: self.owner, groupJID: self.jid)
                self.apply(projection, force: true)
                ToastPresenter().presentSuccess(message: "Info updated")
            } catch is CancellationError {
                return
            } catch {
                ToastPresenter().presentError(message: "Error: \(error.localizedDescription)")
            }
        }
    }

    private func apply(_ projection: GroupRepositoryProjection, force: Bool) {
        self.projection = projection
        let model = GroupchatSettingsCanonicalModel(
            projection: projection,
            outgoingInviteCount: outgoingInviteTargets.count,
            blockedCount: blockedTargets.count
        )
        canonicalModel = model

        let shouldReload = force || !changesObserver.value
        if shouldReload {
            storedTitle = model.name
            storedDescription = model.description
            storedStatus = model.status
            titleObserver.accept(model.name)
            descriptionObserver.accept(model.description)
            statusObserver.accept(model.status)
            changesObserver.accept(false)
            datasource = makeDatasource(model)
        }

        headerView.configure(
            avatarUrl: model.avatarURL,
            username: model.name.isEmpty ? jid : model.name,
            jid: jid,
            owner: owner
        )
        headerView.avatarButtonTouchUpCallback = model.canEditInfo ? { [weak self] in
            self?.onChangeAvatar()
        } : nil
        headerView.imageButton.isEnabled = model.canEditInfo
        headerView.actionButton.isEnabled = model.canEditInfo
        headerView.actionButton.isHidden = !model.canEditInfo
        if shouldReload {
            tableView.reloadData()
        }
    }

    private func makeDatasource(_ model: GroupchatSettingsCanonicalModel) -> [[Datasource]] {
        let editing = changesObserver.value
        var sections: [[Datasource]] = [[
            Datasource(
                kind: .textField,
                title: "Name",
                key: "title",
                value: editing ? (titleObserver.value ?? "") : model.name
            ),
            Datasource(
                kind: .multilineTextField,
                title: "Description",
                key: "description",
                value: editing ? (descriptionObserver.value ?? "") : model.description
            ),
            Datasource(
                kind: .textField,
                title: "Status".localizeString(id: "groupchat_status", arguments: []),
                key: "status",
                value: editing ? (statusObserver.value ?? "") : model.status
            )
        ]]

        if model.canEditSettings {
            sections.append([
                Datasource(
                    kind: .item,
                    title: "Group type",
                    icon: "custom.person.2.square.fill",
                    key: "membership",
                    value: membershipTitle(model.membership)
                )
            ])
        }

        var administration: [Datasource] = []
        if model.canEditDefaultPermissions {
            administration.append(
                Datasource(
                    kind: .item,
                    title: "Permissions",
                    icon: "custom.key.square.fill",
                    key: "permissions",
                    value: "\(model.enabledDefaultPermissionCount) / \(model.defaultPermissionCount)"
                )
            )
        }
        if model.canManageAdmins {
            administration.append(
                Datasource(
                    kind: .item,
                    title: "Administrators",
                    icon: "star.square.fill",
                    key: "admins",
                    value: "\(model.administratorCount)"
                )
            )
        }
        if !administration.isEmpty {
            sections.append(administration)
        }

        var membershipActions: [Datasource] = []
        if model.canInvite {
            membershipActions.append(
                Datasource(
                    kind: .item,
                    title: "Invitations",
                    icon: "xabber.invite.square.fill",
                    key: "invites",
                    value: "\(model.outgoingInviteCount)"
                )
            )
        }
        if model.canBlock {
            membershipActions.append(
                Datasource(
                    kind: .item,
                    title: "Blocked",
                    icon: "custom.nosign.square.fill",
                    key: "block",
                    value: "\(model.blockedCount)"
                )
            )
        }
        if !membershipActions.isEmpty {
            sections.append(membershipActions)
        }

        if model.canDelete {
            sections.append([
                Datasource(
                    kind: .delete,
                    title: "Delete group",
                    key: "delete",
                    value: ""
                )
            ])
        }
        return sections
    }

    private func membershipTitle(_ membership: GroupMembership?) -> String {
        switch membership {
        case .open:
            return "Open".localizeString(id: "groupchat_membership_type_open", arguments: [])
        case .privateGroup:
            return "Private".localizeString(id: "groupchat_membership_type_private", arguments: [])
        case nil:
            return ""
        }
    }

    private func refreshAuthoritativeState() {
        guard refreshTask == nil,
              canonicalModel?.shouldRefreshPermissions == true,
              let account = AccountManager.shared.find(for: owner) else {
            return
        }
        refreshTask = Task { @MainActor [weak self, weak account] in
            guard let self, let account else { return }
            defer { self.refreshTask = nil }
            do {
                async let snapshotRequest = account.groupchatService.refreshGroup(groupJID: self.jid)
                async let membersRequest = account.groupchatService.refreshMembers(groupJID: self.jid)
                async let invitesRequest = account.groupchatService.refreshInvites(groupJID: self.jid)
                async let blocklistRequest = account.groupchatService.refreshBlocklist(groupJID: self.jid)
                let (snapshot, members, invites, blocklist) = try await (
                    snapshotRequest,
                    membersRequest,
                    invitesRequest,
                    blocklistRequest
                )
                let repository = try self.canonicalRepository()
                try repository.applySnapshot(snapshot, owner: self.owner, groupJID: self.jid)
                try repository.replaceMembers(members, owner: self.owner, groupJID: self.jid)
                _ = try repository.replaceOutgoingInvites(
                    owner: self.owner,
                    groupJID: self.jid,
                    targets: invites
                )
                self.outgoingInviteTargets = invites
                self.blockedTargets = blocklist

                let activeProjection = try repository.projection(owner: self.owner, groupJID: self.jid)
                self.apply(activeProjection, force: false)
                guard activeProjection.state.isActive else { return }

                async let defaultsRequest = account.groupchatService.getPermissions(
                    groupJID: self.jid,
                    scope: GroupPermissionScope.defaults
                )
                async let newbiesRequest = account.groupchatService.getPermissions(
                    groupJID: self.jid,
                    scope: GroupPermissionScope.newbies
                )
                let (defaults, newbies) = try await (defaultsRequest, newbiesRequest)
                try repository.replacePermissionSet(defaults, owner: self.owner, groupJID: self.jid)
                try repository.replacePermissionSet(newbies, owner: self.owner, groupJID: self.jid)
                if let selfMemberID = activeProjection.selfMemberID {
                    let direct = try await account.groupchatService.getPermissions(
                        groupJID: self.jid,
                        scope: GroupPermissionScope.direct,
                        targetMemberID: selfMemberID
                    )
                    try repository.replacePermissionSet(direct, owner: self.owner, groupJID: self.jid)
                }
                self.apply(
                    try repository.projection(owner: self.owner, groupJID: self.jid),
                    force: false
                )
            } catch is CancellationError {
                return
            } catch {
                DDLogDebug("GroupchatSettingsViewController: \(#function). \(error.localizedDescription)")
            }
        }
    }

    private func confirmDelete() {
        guard canonicalModel?.canDelete == true else { return }
        let alert = UIAlertController(
            title: "Delete group",
            message: "Deleting this group removes it for every member.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            self?.deleteGroup()
        })
        present(alert, animated: true)
    }

    private func deleteGroup() {
        guard deleteTask == nil,
              canonicalModel?.canDelete == true,
              let account = AccountManager.shared.find(for: owner) else {
            return
        }
        deleteTask = Task { @MainActor [weak self, weak account] in
            guard let self, let account else { return }
            defer { self.deleteTask = nil }
            do {
                try await account.groupchatService.delete(groupJID: self.jid)
                let repository = try self.canonicalRepository()
                try repository.recordDeletion(owner: self.owner, groupJID: self.jid)
                self.navigationController?.popViewController(animated: true)
            } catch is CancellationError {
                return
            } catch {
                ToastPresenter().presentError(message: "Error: \(error.localizedDescription)")
            }
        }
    }

}

extension GroupchatSettingsViewControllerT: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        let item = self.datasource[indexPath.section][indexPath.row]
        switch item.kind {
            case .header:
                return 176
            default:
                return 52
        }
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let item = self.datasource[indexPath.section][indexPath.row]
        switch item.key {
            case "membership":
                let vc = GroupchatSettingsMembershipViewController()
                
                vc.jid = self.jid
                vc.owner = self.owner
                
                self.navigationController?.pushViewController(vc, animated: true)
            case "permissions":
                let vc = GroupchatSettingsPermissionsViewController()
                
                vc.jid = self.jid
                vc.owner = self.owner
                
                self.navigationController?.pushViewController(vc, animated: true)
            case "members":
                let vc = GroupchatMembersListViewController()
                
                vc.permissionScope = "member"
                vc.jid = self.jid
                vc.owner = self.owner
                
                self.navigationController?.pushViewController(vc, animated: true)
            case "admins":
                let vc = GroupchatMembersListViewController()
                
                vc.permissionScope = "owner,admin"
                vc.jid = self.jid
                vc.owner = self.owner
                
                self.navigationController?.pushViewController(vc, animated: true)
            case "restrited":
                let vc = GroupchatMembersListViewController()
                
                vc.permissionScope = "restrited"
                vc.jid = self.jid
                vc.owner = self.owner
                
                self.navigationController?.pushViewController(vc, animated: true)
            case "invites":
                let vc = GroupchatInviteListViewController()
                
                vc.jid = self.jid
                vc.owner = self.owner
                vc.leftMenuDelegate = self.leftMenuDelegate
                
                self.navigationController?.pushViewController(vc, animated: true)
                
            case "block":
                let vc = GroupchatBlockedViewController()
                
                vc.jid = self.jid
                vc.owner = self.owner
                vc.leftMenuDelegate = self.leftMenuDelegate
                
                self.navigationController?.pushViewController(vc, animated: true)
            case "delete":
                confirmDelete()
            default:
                break
        }
    }
}

extension GroupchatSettingsViewControllerT: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        return self.datasource.count
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.datasource[section].count
    }
    
    public func onTextFieldDidChange(key: String, value: String?) {
        switch key {
            case "title":
                self.titleObserver.accept(value)
            case "description":
                self.descriptionObserver.accept(value)
            case "status":
                self.statusObserver.accept(value)
            default:
                break
        }
        updateChangesState()
    }

    private func updateChangesState() {
        changesObserver.accept(
            titleObserver.value != storedTitle
                || descriptionObserver.value != storedDescription
                || statusObserver.value != storedStatus
        )
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = self.datasource[indexPath.section][indexPath.row]
        switch item.kind {
            case .header:
                guard let cell = tableView.dequeueReusableCell(withIdentifier: SettingsTableHeaderCell.cellName, for: indexPath) as? SettingsTableHeaderCell else {
                    fatalError()
                }
                
                cell.configure(avatarUrl: item.icon, username: item.title, jid: self.jid, owner: self.owner)
                cell.selectionStyle = .none
                
                return cell
            case .textField:
                guard let cell = tableView.dequeueReusableCell(withIdentifier: SettingsTextFieldCell.cellName, for: indexPath) as? SettingsTextFieldCell else {
                    fatalError()
                }
                
                cell.configure(item.title, value: item.value, key: item.key)
                cell.field.isEnabled = canonicalModel?.canEditInfo == true
                cell.callback = canonicalModel?.canEditInfo == true ? self.onTextFieldDidChange : nil
                cell.selectionStyle = .none
                
                return cell
            case .multilineTextField:
                guard let cell = tableView.dequeueReusableCell(withIdentifier: SettingsTextFieldCell.cellName, for: indexPath) as? SettingsTextFieldCell else {
                    fatalError()
                }
                
                cell.configure(item.title, value: item.value, key: item.key)
                cell.field.isEnabled = canonicalModel?.canEditInfo == true
                cell.callback = canonicalModel?.canEditInfo == true ? self.onTextFieldDidChange : nil
                cell.selectionStyle = .none
                
                return cell
            case .item:
                guard let cell = tableView.dequeueReusableCell(withIdentifier: SettingsItemCell.cellName, for: indexPath) as? SettingsItemCell else {
                    fatalError()
                }
                
                cell.configure(title: item.title, badge: item.value, icon: item.icon ?? "settings")
                cell.selectionStyle = .none
                
                return cell
            case .delete:
                guard let cell = tableView.dequeueReusableCell(withIdentifier: SettingsDeleteButtonCell.cellName, for: indexPath) as? SettingsDeleteButtonCell else {
                    fatalError()
                }
                
                cell.configure(title: item.title)
                
                return cell
        }
    }
    
    
}

extension GroupchatSettingsViewControllerT {
    func onChangeAvatar() {
        let items = [
            ActionSheetPresenter.Item(destructive: false, title: "Use emoji".localizeString(id: "account_emoji_profile_image_button", arguments: []), value: "emoji"),
            ActionSheetPresenter.Item(destructive: false, title: "Open gallery".localizeString(id: "account_open_gallery", arguments: []), value: "gallery"),
            ActionSheetPresenter.Item(destructive: false, title: "Open camera".localizeString(id: "account_open_camera", arguments: []), value: "camera")
        ]
        ActionSheetPresenter().present(in: self,
                                       title: nil,
                                       message: nil,
                                       cancel: "Cancel".localizeString(id: "cancel", arguments: []),
                                       values: items,
                                       animated: true) { (value) in
                                        switch value {
                                        case "camera": self.onOpenCamera()
                                        case "gallery": self.onOpenGallery()
                                        case "emoji": self.onOpenEmojiPicker()
                                        default: break
                                        }
        }
    }
    
    
    internal func askPermision(_ callback: @escaping ((Bool) -> Void)) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            callback(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                callback(granted)
            }
        case .denied, .restricted:
            callback(false)
            return
        @unknown default:
            callback(false)
        }
    }
    
    internal func openCamera() {
        askPermision { (result) in
            DispatchQueue.main.async {
                if result && UIImagePickerController.isSourceTypeAvailable(.camera) {
                    let cameraPickerVC = UIImagePickerController()
                    cameraPickerVC.delegate = self
                    cameraPickerVC.sourceType = .camera
                    cameraPickerVC.allowsEditing = true
                    self.present(cameraPickerVC, animated: true, completion: nil)
                } else {
                    ErrorMessagePresenter()
                        .present(in: self,
                                 message: "To choose group picture from camera, you should grant permission first".localizeString(id: "account_camera_permission", arguments: []),
                                 animated: true,
                                 completion: nil)
                }
            }
        }
    }
    
    internal func openGallery() {
        if UIImagePickerController.isSourceTypeAvailable(.photoLibrary) {
            let galleryPickerVC = UIImagePickerController()
            galleryPickerVC.delegate = self
            galleryPickerVC.sourceType = .photoLibrary
            galleryPickerVC.allowsEditing = true
            self.present(galleryPickerVC, animated: true, completion: nil)
        }
    }
    
    internal final func openAvatarPicker() {
        let vc = AvatarPickerViewController()
        vc.delegate = self
        vc.palette = nil
        vc.lastSettedEmoji = nil
        showModal(vc, parent: self)
    }
    
    internal final func onOpenEmojiPicker() {
        openAvatarPicker()
    }
    
    func onOpenCamera() {
        openCamera()
    }
    
    func onOpenGallery() {
        openGallery()
    }
    
    func onUpdateAvatar(_ image: UIImage?) {
        guard canonicalModel?.canEditInfo == true,
              let account = AccountManager.shared.find(for: owner),
              let image else {
            return
        }
        self.beforeSettingAvatar()
        account.action { [weak self] user, _ in
            guard let self else { return }
            user.avatarUploader.setGroupAvatar(groupchat: self.jid, image: image, successCallback: {
                self.afterSettingAvatar(image: image)
                user.cloudStorage.getStats()
            }, failureCallback: { _, _ in
                self.afterAvatarUploadFailure()
                DispatchQueue.main.async {
                    let errorMessage = "Unable to send file: out of Cloud Storage"//item.messageError
                    let itemsWithQuota = [
                        ActionSheetPresenter.Item(destructive: false, title: "Manage Cloud Storage", value: "quota")
                    ]
                    ActionSheetPresenter().present(
                        in: self,
                        title: "Avatar upload error",
                        message: errorMessage,
                        cancel: "Cancel",
                        values: itemsWithQuota,
                        animated: true) { value in
                            switch value {
                                case "quota":
                                    let vc = CloudStorageViewController()
                                    vc.configure(jid: self.owner)
                                    self.navigationController?.pushViewController(vc, animated: true)
                                default:
                                    break
                            }
                        }
                }
                DDLogDebug("AccountInfoVC, InfoScreenButtonDelegate: \(#function). Fail to set avatar.")
            }, queuedCallback: {
                self.afterSettingAvatar(image: image)
            })
        }
    }
    
    func beforeSettingAvatar() {
        DispatchQueue.main.async {
            self.headerView.imageButton.showLoading()
        }
    }
    
    func afterSettingAvatar(image: UIImage) {
        DispatchQueue.main.async {
            self.headerView.imageButton.hideLoading()
            self.headerView.imageButton.setImage(
                image.resize(targetSize: CGSize(square: 128)),
                for: .normal
            )
        }
    }

    func afterAvatarUploadFailure() {
        DispatchQueue.main.async {
            self.headerView.imageButton.hideLoading()
            guard let model = self.canonicalModel else { return }
            self.headerView.configure(
                avatarUrl: model.avatarURL,
                username: model.name.isEmpty ? self.jid : model.name,
                jid: self.jid,
                owner: self.owner
            )
        }
    }
}

extension GroupchatSettingsViewControllerT: AvatarPickerViewControllerDelegate {
    func onReceiveAvatar(image: UIImage, emoji: String?, currentPalette: MDCPalette?) {
        onUpdateAvatar(image)
    }
}

extension GroupchatSettingsViewControllerT: UIImagePickerControllerDelegate & UINavigationControllerDelegate {
    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
        let maxSize: CGFloat = 164
        guard let newImage = info[UIImagePickerController.InfoKey.editedImage] as? UIImage ?? info[UIImagePickerController.InfoKey.originalImage] as? UIImage else {
            DispatchQueue.main.async {
                self.view.makeToast("Internal error".localizeString(id: "message_manager_error_internal", arguments: []))
            }
            return
        }
        var image = newImage
        if picker.sourceType == .camera {
            UIImageWriteToSavedPhotosAlbum(image, self, nil, nil)
        }
        image = image.fixOrientation()
        picker.dismiss(animated: true) {
            self.onUpdateAvatar(image)
        }
    }
}
