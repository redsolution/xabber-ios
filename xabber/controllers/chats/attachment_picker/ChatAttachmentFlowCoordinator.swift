import RealmSwift
import UIKit

struct ChatAttachmentFlowContext {
    let owner: String
    let jid: String
    let conversationType: ClientSynchronizationManager.ConversationType
    let forwardedMessageIds: [String]
    let composerTintColor: UIColor

    init(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        forwardedMessageIds: [String],
        composerTintColor: UIColor = .systemBlue
    ) {
        self.owner = owner
        self.jid = jid
        self.conversationType = conversationType
        self.forwardedMessageIds = forwardedMessageIds
        self.composerTintColor = composerTintColor
    }
}

protocol ChatAttachmentFlowCoordinating: AnyObject {
    func start()
    func switchSource(to source: ChatAttachmentSource)
    func dismiss(animated: Bool)
}

protocol ChatAttachmentFlowCoordinatorDelegate: AnyObject {
    func chatAttachmentFlowCoordinatorWillSend(_ coordinator: ChatAttachmentFlowCoordinator)
    func chatAttachmentFlowCoordinatorDidSend(_ coordinator: ChatAttachmentFlowCoordinator)
    func chatAttachmentFlowCoordinatorDidDismiss(_ coordinator: ChatAttachmentFlowCoordinator)
    func chatAttachmentFlowCoordinator(
        _ coordinator: ChatAttachmentFlowCoordinator,
        didRequestPremiumFor owner: String
    )
    func chatAttachmentFlowCoordinator(
        _ coordinator: ChatAttachmentFlowCoordinator,
        didFailWith error: ChatAttachmentFlowError
    )
}

extension ChatAttachmentFlowCoordinatorDelegate {
    func chatAttachmentFlowCoordinatorWillSend(_ coordinator: ChatAttachmentFlowCoordinator) {}
}

protocol ChatAttachmentSourceControlling: AnyObject {
    var source: ChatAttachmentSource { get }
    var viewController: UIViewController { get }
    var onSelectionCountChanged: ((Int) -> Void)? { get set }
}

protocol ChatAttachmentSourceControllerFactory {
    func makeController(
        for source: ChatAttachmentSource,
        context: ChatAttachmentFlowContext
    ) -> ChatAttachmentSourceControlling
}

protocol ChatAttachmentCloudStorageQuotaAlertPresenting: AnyObject {
    func presentQuotaExceededAlert(
        from presenter: UIViewController,
        owner: String,
        openCloudStorage: @escaping () -> Void
    )
}

final class UIKitChatAttachmentCloudStorageQuotaAlertPresenter: ChatAttachmentCloudStorageQuotaAlertPresenting {
    func presentQuotaExceededAlert(
        from presenter: UIViewController,
        owner: String,
        openCloudStorage: @escaping () -> Void
    ) {
        let alert = UIAlertController(
            title: ChatAttachmentLocalization.string(.cloudStorageQuotaExceededTitle),
            message: ChatAttachmentLocalization.string(.cloudStorageQuotaExceededMessage),
            preferredStyle: .alert
        )
        alert.addAction(
            UIAlertAction(
                title: ChatAttachmentLocalization.string(.actionCancel),
                style: .cancel
            )
        )
        alert.addAction(
            UIAlertAction(
                title: ChatAttachmentLocalization.string(.cloudStorageQuotaExceededOpenAction),
                style: .default
            ) { _ in
                openCloudStorage()
            }
        )
        presenter.present(alert, animated: true)
    }
}

final class ChatAttachmentFlowCoordinator: NSObject, ChatAttachmentFlowCoordinating {
    typealias PresentationHandler = (
        UIViewController,
        UIViewController,
        Bool,
        (() -> Void)?
    ) -> Void
    typealias DismissalHandler = (
        UIViewController,
        Bool,
        (() -> Void)?
    ) -> Void
    typealias EndEditingHandler = (
        ChatAttachmentPickerViewController,
        UIViewController
    ) -> Void
    typealias CloudStoragePresentationHandler = (
        UIViewController,
        String
    ) -> Void

    weak var delegate: ChatAttachmentFlowCoordinatorDelegate?

    private weak var presentingViewController: UIViewController?
    private let context: ChatAttachmentFlowContext
    private let sourceControllerFactory: ChatAttachmentSourceControllerFactory
    private let presentationHandler: PresentationHandler
    private let dismissalHandler: DismissalHandler
    private let endEditingHandler: EndEditingHandler
    private let sendCoordinator: ChatAttachmentSendCoordinating
    private let mediaPreparationCoordinator: ChatAttachmentMediaPreparing
    private let quotaRefresher: ChatAttachmentQuotaRefreshing
    private let quotaAlertPresenter: ChatAttachmentCloudStorageQuotaAlertPresenting
    private let cloudStoragePresentationHandler: CloudStoragePresentationHandler

    private(set) var pickerViewController: ChatAttachmentPickerViewController?
    private(set) var pickerNavigationController: UINavigationController?
    var sheetViewController: ChatAttachmentPickerViewController? {
        pickerViewController
    }
    private(set) var selectedItemCount: Int = 0

    init(
        presentingViewController: UIViewController,
        context: ChatAttachmentFlowContext,
        sourceControllerFactory: ChatAttachmentSourceControllerFactory = DefaultChatAttachmentSourceControllerFactory(),
        sendCoordinator: ChatAttachmentSendCoordinating = ChatAttachmentSendPipeline(),
        mediaPreparationCoordinator: ChatAttachmentMediaPreparing = ChatAttachmentMediaPreparationCoordinator(),
        quotaRefresher: ChatAttachmentQuotaRefreshing = CloudStorageQuotaRefreshCoordinatorAdapter(),
        quotaAlertPresenter: ChatAttachmentCloudStorageQuotaAlertPresenting = UIKitChatAttachmentCloudStorageQuotaAlertPresenter(),
        presentationHandler: @escaping PresentationHandler = { presenter, sheet, animated, completion in
            presenter.present(sheet, animated: animated, completion: completion)
        },
        dismissalHandler: @escaping DismissalHandler = { controller, animated, completion in
            guard controller.presentingViewController != nil else {
                completion?()
                return
            }

            controller.dismiss(animated: animated, completion: completion)
        },
        endEditingHandler: @escaping EndEditingHandler = { picker, presentedController in
            picker.previewViewController?.view.endEditing(true)
            picker.view.endEditing(true)
            presentedController.view.endEditing(true)
        },
        cloudStoragePresentationHandler: @escaping CloudStoragePresentationHandler = { sourceController, owner in
            let cloudStorageViewController = CloudStorageViewController()
            cloudStorageViewController.configure(jid: owner)
            if let navigationController = sourceController as? UINavigationController {
                navigationController.pushViewController(cloudStorageViewController, animated: true)
            } else if let navigationController = sourceController.navigationController {
                navigationController.pushViewController(cloudStorageViewController, animated: true)
            } else {
                showModal(cloudStorageViewController, parent: sourceController)
            }
        }
    ) {
        self.presentingViewController = presentingViewController
        self.context = context
        self.sourceControllerFactory = sourceControllerFactory
        self.sendCoordinator = sendCoordinator
        self.mediaPreparationCoordinator = mediaPreparationCoordinator
        self.quotaRefresher = quotaRefresher
        self.quotaAlertPresenter = quotaAlertPresenter
        self.presentationHandler = presentationHandler
        self.dismissalHandler = dismissalHandler
        self.endEditingHandler = endEditingHandler
        self.cloudStoragePresentationHandler = cloudStoragePresentationHandler
        super.init()
    }

    func start() {
        NSLog(
            "ATTACHMENT_TAP event=coordinator_start presenter=%@ existing_picker=%@",
            (presentingViewController != nil).description,
            (pickerViewController != nil).description
        )
        guard let presenter = presentingViewController else {
            NSLog("ATTACHMENT_TAP event=presentation_rejected reason=missing_presenter")
            delegate?.chatAttachmentFlowCoordinator(self, didFailWith: .missingPresenter)
            return
        }

        guard pickerViewController == nil else {
            NSLog("ATTACHMENT_TAP event=presentation_rejected reason=picker_already_exists")
            return
        }

        guard presenter.presentedViewController == nil else {
            NSLog(
                "ATTACHMENT_TAP event=presentation_rejected reason=presenter_busy controller=%@",
                String(describing: presenter.presentedViewController)
            )
            delegate?.chatAttachmentFlowCoordinator(self, didFailWith: .presentationFailed)
            return
        }

        let loadStartedAt = CFAbsoluteTimeGetCurrent()
        let picker = ChatAttachmentPickerViewController(
            context: context,
            sourceControllerFactory: sourceControllerFactory,
            mediaPreparationCoordinator: mediaPreparationCoordinator
        )
        picker.delegate = self
        picker.navigationItem.largeTitleDisplayMode = .never
        picker.loadViewIfNeeded()
        NSLog(
            "ATTACHMENT_TAP event=picker_view_loaded elapsed_ms=%.1f",
            (CFAbsoluteTimeGetCurrent() - loadStartedAt) * 1000
        )
        let navigationController = UINavigationController(rootViewController: picker)
        navigationController.setNavigationBarHidden(false, animated: false)
        navigationController.navigationBar.prefersLargeTitles = false
        ChatAttachmentPickerPageSheetStyle.apply(to: navigationController)
        navigationController.presentationController?.delegate = self
        pickerViewController = picker
        pickerNavigationController = navigationController
        selectedItemCount = picker.selectedItemCount

        refreshCloudStorageStatsOnOpen()
        NSLog("ATTACHMENT_TAP event=presentation_begin")
        presentationHandler(presenter, navigationController, true) { [weak self, weak navigationController] in
            NSLog("ATTACHMENT_TAP event=presentation_completion")
            guard let self else {
                return
            }

            navigationController?.presentationController?.delegate = self
        }
    }

    func switchSource(to source: ChatAttachmentSource) {
        pickerViewController?.switchSource(to: source)
    }

    func dismiss(animated: Bool) {
        guard let picker = pickerViewController else {
            return
        }

        let completeDismissal: () -> Void = { [weak self] in
            guard let self else {
                return
            }

            self.finishDismissal(notifyDelegate: true)
        }

        let presentedController = pickerNavigationController ?? picker
        dismissalHandler(presentedController, animated, completeDismissal)
    }

    private func finishDismissal(notifyDelegate: Bool) {
        guard let picker = pickerViewController else {
            return
        }

        picker.delegate = nil
        picker.releaseSourceControllers()
        pickerViewController = nil
        pickerNavigationController = nil
        selectedItemCount = 0

        if notifyDelegate {
            delegate?.chatAttachmentFlowCoordinatorDidDismiss(self)
        }
    }

    private func finishSend() {
        guard let picker = pickerViewController else {
            delegate?.chatAttachmentFlowCoordinatorDidSend(self)
            return
        }

        let presentedController = pickerNavigationController ?? picker
        picker.delegate = nil
        endEditingHandler(picker, presentedController)

        dismissalHandler(presentedController, true) { [weak self] in
            guard let self else {
                return
            }

            self.finishDismissal(notifyDelegate: false)
            self.delegate?.chatAttachmentFlowCoordinatorDidSend(self)
        }
    }

    private func refreshCloudStorageStatsOnOpen() {
        quotaRefresher.refreshQuota(
            owner: context.owner,
            reason: .screenOpen,
            force: true
        ) { _ in }
    }

    private func presentCloudStorageQuotaExceededAlert(owner: String) {
        let presenter = pickerNavigationController ?? pickerViewController ?? presentingViewController
        guard let presenter else {
            delegate?.chatAttachmentFlowCoordinator(self, didFailWith: .sendBlocked(.accountUnavailable))
            return
        }

        quotaAlertPresenter.presentQuotaExceededAlert(
            from: presenter,
            owner: owner
        ) { [weak self, weak presenter] in
            guard let self, let presenter else {
                return
            }

            self.cloudStoragePresentationHandler(presenter, owner)
        }
    }
}

extension ChatAttachmentFlowCoordinator: ChatAttachmentPickerViewControllerDelegate {
    func chatAttachmentSheetViewControllerDidRequestDismiss(_ sheet: ChatAttachmentPickerViewController) {
        dismiss(animated: true)
    }

    func chatAttachmentSheetViewControllerDidDismiss(_ sheet: ChatAttachmentPickerViewController) {
        finishDismissal(notifyDelegate: true)
    }

    func chatAttachmentSheetViewControllerDidSend(_ sheet: ChatAttachmentPickerViewController) {
        finishSend()
    }

    func chatAttachmentSheetViewController(
        _ sheet: ChatAttachmentPickerViewController,
        didRequestSend drafts: [AttachmentDraft],
        captionState: ChatAttachmentCaptionState
    ) {
        delegate?.chatAttachmentFlowCoordinatorWillSend(self)
        sendCoordinator.send(
            drafts: drafts,
            captionState: captionState,
            context: context
        ) { [weak self] result in
            let complete = {
                guard let self else {
                    return
                }

                switch result {
                case .sent:
                    self.finishSend()
                case .premiumRequired(let owner):
                    self.delegate?.chatAttachmentFlowCoordinator(self, didRequestPremiumFor: owner)
                case .cloudStorageQuotaExceeded(let owner):
                    self.presentCloudStorageQuotaExceededAlert(owner: owner)
                case .blocked(let reason):
                    if let picker = self.pickerViewController {
                        picker.applySendBlockedReason(reason)
                    } else {
                        self.delegate?.chatAttachmentFlowCoordinator(self, didFailWith: .sendBlocked(reason))
                    }
                }
            }

            if Thread.isMainThread {
                complete()
            } else {
                DispatchQueue.main.async(execute: complete)
            }
        }
    }

    func chatAttachmentSheetViewController(
        _ sheet: ChatAttachmentPickerViewController,
        didRequestPremiumFor owner: String
    ) {
        delegate?.chatAttachmentFlowCoordinator(self, didRequestPremiumFor: owner)
    }

    func chatAttachmentSheetViewController(
        _ sheet: ChatAttachmentPickerViewController,
        didFailWith error: ChatAttachmentFlowError
    ) {
        finishDismissal(notifyDelegate: false)
        delegate?.chatAttachmentFlowCoordinator(self, didFailWith: error)
    }

    func chatAttachmentSheetViewController(
        _ sheet: ChatAttachmentPickerViewController,
        didUpdateSelectionCount count: Int
    ) {
        selectedItemCount = count
    }
}

extension ChatAttachmentFlowCoordinator: UIAdaptivePresentationControllerDelegate {
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        finishDismissal(notifyDelegate: true)
    }
}

final class DefaultChatAttachmentSourceControllerFactory: ChatAttachmentSourceControllerFactory {
    func makeController(
        for source: ChatAttachmentSource,
        context: ChatAttachmentFlowContext
    ) -> ChatAttachmentSourceControlling {
        switch source {
        case .gallery:
            return ChatAttachmentGallerySourceViewController()
        case .file:
            return ChatAttachmentFileSourceViewController(
                owner: context.owner,
                fileDraftBuilder: ChatAttachmentFileDraftBuilder(
                    maximumFileSize: ChatAttachmentFileUploadLimitProvider.maxUploadFileSize(owner: context.owner)
                )
            )
        case .geolocation:
            return ChatAttachmentGeolocationSourceViewController()
        case .contact:
            return ChatAttachmentContactSourceViewController(owner: context.owner)
        }
    }
}

final class ChatAttachmentPlaceholderSourceViewController: UIViewController, ChatAttachmentSourceControlling {
    let source: ChatAttachmentSource
    var onSelectionCountChanged: ((Int) -> Void)?

    var viewController: UIViewController {
        self
    }

    init(source: ChatAttachmentSource) {
        self.source = source
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let rootView = UIView()
        rootView.backgroundColor = .clear
        view = rootView
    }
}

struct ChatAttachmentContactRosterRecord: Equatable {
    let owner: String
    let jid: String
    let entity: MessageContactEntityKind
    let displayTitle: String
    let nickname: String?
    let given: String?
    let family: String?
    let avatarURL: String?
    let isHidden: Bool
    let removed: Bool
    let isContact: Bool
    let subscription: RosterStorageItem.Subsccribtion
    let isContactEntity: Bool
}

struct ChatAttachmentContactListItem: Equatable {
    let owner: String
    let jid: String
    let entity: MessageContactEntityKind
    let displayTitle: String
    let nickname: String?
    let given: String?
    let family: String?
    let avatarURL: String?
    let avatarMetadata: [String: String]

    init(
        owner: String,
        jid: String,
        entity: MessageContactEntityKind = .contact,
        displayTitle: String,
        nickname: String?,
        given: String?,
        family: String?,
        avatarURL: String?,
        avatarMetadata: [String: String]
    ) {
        self.owner = owner
        self.jid = jid
        self.entity = entity
        self.displayTitle = displayTitle
        self.nickname = nickname
        self.given = given
        self.family = family
        self.avatarURL = avatarURL
        self.avatarMetadata = avatarMetadata
    }

    func makeDraft() -> AttachmentDraft {
        let title = ChatAttachmentContactText.nonEmpty(displayTitle) ?? jid
        let contact = AttachmentPreparedContact(
            jid: jid,
            entity: entity,
            nickname: ChatAttachmentContactText.nonEmpty(nickname),
            given: ChatAttachmentContactText.nonEmpty(given),
            family: ChatAttachmentContactText.nonEmpty(family),
            displayTitle: title,
            avatarURL: ChatAttachmentContactText.nonEmpty(avatarURL),
            avatarMetadata: avatarMetadata.filter { ChatAttachmentContactText.nonEmpty($0.value) != nil }
        )
        return AttachmentDraft(
            id: "contact:\(entity.rawValue):\(owner)|\(jid)",
            source: .contact,
            mediaKind: .contact,
            thumbnailState: .none,
            filename: title,
            byteSize: 0,
            duration: nil,
            dimensions: nil,
            preparationState: .preparedContact(contact)
        )
    }
}

protocol ChatAttachmentContactSourceDataProviding: AnyObject {
    func loadItems(owner: String, searchQuery: String) -> [ChatAttachmentContactListItem]
}

final class ChatAttachmentContactSourceDataSource: ChatAttachmentContactSourceDataProviding {
    func loadItems(owner: String, searchQuery: String) -> [ChatAttachmentContactListItem] {
        do {
            let realm = try WRealm.safe()
            let records = realm
                .objects(RosterStorageItem.self)
                .filter("owner == %@", owner)
                .map { rosterItem -> ChatAttachmentContactRosterRecord in
                    let vCardItem = realm.object(ofType: vCardStorageItem.self, forPrimaryKey: rosterItem.jid)
                    let vCardNickname = ChatAttachmentContactText.nonEmpty(vCardItem?.nickname)
                    let rosterNickname = ChatAttachmentContactText.nickname(
                        fromDisplayTitle: rosterItem.displayName,
                        jid: rosterItem.jid
                    )
                    let primaryResource = rosterItem.getPrimaryResource()
                    let groupItem = realm.object(
                        ofType: GroupChatStorageItem.self,
                        forPrimaryKey: GroupChatStorageItem.genPrimary(jid: rosterItem.jid, owner: owner)
                    )
                    let entity = Self.entity(primaryResource: primaryResource, groupItem: groupItem)
                    let displayTitle = entity == .contact
                        ? rosterItem.displayName
                        : (ChatAttachmentContactText.nonEmpty(groupItem?.name) ?? rosterItem.displayName)
                    return ChatAttachmentContactRosterRecord(
                        owner: rosterItem.owner,
                        jid: rosterItem.jid,
                        entity: entity,
                        displayTitle: displayTitle,
                        nickname: vCardNickname ?? rosterNickname,
                        given: ChatAttachmentContactText.nonEmpty(vCardItem?.given),
                        family: ChatAttachmentContactText.nonEmpty(vCardItem?.family),
                        avatarURL: ChatAttachmentContactText.nonEmpty(rosterItem.avatarUrl),
                        isHidden: rosterItem.isHidden,
                        removed: rosterItem.removed,
                        isContact: rosterItem.isContact,
                        subscription: rosterItem.subscribtion,
                        isContactEntity: primaryResource?.entity == .contact || primaryResource == nil
                    )
                }
            return Self.items(
                from: Array(records),
                owner: owner,
                searchQuery: searchQuery
            )
        } catch {
            return []
        }
    }

    private static func entity(
        primaryResource: ResourceStorageItem?,
        groupItem: GroupChatStorageItem?
    ) -> MessageContactEntityKind {
        if let groupItem {
            guard groupItem.isDeleted == false,
                  groupItem.peerToPeer == false else {
                return .contact
            }
            return groupItem.privacy == .incognito ? .incognito : .groupchat
        }
        switch primaryResource?.entity {
        case .groupchat:
            return .groupchat
        case .incognitoChat:
            return .incognito
        default:
            return .contact
        }
    }

    static func items(
        from records: [ChatAttachmentContactRosterRecord],
        owner: String,
        searchQuery: String
    ) -> [ChatAttachmentContactListItem] {
        let items = records.compactMap { record -> ChatAttachmentContactListItem? in
            guard record.owner == owner,
                  record.removed == false,
                  record.isHidden == false,
                  let jid = ChatAttachmentContactText.nonEmpty(record.jid),
                  jid != owner else {
                return nil
            }
            switch record.entity {
            case .contact:
                guard record.isContact,
                      record.isContactEntity,
                      record.subscription == .both else {
                    return nil
                }
            case .groupchat, .incognito:
                break
            }

            let nickname = ChatAttachmentContactText.nonEmpty(record.nickname)
            let given = ChatAttachmentContactText.nonEmpty(record.given)
            let family = ChatAttachmentContactText.nonEmpty(record.family)
            let displayTitle = ChatAttachmentContactText.displayTitle(
                explicitTitle: record.displayTitle,
                nickname: nickname,
                given: given,
                family: family,
                jid: jid
            )
            let avatarURL = ChatAttachmentContactText.nonEmpty(record.avatarURL)
            var avatarMetadata: [String: String] = [:]
            if let avatarURL {
                avatarMetadata["avatar_url"] = avatarURL
            }

            return ChatAttachmentContactListItem(
                owner: record.owner,
                jid: jid,
                entity: record.entity,
                displayTitle: displayTitle,
                nickname: nickname,
                given: given,
                family: family,
                avatarURL: avatarURL,
                avatarMetadata: avatarMetadata
            )
        }
        .sorted { left, right in
            let titleOrder = left.displayTitle.localizedCaseInsensitiveCompare(right.displayTitle)
            if titleOrder == .orderedSame {
                return left.jid.localizedCaseInsensitiveCompare(right.jid) == .orderedAscending
            }
            return titleOrder == .orderedAscending
        }

        return filteredItems(items, searchQuery: searchQuery)
    }

    static func filteredItems(
        _ items: [ChatAttachmentContactListItem],
        searchQuery: String
    ) -> [ChatAttachmentContactListItem] {
        guard let query = ChatAttachmentContactText.nonEmpty(searchQuery)?.lowercased() else {
            return items
        }

        return items.filter { item in
            item.displayTitle.lowercased().contains(query)
                || item.jid.lowercased().contains(query)
        }
    }
}

final class ChatAttachmentContactSourceViewController: UIViewController,
    ChatAttachmentSourceControlling,
    ChatAttachmentDraftSelectionProviding,
    ChatAttachmentDraftSelectionMutating,
    ChatAttachmentDraftSelectionSyncing,
    UISearchBarDelegate,
    UITableViewDataSource,
    UITableViewDelegate {
    let source: ChatAttachmentSource = .contact
    var onSelectionCountChanged: ((Int) -> Void)?
    var onSelectedAttachmentDraftsChanged: (([AttachmentDraft]) -> Void)?

    let searchBar = UISearchBar(frame: .zero)
    let tableView = UITableView(frame: .zero, style: .plain)

    private let owner: String
    private let dataSource: ChatAttachmentContactSourceDataProviding
    private var items: [ChatAttachmentContactListItem] = []
    private var selectedDrafts: [AttachmentDraft] = []

    var viewController: UIViewController {
        self
    }

    var selectedAttachmentDrafts: [AttachmentDraft] {
        selectedDrafts
    }

    init(
        owner: String,
        dataSource: ChatAttachmentContactSourceDataProviding = ChatAttachmentContactSourceDataSource()
    ) {
        self.owner = owner
        self.dataSource = dataSource
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let rootView = UIView()
        rootView.backgroundColor = .systemBackground

        searchBar.translatesAutoresizingMaskIntoConstraints = false
        searchBar.accessibilityIdentifier = "chatAttachmentContact.searchBar"
        searchBar.placeholder = ChatAttachmentLocalization.string(.sourceContactTitle)
        searchBar.searchBarStyle = .minimal
        searchBar.delegate = self

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.accessibilityIdentifier = "chatAttachmentContact.tableView"
        tableView.keyboardDismissMode = .onDrag
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(
            ChatAttachmentContactSourceCell.self,
            forCellReuseIdentifier: ChatAttachmentContactSourceCell.reuseIdentifier
        )

        rootView.addSubview(searchBar)
        rootView.addSubview(tableView)

        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: rootView.safeAreaLayoutGuide.topAnchor, constant: 8),
            searchBar.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 8),
            searchBar.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -8),

            tableView.topAnchor.constraint(equalTo: searchBar.bottomAnchor, constant: 4),
            tableView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
        ])

        view = rootView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        reloadItems()
    }

    func syncSelectedAttachmentDrafts(_ drafts: [AttachmentDraft]) {
        selectedDrafts = drafts.filter { $0.source == .contact }
        tableView.reloadData()
    }

    @discardableResult
    func removeSelectedAttachmentDraft(withID draftID: String) -> [AttachmentDraft] {
        let previousDrafts = selectedDrafts
        selectedDrafts.removeAll { $0.id == draftID }
        if selectedDrafts != previousDrafts {
            notifySelectionChanged()
        }
        return selectedDrafts
    }

    @discardableResult
    func replaceSelectedAttachmentDraft(withID draftID: String, updatedDraft: AttachmentDraft) -> [AttachmentDraft] {
        guard let index = selectedDrafts.firstIndex(where: { $0.id == draftID }) else {
            return selectedDrafts
        }
        selectedDrafts[index] = updatedDraft
        notifySelectionChanged()
        return selectedDrafts
    }

    func selectContact(_ item: ChatAttachmentContactListItem) {
        selectedDrafts = [item.makeDraft()]
        notifySelectionChanged()
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        reloadItems()
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        items.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: ChatAttachmentContactSourceCell.reuseIdentifier,
            for: indexPath
        )
        guard let contactCell = cell as? ChatAttachmentContactSourceCell,
              items.indices.contains(indexPath.row) else {
            return cell
        }
        let item = items[indexPath.row]
        contactCell.configure(
            with: item,
            isSelected: selectedDrafts.contains { $0.preparedContact?.jid == item.jid }
        )
        cell.accessibilityIdentifier = "chatAttachmentContact.contact.\(indexPath.row)"
        return contactCell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard items.indices.contains(indexPath.row) else { return }
        selectContact(items[indexPath.row])
        tableView.deselectRow(at: indexPath, animated: true)
    }

    private func reloadItems() {
        items = dataSource.loadItems(
            owner: owner,
            searchQuery: searchBar.text ?? ""
        )
        tableView.reloadData()
    }

    private func notifySelectionChanged() {
        onSelectionCountChanged?(selectedDrafts.count)
        onSelectedAttachmentDraftsChanged?(selectedDrafts)
        tableView.reloadData()
    }
}

private final class ChatAttachmentContactSourceCell: UITableViewCell {
    static let reuseIdentifier = "chatAttachmentContactCell"
    private static let avatarSize: CGFloat = 40

    private var representedAvatarRequestKey: String?

    func configure(
        with item: ChatAttachmentContactListItem,
        isSelected: Bool
    ) {
        let requestKey = Self.avatarRequestKey(for: item)
        let defaultAvatar = UIImageView.getDefaultAvatar(
            for: item.displayTitle,
            owner: item.owner,
            size: Self.avatarSize
        )
        representedAvatarRequestKey = requestKey
        let cachedAvatar = DefaultAvatarManager.shared.cachedAvatarImage(url: item.avatarURL)
        apply(item: item, image: cachedAvatar ?? defaultAvatar)
        accessoryType = isSelected ? .checkmark : .none

        guard cachedAvatar == nil else { return }
        DefaultAvatarManager.shared.getAvatar(
            url: item.avatarURL,
            jid: item.jid,
            owner: item.owner,
            size: Self.avatarSize
        ) { [weak self] image in
            guard let self,
                  self.representedAvatarRequestKey == requestKey else {
                return
            }
            self.apply(item: item, image: image ?? defaultAvatar)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        representedAvatarRequestKey = nil
        contentConfiguration = nil
        accessoryType = .none
    }

    private func apply(item: ChatAttachmentContactListItem, image: UIImage?) {
        var configuration = defaultContentConfiguration()
        configuration.text = item.displayTitle
        configuration.secondaryText = Self.secondaryText(for: item)
        configuration.textProperties.numberOfLines = 1
        configuration.textProperties.lineBreakMode = .byTruncatingTail
        configuration.secondaryTextProperties.numberOfLines = 1
        configuration.secondaryTextProperties.lineBreakMode = .byTruncatingTail
        configuration.image = image
        configuration.imageProperties.maximumSize = CGSize(width: Self.avatarSize, height: Self.avatarSize)
        configuration.imageProperties.cornerRadius = Self.avatarSize / 2
        contentConfiguration = configuration
    }

    private static func secondaryText(for item: ChatAttachmentContactListItem) -> String {
        switch item.entity {
        case .contact:
            return item.jid
        case .groupchat:
            return "Group - \(item.jid)"
        case .incognito:
            return "Incognito group - \(item.jid)"
        }
    }

    private static func avatarRequestKey(for item: ChatAttachmentContactListItem) -> String {
        "\(item.owner)|\(item.jid)|\(item.avatarURL ?? "")|\(Int(avatarSize))"
    }
}

private enum ChatAttachmentContactText {
    static func nonEmpty(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func nickname(fromDisplayTitle displayTitle: String, jid: String) -> String? {
        guard let title = nonEmpty(displayTitle),
              title != JidManager.shared.prepareJid(jid: jid),
              title != jid else {
            return nil
        }
        return title
    }

    static func displayTitle(
        explicitTitle: String?,
        nickname: String?,
        given: String?,
        family: String?,
        jid: String
    ) -> String {
        if let explicitTitle = nonEmpty(explicitTitle) {
            return explicitTitle
        }
        if let nickname = nonEmpty(nickname) {
            return nickname
        }
        let fullName = [nonEmpty(given), nonEmpty(family)]
            .compactMap { $0 }
            .joined(separator: " ")
        if let fullName = nonEmpty(fullName) {
            return fullName
        }
        return jid
    }
}
