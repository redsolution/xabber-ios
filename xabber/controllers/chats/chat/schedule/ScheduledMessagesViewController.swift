//
//  ScheduledMessagesViewController.swift
//  xabber
//
//  Created by Codex on 15.06.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import RealmSwift
import UIKit

struct ScheduledMessageDaySection {
    let day: Date
    let items: [ScheduledMessageListItem]

    static func make(from items: [ScheduledMessageListItem], calendar: Calendar) -> [Self] {
        let days = Dictionary(grouping: items) { calendar.startOfDay(for: $0.deliverAt) }
        return days.keys.sorted().map { day in
            let messages = days[day, default: []].sorted { lhs, rhs in
                lhs.deliverAt == rhs.deliverAt ? lhs.scheduledId < rhs.scheduledId : lhs.deliverAt < rhs.deliverAt
            }
            return Self(day: day, items: messages)
        }
    }
}

final class ScheduledMessagesViewController: SimpleBaseViewController {
    static let tableAccessibilityIdentifier = "chat.schedule.list"
    static let cancelActionAccessibilityIdentifier = "chat.schedule.list.cancel"

    var conversationType: ClientSynchronizationManager.ConversationType = .regular
    var scheduledMessageService: ChatScheduledMessageServicing = AccountChatScheduledMessageService()
    var actionCoordinator: ScheduledMessageActionCoordinator?
    var onDidDisappear: (() -> Void)?

    private lazy var fallbackCoordinator = ScheduledMessageActionCoordinator(service: scheduledMessageService)
    private var coordinator: ScheduledMessageActionCoordinator { actionCoordinator ?? fallbackCoordinator }

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let emptyLabel = UILabel()
    private let banner = UIStackView()
    private let statusLabel = UILabel()
    private let activity = UIActivityIndicatorView(style: .medium)
    private let retryButton = UIButton(type: .system)
    private let recoveryButton = UIButton(type: .system)
    private let refreshControl = UIRefreshControl()
    private let attachmentPreview = ScheduledAttachmentPreviewCoordinator()

    private var sections: [ScheduledMessageDaySection] = []
    private var itemsByID: [String: ScheduledMessageListItem] = [:]
    private var selectedIDs: Set<String> = []
    private var activeIDs: Set<String> = []
    private var editDrafts: [String: ScheduledMessageEditDraft] = [:]
    private var isRefreshing = false
    private var refreshFailed = false
    private var actionNotice: String?
    private var notificationToken: NotificationToken?
    private var countdownTimer: Timer?
    private var didActivateConstraints = false

    private var selectedItems: [ScheduledMessageListItem] {
        sections.flatMap(\.items).filter { selectedIDs.contains($0.scheduledId) }
    }

    override func setupSubviews() {
        super.setupSubviews()
        [banner, tableView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        [activity, statusLabel, retryButton, recoveryButton].forEach { banner.addArrangedSubview($0) }
        tableView.backgroundView = emptyLabel
    }

    override func configure() {
        super.configure()
        title = L10n.text("scheduled_messages_title", fallback: "Scheduled Messages")
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(close(_:))
        )

        tableView.accessibilityIdentifier = Self.tableAccessibilityIdentifier
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 76
        tableView.allowsSelection = false
        tableView.allowsSelectionDuringEditing = true
        tableView.allowsMultipleSelectionDuringEditing = true
        tableView.refreshControl = refreshControl
        tableView.register(ScheduledMessageCell.self, forCellReuseIdentifier: ScheduledMessageCell.reuseIdentifier)
        refreshControl.addTarget(self, action: #selector(refreshRemoteRows), for: .valueChanged)

        banner.axis = .vertical
        banner.alignment = .center
        banner.spacing = 4
        activity.hidesWhenStopped = true
        for label in [emptyLabel, statusLabel] {
            label.font = .preferredFont(forTextStyle: .subheadline)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = .secondaryLabel
            label.textAlignment = .center
            label.numberOfLines = 0
        }
        emptyLabel.text = L10n.text("scheduled_messages_empty", fallback: "No scheduled messages")
        retryButton.setTitle(L10n.text("common__action__retry", fallback: "Retry"), for: .normal)
        retryButton.accessibilityIdentifier = "chat.schedule.list.refresh"
        retryButton.addTarget(self, action: #selector(refreshRemoteRows), for: .touchUpInside)
        recoveryButton.setTitle(L10n.text("scheduled_messages_review", fallback: "Review pending actions"), for: .normal)
        recoveryButton.accessibilityIdentifier = "chat.schedule.list.recovery"
        recoveryButton.addTarget(self, action: #selector(showRecoveries), for: .touchUpInside)
        for button in [retryButton, recoveryButton] {
            button.titleLabel?.font = .preferredFont(forTextStyle: .body)
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            let hitTarget = button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
            hitTarget.priority = .defaultHigh
            hitTarget.isActive = true
        }
        updateControls()
    }

    override func activateConstraints() {
        super.activateConstraints()
        guard !didActivateConstraints else { return }
        didActivateConstraints = true
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            banner.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),

            tableView.topAnchor.constraint(equalTo: banner.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        observeLocalRows()
        reloadLocalRows()
        refreshRemoteRows()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateVisibleCountdowns()
        countdownTimer?.invalidate()
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateVisibleCountdowns() }
        }
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        attachmentPreview.cancel()
        countdownTimer?.invalidate()
        countdownTimer = nil
        notificationToken?.invalidate()
        notificationToken = nil
        onDidDisappear?()
    }

    private func observeLocalRows() {
        notificationToken?.invalidate()
        guard let realm = try? WRealm.safe() else { return }
        let results = ScheduledMessagesComposerButtonModel.results(
            owner: owner,
            conversation: jid,
            conversationType: conversationType,
            realm: realm
        )
        notificationToken = results.observe { [weak self] _ in
            self?.reloadLocalRows()
        }
    }

    private func reloadLocalRows() {
        guard let realm = try? WRealm.safe(),
              let loaded = try? ScheduledMessagesListModel.items(
                owner: owner,
                conversation: jid,
                conversationType: conversationType,
                realm: realm
              ) else {
            refreshFailed = true
            updateControls()
            return
        }
        sections = ScheduledMessageDaySection.make(from: loaded, calendar: L10n.formatters.calendar)
        itemsByID = Dictionary(uniqueKeysWithValues: loaded.map { ($0.scheduledId, $0) })
        selectedIDs.formIntersection(itemsByID.keys)
        editDrafts = editDrafts.filter { itemsByID[$0.key] != nil || activeIDs.contains($0.key) }
        tableView.reloadData()
        if tableView.isEditing {
            for (section, day) in sections.enumerated() {
                for (row, item) in day.items.enumerated() where selectedIDs.contains(item.scheduledId) {
                    tableView.selectRow(at: IndexPath(row: row, section: section), animated: false, scrollPosition: .none)
                }
            }
            if itemsByID.isEmpty { tableView.setEditing(false, animated: false) }
        }
        updateControls()
    }

    @objc private func refreshRemoteRows() {
        guard !isRefreshing else { return }
        isRefreshing = true
        refreshFailed = false
        updateControls()
        scheduledMessageService.listScheduledMessages(
            owner: owner,
            conversation: jid,
            conversationType: conversationType
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRefreshing = false
                self.refreshControl.endRefreshing()
                switch result {
                case .success:
                    self.reloadLocalRows()
                case .failure:
                    self.refreshFailed = true
                }
                self.updateControls()
            }
        }
    }

    private func updateControls() {
        let isBusy = !activeIDs.isEmpty
        let isEditing = tableView.isEditing
        title = isEditing
            ? L10n.format(
                "scheduled_messages_selection_count",
                fallback: "%@ selected",
                arguments: [L10n.formatters.numberFormatter(style: .decimal).string(from: NSNumber(value: selectedIDs.count)) ?? String(selectedIDs.count)]
            )
            : L10n.text("scheduled_messages_title", fallback: "Scheduled Messages")
        navigationItem.leftBarButtonItem?.isEnabled = !isBusy
        isModalInPresentation = isBusy
        navigationController?.isModalInPresentation = isBusy

        if isEditing {
            let endSelection = UIBarButtonItem(
                systemItem: .cancel,
                primaryAction: UIAction { [weak self] _ in self?.finishSelection() }
            )
            let send = UIBarButtonItem(
                image: UIImage(systemName: "paperplane"),
                primaryAction: UIAction { [weak self] _ in self?.performSelection(.sendNow) }
            )
            send.accessibilityLabel = L10n.text("scheduled_message_send_now", fallback: "Send Now")
            send.accessibilityIdentifier = "chat.schedule.list.selection.send"
            send.isEnabled = !isBusy && !selectedIDs.isEmpty
                && selectedItems.allSatisfy { ScheduledMessageActionCoordinator.supports(.sendNow, on: $0) }
            let delete = UIBarButtonItem(
                image: UIImage(systemName: "trash"),
                primaryAction: UIAction { [weak self] _ in self?.performSelection(.delete) }
            )
            delete.accessibilityLabel = L10n.text("common__action__delete", fallback: "Delete")
            delete.accessibilityIdentifier = "chat.schedule.list.selection.delete"
            delete.isEnabled = !isBusy && !selectedIDs.isEmpty
            endSelection.isEnabled = !isBusy
            navigationItem.rightBarButtonItems = [delete, send, endSelection]
        } else {
            let select = UIBarButtonItem(
                title: L10n.text("common__action__select", fallback: "Select"),
                primaryAction: UIAction { [weak self] _ in self?.startSelection() }
            )
            select.accessibilityIdentifier = "chat.schedule.list.select"
            select.isEnabled = !isBusy && !itemsByID.isEmpty
            navigationItem.rightBarButtonItems = [select]
        }

        if isBusy || (isRefreshing && itemsByID.isEmpty) { activity.startAnimating() } else { activity.stopAnimating() }
        if isBusy {
            statusLabel.text = L10n.text("scheduled_messages_working", fallback: "Updating scheduled messages…")
        } else if isRefreshing && itemsByID.isEmpty {
            statusLabel.text = L10n.text("scheduled_messages_loading", fallback: "Loading scheduled messages…")
        } else if refreshFailed {
            statusLabel.text = L10n.text("scheduled_messages_load_error", fallback: "Could not load scheduled messages.")
        } else {
            statusLabel.text = actionNotice
        }
        statusLabel.isHidden = statusLabel.text == nil
        retryButton.isHidden = !refreshFailed || isBusy || isRefreshing
        recoveryButton.isHidden = isBusy || recoveries.isEmpty
        recoveryButton.titleLabel?.numberOfLines = 0
        recoveryButton.titleLabel?.textAlignment = .center
        banner.isHidden = activity.isHidden && statusLabel.isHidden && retryButton.isHidden && recoveryButton.isHidden
        emptyLabel.isHidden = !itemsByID.isEmpty || refreshFailed || isRefreshing || isBusy
    }

    private func dayTitle(_ date: Date, now: Date = Date()) -> String {
        let calendar = L10n.formatters.calendar
        if calendar.isDate(date, inSameDayAs: now) {
            return L10n.text("today", fallback: "Today")
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return L10n.text("scheduled_message_tomorrow", fallback: "Tomorrow")
        }
        return L10n.formatters.dateFormatter(dateStyle: .medium).string(from: date)
    }

    private func updateVisibleCountdowns() {
        let now = Date()
        for indexPath in tableView.indexPathsForVisibleRows ?? [] {
            guard let cell = tableView.cellForRow(at: indexPath) as? ScheduledMessageCell,
                  let item = item(at: indexPath) else { continue }
            cell.updateCountdown(for: item, now: now)
        }
        for (index, section) in sections.enumerated() {
            tableView.headerView(forSection: index)?.textLabel?.text = dayTitle(section.day, now: now)
        }
    }

    private func item(at indexPath: IndexPath) -> ScheduledMessageListItem? {
        guard sections.indices.contains(indexPath.section),
              sections[indexPath.section].items.indices.contains(indexPath.row) else { return nil }
        return sections[indexPath.section].items[indexPath.row]
    }

    private func startSelection(initialID: String? = nil) {
        guard !itemsByID.isEmpty, activeIDs.isEmpty else { return }
        if let initialID, itemsByID[initialID] == nil { return }
        tableView.setEditing(true, animated: true)
        if let initialID {
            for (section, day) in sections.enumerated() {
                guard let row = day.items.firstIndex(where: { $0.scheduledId == initialID }) else { continue }
                select(itemAt: IndexPath(row: row, section: section))
                break
            }
        }
        updateVisibleAccessibilityActions()
        updateControls()
    }

    private func select(itemAt indexPath: IndexPath) {
        guard let item = item(at: indexPath) else { return }
        tableView.selectRow(at: indexPath, animated: false, scrollPosition: .none)
        selectedIDs.insert(item.scheduledId)
    }

    private func finishSelection() {
        selectedIDs.removeAll()
        tableView.setEditing(false, animated: true)
        updateVisibleAccessibilityActions()
        updateControls()
    }

    private func performSelection(_ action: ScheduledMessageAction) {
        let selection = selectedItems
        guard !selection.isEmpty else { return }
        perform(action, items: selection)
    }

    private func perform(
        _ action: ScheduledMessageAction,
        items: [ScheduledMessageListItem],
        completion: ((Result<Void, ScheduledMessageActionFailure>) -> Void)? = nil
    ) {
        guard activeIDs.isEmpty, !items.isEmpty,
              items.allSatisfy({ itemsByID[$0.scheduledId] == $0 }) else {
            reportChangedItem()
            completion?(.failure(.init(error: .itemNotFound, recovery: nil)))
            return
        }
        activeIDs = Set(items.map(\.scheduledId))
        actionNotice = nil
        if tableView.isEditing { finishSelection() }
        updateVisibleAccessibilityActions()
        updateControls()

        Task { [weak self] in
            guard let self else { return }
            let outcomes = await coordinator.perform(action, on: items)
            var failures: [ScheduledMessageActionFailure] = []
            for (item, result) in outcomes {
                switch result {
                case .success:
                    editDrafts.removeValue(forKey: item.scheduledId)
                case .failure(let failure):
                    failures.append(failure)
                }
            }
            if failures.count > 1 || (!failures.isEmpty && items.count > 1) {
                actionNotice = L10n.text("scheduled_messages_batch_error", fallback: "Some actions could not be completed.")
            } else if let failure = failures.first {
                actionNotice = notice(for: failure)
            }
            activeIDs.removeAll()
            reloadLocalRows()
            if let outcome = outcomes.first { completion?(outcome.result) }
        }
    }

    private func reportChangedItem() {
        actionNotice = L10n.text("scheduled_messages_changed", fallback: "The scheduled message changed. Review the updated list.")
        refreshRemoteRows()
        updateControls()
    }

    private func notice(for failure: ScheduledMessageActionFailure) -> String {
        switch failure.error {
        case .itemNotFound:
            return L10n.text("scheduled_messages_changed", fallback: "The scheduled message changed. Review the updated list.")
        case .notAcceptable:
            return L10n.text("scheduled_messages_time_error", fallback: "Choose a valid future send time.")
        case .resourceConstraint:
            return L10n.text("scheduled_messages_limit_error", fallback: "The server limit for scheduled messages was reached.")
        case .forbidden:
            return L10n.text("scheduled_messages_permission_error", fallback: "You do not have permission for this action.")
        default:
            return L10n.text("scheduled_messages_action_error", fallback: "Could not update the scheduled message.")
        }
    }

    private func edit(_ item: ScheduledMessageListItem) {
        guard itemsByID[item.scheduledId] == item, activeIDs.isEmpty,
              let content = ScheduledMessageContent.read(item) else { return }
        let editor = ScheduledMessageEditViewController(
            item: item,
            display: ScheduledMessageDisplayContent(item: item),
            draft: editDrafts[item.scheduledId] ?? ScheduledMessageEditDraft(content: content),
            errorText: { [weak self] failure in
                self?.notice(for: failure) ?? L10n.text("scheduled_messages_action_error", fallback: "Could not update the scheduled message.")
            }
        ) { [weak self] draft, completion in
            guard let self else {
                completion(.failure(.init(error: .disconnected, recovery: nil)))
                return
            }
            editDrafts[item.scheduledId] = draft
            perform(draft.action, items: [item], completion: completion)
        }
        let navigation = UINavigationController(rootViewController: editor)
        navigation.modalPresentationStyle = .formSheet
        navigation.isModalInPresentation = true
        present(navigation, animated: true)
    }

    private func reschedule(_ item: ScheduledMessageListItem) {
        guard itemsByID[item.scheduledId] == item, activeIDs.isEmpty else { return }
        let picker = ScheduledMessageDatePickerViewController(initialDate: item.deliverAt) { [weak self] date in
            self?.perform(.reschedule(date), items: [item])
        }
        present(picker, animated: true)
    }

    private var recoveries: [ScheduledMessageActionRecovery] {
        coordinator.recoveries(owner: owner, conversation: jid, conversationType: conversationType)
    }

    @objc private func showRecoveries() {
        let pending = recoveries
        guard let first = pending.first else { return }
        if pending.count == 1 {
            showRecovery(first)
            return
        }
        let menu = UIAlertController(
            title: L10n.text("scheduled_messages_review", fallback: "Review pending actions"),
            message: nil,
            preferredStyle: .actionSheet
        )
        for recovery in pending {
            menu.addAction(UIAlertAction(title: String(recoveryBody(recovery).prefix(60)), style: .default) { [weak self] _ in
                self?.showRecovery(recovery)
            })
        }
        menu.addAction(UIAlertAction(title: L10n.text("common__action__cancel", fallback: "Cancel"), style: .cancel))
        menu.popoverPresentationController?.sourceView = recoveryButton
        menu.popoverPresentationController?.sourceRect = recoveryButton.bounds
        present(menu, animated: true)
    }

    private func recoveryBody(_ recovery: ScheduledMessageActionRecovery) -> String {
        let display = ScheduledMessageDisplayContent(item: recovery.item)
        let body: String
        switch recovery.action {
        case .edit(let text), .editContent(let text, _, _): body = text
        default: body = display.body
        }
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty
            ? L10n.text("scheduled_message_preview_fallback", fallback: "Scheduled message")
            : text
    }

    private func showRecovery(_ recovery: ScheduledMessageActionRecovery) {
        let detail = recovery.requiresRefresh
            ? L10n.text("scheduled_messages_unknown_result", fallback: "The server did not confirm the result. Refresh and review the list.")
            : L10n.text("scheduled_messages_recovery_detail", fallback: "The original was canceled. You can continue the pending action.")
        let alert = UIAlertController(
            title: L10n.text("scheduled_messages_review", fallback: "Review pending actions"),
            message: "\(detail)\n\n\(recoveryBody(recovery))",
            preferredStyle: .alert
        )
        if recovery.requiresRefresh {
            alert.addAction(UIAlertAction(title: L10n.text("scheduled_messages_refresh", fallback: "Refresh"), style: .default) { [weak self] _ in
                self?.refreshRemoteRows()
            })
        } else {
            alert.addAction(UIAlertAction(title: L10n.text("common__action__retry", fallback: "Retry"), style: .default) { [weak self] _ in
                self?.continueRecovery(recovery)
            })
        }
        alert.addAction(UIAlertAction(title: L10n.text("common__action__copy", fallback: "Copy"), style: .default) { [weak self] _ in
            guard let self else { return }
            UIPasteboard.general.string = self.recoveryBody(recovery)
        })
        alert.addAction(UIAlertAction(title: L10n.text("scheduled_messages_discard_action", fallback: "Discard Action"), style: .destructive) { [weak self] _ in
            self?.coordinator.dismissRecovery(recovery)
            self?.updateControls()
        })
        alert.addAction(UIAlertAction(title: L10n.text("common__action__cancel", fallback: "Cancel"), style: .cancel))
        present(alert, animated: true)
    }

    private func continueRecovery(_ recovery: ScheduledMessageActionRecovery) {
        guard activeIDs.isEmpty, !recovery.requiresRefresh else { return }
        activeIDs = [recovery.item.scheduledId]
        actionNotice = nil
        updateVisibleAccessibilityActions()
        updateControls()
        Task { [weak self] in
            guard let self else { return }
            if case .failure(let failure) = await coordinator.retry(recovery) {
                actionNotice = notice(for: failure)
            }
            activeIDs.removeAll()
            reloadLocalRows()
        }
    }
}

extension ScheduledMessagesViewController: UITableViewDataSource, UITableViewDelegate {
    private struct RowAction {
        let identifier: String
        let title: String
        let symbol: String
        var destructive = false
        let handler: () -> Void
    }

    private func rowActions(for item: ScheduledMessageListItem, display: ScheduledMessageDisplayContent) -> [RowAction] {
        guard activeIDs.isEmpty, !tableView.isEditing else { return [] }
        let id = item.scheduledId
        var actions: [RowAction] = []
        if ScheduledMessageActionCoordinator.supports(.edit(display.body), on: item) {
            actions.append(RowAction(identifier: "chat.schedule.list.edit", title: L10n.text("common__action__edit", fallback: "Edit"), symbol: "pencil") { [weak self] in
                self?.edit(item)
            })
        }
        if !display.body.isEmpty {
            actions.append(RowAction(identifier: "chat.schedule.list.copy", title: L10n.text("common__action__copy", fallback: "Copy"), symbol: "document.on.document") {
                UIPasteboard.general.string = display.body
            })
        }
        if ScheduledMessageActionCoordinator.supports(.sendNow, on: item) {
            actions.append(RowAction(identifier: "chat.schedule.list.send", title: L10n.text("scheduled_message_send_now", fallback: "Send Now"), symbol: "paperplane") { [weak self] in
                self?.perform(.sendNow, items: [item])
            })
        }
        if ScheduledMessageActionCoordinator.supports(.reschedule(item.deliverAt), on: item) {
            actions.append(RowAction(identifier: "chat.schedule.list.reschedule", title: L10n.text("scheduled_message_reschedule", fallback: "Reschedule"), symbol: "calendar.badge.clock") { [weak self] in
                self?.reschedule(item)
            })
        }
        actions.append(RowAction(identifier: "chat.schedule.list.select", title: L10n.text("common__action__select", fallback: "Select"), symbol: "checkmark.circle") { [weak self] in
            self?.startSelection(initialID: id)
        })
        actions.append(RowAction(
            identifier: Self.cancelActionAccessibilityIdentifier,
            title: L10n.text("common__action__delete", fallback: "Delete"),
            symbol: "trash",
            destructive: true
        ) { [weak self] in self?.perform(.delete, items: [item]) })
        return actions
    }

    private func updateVisibleAccessibilityActions() {
        for indexPath in tableView.indexPathsForVisibleRows ?? [] {
            guard let item = item(at: indexPath),
                  let cell = tableView.cellForRow(at: indexPath) as? ScheduledMessageCell else { continue }
            cell.setAttachmentInteractionEnabled(activeIDs.isEmpty && !tableView.isEditing)
            cell.accessibilityCustomActions = accessibilityActions(for: item, display: ScheduledMessageDisplayContent(item: item))
        }
    }

    private func accessibilityActions(
        for item: ScheduledMessageListItem,
        display: ScheduledMessageDisplayContent
    ) -> [UIAccessibilityCustomAction] {
        guard activeIDs.isEmpty, !tableView.isEditing else { return [] }
        let messageActions = rowActions(for: item, display: display).map { action in
            UIAccessibilityCustomAction(name: action.title) { _ in
                action.handler()
                return true
            }
        }
        let previewActions = display.attachments.filter { $0.url != nil }.map { attachment in
            let label = L10n.format("scheduled_message_open_attachment", fallback: "Open %@", arguments: [attachment.title])
            return UIAccessibilityCustomAction(name: label) { [weak self] _ in
                self?.openAttachment(attachment, item: item)
                return true
            }
        }
        return previewActions + messageActions
    }

    private func openAttachment(
        _ attachment: ScheduledMessageAttachmentPresentation,
        item: ScheduledMessageListItem
    ) {
        attachmentPreview.open(attachment, owner: item.owner, from: self) { [weak self] in
            guard let self else { return false }
            return owner == item.owner && jid == item.conversation && conversationType == item.conversationType
                && itemsByID[item.scheduledId] == item && activeIDs.isEmpty && !tableView.isEditing
        }
    }

    func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        dayTitle(sections[section].day)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].items.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: ScheduledMessageCell.reuseIdentifier,
            for: indexPath
        ) as! ScheduledMessageCell
        let item = sections[indexPath.section].items[indexPath.row]
        let display = ScheduledMessageDisplayContent(item: item)
        cell.configure(with: item, display: display) { [weak self] attachment in
            self?.openAttachment(attachment, item: item)
        }
        cell.setAttachmentInteractionEnabled(activeIDs.isEmpty && !tableView.isEditing)
        cell.accessibilityCustomActions = accessibilityActions(for: item, display: display)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard tableView.isEditing, activeIDs.isEmpty else { return }
        select(itemAt: indexPath)
        updateControls()
    }

    func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        guard let item = item(at: indexPath) else { return }
        selectedIDs.remove(item.scheduledId)
        updateControls()
    }

    func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let item = item(at: indexPath) else { return nil }
        let actions = rowActions(for: item, display: ScheduledMessageDisplayContent(item: item))
        guard !actions.isEmpty else { return nil }
        return UIContextMenuConfiguration(identifier: item.scheduledId as NSString, previewProvider: nil) { _ in
            UIMenu(children: actions.map { action in
                UIAction(
                    title: action.title,
                    image: UIImage(systemName: action.symbol),
                    identifier: UIAction.Identifier(rawValue: action.identifier),
                    attributes: action.destructive ? .destructive : []
                ) { _ in action.handler() }
            })
        }
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let item = item(at: indexPath), activeIDs.isEmpty, !tableView.isEditing else { return nil }
        let title = L10n.text("common__action__delete", fallback: "Delete")
        let action = UIContextualAction(style: .destructive, title: title) { [weak self] _, _, completion in
            guard let self, self.itemsByID[item.scheduledId] == item, self.activeIDs.isEmpty else {
                completion(false)
                return
            }
            self.perform(.delete, items: [item])
            completion(true)
        }
        action.accessibilityLabel = title
        let configuration = UISwipeActionsConfiguration(actions: [action])
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }
}

final class ScheduledMessageCell: UITableViewCell {
    static let reuseIdentifier = "ScheduledMessageCell"

    private let previewLabel = UILabel()
    private let attachmentList = UIStackView()
    private let detailLabel = UILabel()
    private let statusLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        let labels = UIStackView(arrangedSubviews: [previewLabel, attachmentList, detailLabel, statusLabel])
        labels.axis = .vertical
        labels.spacing = 3
        labels.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(labels)
        NSLayoutConstraint.activate([
            labels.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            labels.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            labels.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            labels.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor)
        ])
        isAccessibilityElement = true
        for label in [previewLabel, detailLabel, statusLabel] {
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
            label.isAccessibilityElement = false
        }
        previewLabel.font = .preferredFont(forTextStyle: .body)
        attachmentList.axis = .vertical
        attachmentList.spacing = 3
        detailLabel.font = .preferredFont(forTextStyle: .subheadline)
        detailLabel.textColor = .secondaryLabel
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        with item: ScheduledMessageListItem,
        display: ScheduledMessageDisplayContent,
        onPreview: @escaping (ScheduledMessageAttachmentPresentation) -> Void
    ) {
        previewLabel.isHidden = display.body.isEmpty && !display.attachments.isEmpty
        if display.body.isEmpty {
            previewLabel.text = L10n.text("scheduled_message_preview_fallback", fallback: "Scheduled message")
        } else {
            previewLabel.attributedText = display.attributedBody(
                font: .preferredFont(forTextStyle: .body), color: .label, mentionColor: tintColor
            )
        }
        attachmentList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        display.attachments.forEach { attachment in
            attachmentList.addArrangedSubview(attachment.previewButton { onPreview(attachment) })
        }
        attachmentList.isHidden = display.attachments.isEmpty
        detailLabel.text = L10n.formatters.dateFormatter(timeStyle: .short).string(from: item.deliverAt)
        let caption = previewLabel.isHidden ? [] : [display.body.isEmpty ? previewLabel.text ?? "" : display.body]
        accessibilityLabel = (caption + display.attachments.map(\.title)).joined(separator: ", ")
        accessibilityIdentifier = "chat.schedule.list.message"
        updateCountdown(for: item, now: Date())
    }

    func setAttachmentInteractionEnabled(_ enabled: Bool) {
        attachmentList.isUserInteractionEnabled = enabled
    }

    func updateCountdown(for item: ScheduledMessageListItem, now: Date) {
        switch item.status {
        case .pending:
            let formatters = L10n.formatters
            let policy = ScheduledMessageDatePolicy(calendar: formatters.calendar, locale: formatters.locale, timeZone: formatters.timeZone)
            statusLabel.text = policy.countdown(for: item.deliverAt, now: now)
            statusLabel.textColor = .secondaryLabel
        case .failed:
            statusLabel.text = L10n.text("scheduled_message_status_failed", fallback: "Failed")
            statusLabel.textColor = .systemRed
        }
        accessibilityValue = [detailLabel.text, statusLabel.text].compactMap { $0 }.joined(separator: ", ")
    }
}
