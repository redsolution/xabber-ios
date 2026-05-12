//
//  CreateNewEntityViewController.swift
//  xabber
//
//  Created by Игорь Болдин on 28.05.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import MaterialComponents.MDCPalettes
import CocoaLumberjack
import RealmSwift

import RxSwift
import RxCocoa
import RxRealm

class CreateNewEntityViewController: UIViewController {

    struct BotDefinition: Equatable {
        let title: String
        let jid: String
        let description: String
        let avatarAssetName: String
    }

    static let botDefinitions: [BotDefinition] = [
        BotDefinition(
            title: "Call Me Bot",
            jid: "call.me.bot@test.xabber.org",
            description: "Answers calls and mirrors your camera video.",
            avatarAssetName: "create_new_entity_call_me_bot_avatar"
        ),
        BotDefinition(
            title: "Reply Me Bot",
            jid: "reply.me.bot@test.xabber.org",
            description: "Echo bot that sends your messages back.",
            avatarAssetName: "create_new_entity_reply_me_bot_avatar"
        )
    ]

    static func shouldEnsureRoster(for subscription: RosterStorageItem.Subsccribtion?) -> Bool {
        return subscription != .both
    }

    struct Datasource {
        let title: String
        let icon: String
        let key: String
        var subtitle: String
        var jid: String?
        var iconRenderingMode: UIImage.RenderingMode
    }

    struct DatasourceSection {
        let title: String?
        let items: [Datasource]
    }
    
    var datasource: [DatasourceSection] = []
    
    var chatsVc: LastChatsViewController? = nil
    var archivedVc: LastChatsViewController? = nil
    var callsVc: LastCallsViewController? = nil
    var notificationsVc: NotificationsListViewController? = nil
    var notificationsCategoriesVc: NotificationsCategoriesViewController? = nil
    var contactsVc: ContactsViewController? = nil
    
    open var leftMenuSelectRootCategoryDelegate: LeftMenuSelectRootScreenDelegate? = nil
    
    open var filterGroupCreation: Bool? = nil
    private let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .insetGrouped)
        
        view.register(MenuItemTableCell.self, forCellReuseIdentifier: MenuItemTableCell.cellName)
        view.separatorStyle = .singleLine
        
        view.isScrollEnabled = true
        
        return view
    }()

    private var botSelectionInProgress: Bool = false
    
    private static func datasource(
        title: String,
        icon: String,
        key: String,
        subtitle: String = "",
        jid: String? = nil,
        iconRenderingMode: UIImage.RenderingMode = .alwaysTemplate
    ) -> Datasource {
        return Datasource(
            title: title,
            icon: icon,
            key: key,
            subtitle: subtitle,
            jid: jid,
            iconRenderingMode: iconRenderingMode
        )
    }

    private static func botSection() -> DatasourceSection {
        return DatasourceSection(
            title: "Bots",
            items: botDefinitions.map {
                datasource(
                    title: $0.title,
                    icon: $0.avatarAssetName,
                    key: "bot",
                    subtitle: $0.description,
                    jid: $0.jid,
                    iconRenderingMode: .alwaysOriginal
                )
            }
        )
    }

    private static func qrSection() -> DatasourceSection {
        return DatasourceSection(
            title: nil,
            items: [
                datasource(title: "Scan QR code", icon: "qrcode.viewfinder", key: "qr_code")
            ]
        )
    }

    private func loadDatasource() {
        func normalSections(with items: [Datasource], includeBots: Bool) -> [DatasourceSection] {
            var sections = [
                DatasourceSection(title: nil, items: items)
            ]
            if includeBots {
                sections.append(Self.botSection())
            }
            sections.append(Self.qrSection())
            return sections
        }

        if CommonConfigManager.shared.config.locked_conversation_type == "none" {
            if let filterGroupCreation = self.filterGroupCreation {
                if CommonConfigManager.shared.config.support_groupchats, filterGroupCreation {
                    self.datasource = [
                        DatasourceSection(
                            title: nil,
                            items: [
                                Self.datasource(title: "Create group", icon: "person.2", key: "create_group"),
                                Self.datasource(title: "Create incognito group", icon: "xabber.incognito.variant", key: "create_incognito")
                            ]
                        )
                    ]
                } else {
                    self.datasource = normalSections(
                        with: [
                            Self.datasource(title: "Add contact", icon: "person", key: "add_contact"),
                            Self.datasource(title: "Start secret chat", icon: "custom.lock.bubble.left", key: "start_secret_chat")
                        ],
                        includeBots: false
                    )
                }
            } else if CommonConfigManager.shared.config.support_groupchats {
                self.datasource = normalSections(
                    with: [
                        Self.datasource(title: "Add contact", icon: "person", key: "add_contact"),
                        Self.datasource(title: "Create group", icon: "person.2", key: "create_group"),
                        Self.datasource(title: "Create incognito group", icon: "xabber.incognito.variant", key: "create_incognito"),
                        Self.datasource(title: "Start secret chat", icon: "custom.lock.bubble.left", key: "start_secret_chat")
                    ],
                    includeBots: true
                )
            } else {
                self.datasource = normalSections(
                    with: [
                        Self.datasource(title: "Add contact", icon: "person", key: "add_contact"),
                        Self.datasource(title: "Start secret chat", icon: "custom.lock.bubble.left", key: "start_secret_chat")
                    ],
                    includeBots: true
                )
            }
        } else {
            self.datasource = normalSections(
                with: [
                    Self.datasource(title: "Add contact", icon: "person.fill", key: "add_contact")
                ],
                includeBots: self.filterGroupCreation == nil
            )
        }
    }

    private func setBotSelectionInProgress(_ value: Bool) {
        let apply = {
            self.botSelectionInProgress = value
            self.tableView.isUserInteractionEnabled = !value
        }

        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async {
                apply()
            }
        }
    }

    private func conversationType() -> ClientSynchronizationManager.ConversationType {
        return ClientSynchronizationManager.ConversationType(
            rawValue: CommonConfigManager.shared.config.locked_conversation_type
        ) ?? .regular
    }

    private func existingRosterSubscription(owner: String, jid: String) -> RosterStorageItem.Subsccribtion? {
        do {
            let realm = try WRealm.safe()
            return realm
                .object(
                    ofType: RosterStorageItem.self,
                    forPrimaryKey: RosterStorageItem.genPrimary(jid: jid, owner: owner)
                )?
                .subscribtion
        } catch {
            DDLogDebug("CreateNewEntityViewController: \(#function). \(error.localizedDescription)")
        }
        return nil
    }

    private func openBotChat(owner: String, jid: String, conversationType: ClientSynchronizationManager.ConversationType) {
        DispatchQueue.main.async {
            self.setBotSelectionInProgress(false)
            let presentingViewController = self.navigationController?.presentingViewController ?? self.presentationController?.presentingViewController

            let route: (UIViewController) -> Void = { presenter in
                if let delegate = self.leftMenuSelectRootCategoryDelegate {
                    delegate.openChatlistWithChat(owner: owner, jid: jid, conversationType: conversationType, configure: nil)
                } else {
                    let vc = ChatViewController()
                    vc.jid = jid
                    vc.owner = owner
                    vc.conversationType = conversationType

                    showStacked(vc, in: presenter)
                }
            }

            if let presentingViewController = presentingViewController {
                self.dismiss(animated: true) {
                    route(presentingViewController)
                }
            } else {
                route(self)
            }
        }
    }

    private func showBotSelectionError(_ message: String) {
        DispatchQueue.main.async {
            self.setBotSelectionInProgress(false)
            self.view.makeToast(message)
        }
    }

    private func handleBotSelection(_ item: Datasource) {
        guard !botSelectionInProgress,
              let jid = item.jid,
              let bot = Self.botDefinitions.first(where: { $0.jid == jid }) else {
            return
        }

        guard let owner = AccountManager.shared.users.first?.jid,
              let account = AccountManager.shared.find(for: owner) else {
            showBotSelectionError(
                "No connected accounts found.".localizeString(
                    id: "dialog_add_contact__error__text_no_accounts",
                    arguments: []
                )
            )
            return
        }

        let conversationType = self.conversationType()
        setBotSelectionInProgress(true)

        if !Self.shouldEnsureRoster(for: existingRosterSubscription(owner: owner, jid: jid)) {
            account.action { user, _ in
                user.lastChats.initChat(jid: jid, conversationType: conversationType)
                self.openBotChat(owner: owner, jid: jid, conversationType: conversationType)
            }
            return
        }

        account.action { user, stream in
            user.presences.subscribe(stream, jid: jid)
            user.presences.subscribed(stream, jid: jid)
            user.roster.setContact(
                stream,
                jid: jid,
                nickname: bot.title,
                shouldAddSystemMessage: true
            ) { _, error, result in
                if result {
                    user.lastChats.initChat(jid: jid, conversationType: conversationType)
                    self.openBotChat(owner: owner, jid: jid, conversationType: conversationType)
                } else {
                    DDLogDebug("CreateNewEntityViewController: failed to add bot \(jid) to roster: \(error ?? "unknown")")
                    self.showBotSelectionError("Unexpected error".localizeString(id: "unexpected_error", arguments: []))
                }
            }
        }
    }
        
    public func configure() {
        
        self.navigationItem.largeTitleDisplayMode = .never
        navigationController?.navigationBar.prefersLargeTitles = false
        navigationItem.backButtonDisplayMode = .minimal
        
        view.addSubview(tableView)
        tableView.fillSuperview()
        tableView.delegate = self
        tableView.dataSource = self
        
        loadDatasource()
    }
        
    override func viewDidLoad() {
        super.viewDidLoad()
        observer()
        configure()
    }
    
    private func observer() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(languageChanged),
                                               name: .newLanguageSelected,
                                               object: nil)
    }

    @objc
    func languageChanged() {
        print("Notification received")
    }

    private func removeNotificationObserer() {
        NotificationCenter.default.removeObserver(self)
    }

    deinit {
        removeNotificationObserer()
    }
    
    internal var randTitle: String = RandomTitleManager.shared.title()
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.title = CommonConfigManager.shared.config.motivating ? self.randTitle : "New chat"
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
    }
}


extension CreateNewEntityViewController: UITableViewDataSource {
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return datasource.count
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return datasource[section].items.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: MenuItemTableCell.cellName, for: indexPath) as? MenuItemTableCell else {
            fatalError()
        }
        let item = datasource[indexPath.section].items[indexPath.row]
        cell.configure(
            title: item.title,
            subtitle: item.subtitle,
            badge: "",
            icon: item.icon,
            isImportant: false,
            iconRenderingMode: item.iconRenderingMode
        )
        cell.backgroundColor = .white
        cell.layer.cornerRadius = 0
        cell.layer.masksToBounds = false
        cell.separatorInset = UIEdgeInsets(top: 0, left: 72, bottom: 0, right: 16)
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .none
        cell.accessibilityLabel = item.title
        cell.accessibilityValue = item.subtitle.isEmpty ? nil : item.subtitle

        return cell
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return datasource[section].title
    }
}

extension CreateNewEntityViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 52
    }
    
    private func show(controller vc: UIViewController) {
        if UIDevice.current.userInterfaceIdiom == .pad {
            self.splitViewController?.setViewController(vc, for: .supplementary)
//            self.splitViewController?.show(.supplementary)
            self.splitViewController?.hide(.primary)
        } else {
            UIView.performWithoutAnimation {
                self.splitViewController?.setViewController(vc, for: .supplementary)
                self.splitViewController?.show(.supplementary)
                self.splitViewController?.hide(.primary)
            }
        }
        
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let item = self.datasource[indexPath.section].items[indexPath.row]
        let key = item.key
        switch key {
            case "add_contact":
                let vc = AddNewContactViewController()
                vc.leftMenuSelectRootCategoryDelegate = leftMenuSelectRootCategoryDelegate
                self.navigationController?.pushViewController(vc, animated: true)
            case "create_group":
                let vc = CreateNewGroupViewController()
                vc.createIncognitoGroup = false
                vc.leftMenuSelectRootCategoryDelegate = leftMenuSelectRootCategoryDelegate
                self.navigationController?.pushViewController(vc, animated: true)
            case "create_incognito":
                let vc = CreateNewGroupViewController()
                vc.createIncognitoGroup = true
                vc.leftMenuSelectRootCategoryDelegate = leftMenuSelectRootCategoryDelegate
                self.navigationController?.pushViewController(vc, animated: true)
            case "start_secret_chat":
                let vc = NewSecretChatViewController()
                vc.leftMenuSelectRootCategoryDelegate = leftMenuSelectRootCategoryDelegate
                self.navigationController?.pushViewController(vc, animated: true)
            case "qr_code":
                let vc = QRCodeScannerViewController()
                vc.leftMenuSelectRootCategoryDelegate = leftMenuSelectRootCategoryDelegate
                self.navigationController?.pushViewController(vc, animated: true)
            case "bot":
                handleBotSelection(item)
            default:
                break
        }
    }
}
