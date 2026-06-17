//
//  ScheduledMessagesViewController.swift
//  xabber
//
//  Created by Codex on 15.06.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import RealmSwift
import UIKit

final class ScheduledMessagesViewController: SimpleBaseViewController {
    static let tableAccessibilityIdentifier = "chat.schedule.list"
    static let cancelActionAccessibilityIdentifier = "chat.schedule.list.cancel"

    var conversationType: ClientSynchronizationManager.ConversationType = .regular
    var scheduledMessageService: ChatScheduledMessageServicing = AccountChatScheduledMessageService()
    var onDidDisappear: (() -> Void)?

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let emptyLabel = UILabel()
    private var items: [ScheduledMessageListItem] = []
    private var notificationToken: NotificationToken?
    private var didActivateConstraints = false

    override func setupSubviews() {
        super.setupSubviews()
        view.addSubview(tableView)
        view.addSubview(emptyLabel)
    }

    override func configure() {
        super.configure()
        title = "Scheduled Messages".localizeString(id: "scheduled_messages_title", arguments: [])
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(close(_:))
        )

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.accessibilityIdentifier = Self.tableAccessibilityIdentifier
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(ScheduledMessageCell.self, forCellReuseIdentifier: ScheduledMessageCell.reuseIdentifier)

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.text = "No scheduled messages".localizeString(id: "scheduled_messages_empty", arguments: [])
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.font = .systemFont(ofSize: 15, weight: .regular)
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
    }

    override func activateConstraints() {
        super.activateConstraints()
        guard !didActivateConstraints else { return }
        didActivateConstraints = true
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        observeLocalRows()
        reloadLocalRows()
        refreshRemoteRows()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        notificationToken?.invalidate()
        notificationToken = nil
        onDidDisappear?()
    }

    private func observeLocalRows() {
        notificationToken?.invalidate()
        guard let realm = try? WRealm.safe() else { return }
        let results = realm.objects(XMPPMessageScheduleStorageItem.self)
            .filter("owner == %@ AND conversation == %@ AND conversationType_ == %@", owner, jid, conversationType.rawValue)
            .sorted(byKeyPath: "deliverAt", ascending: true)
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
            items = []
            tableView.reloadData()
            updateEmptyState()
            return
        }
        items = loaded
        tableView.reloadData()
        updateEmptyState()
    }

    private func refreshRemoteRows() {
        scheduledMessageService.listScheduledMessages(
            owner: owner,
            conversation: jid,
            conversationType: conversationType
        ) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self?.reloadLocalRows()
                case .failure:
                    ToastPresenter().presentError(
                        message: "Could not load scheduled messages.".localizeString(id: "scheduled_messages_load_error", arguments: [])
                    )
                }
            }
        }
    }

    private func updateEmptyState() {
        emptyLabel.isHidden = !items.isEmpty
        tableView.isHidden = items.isEmpty
    }

    private func cancel(item: ScheduledMessageListItem) {
        scheduledMessageService.cancelScheduledMessage(
            owner: owner,
            scheduledId: item.scheduledId
        ) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self?.reloadLocalRows()
                case .failure:
                    ToastPresenter().presentError(
                        message: "Could not cancel scheduled message.".localizeString(id: "scheduled_messages_cancel_error", arguments: [])
                    )
                }
            }
        }
    }
}

extension ScheduledMessagesViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        items.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: ScheduledMessageCell.reuseIdentifier,
            for: indexPath
        ) as! ScheduledMessageCell
        cell.configure(with: items[indexPath.row])
        return cell
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        let action = UIContextualAction(
            style: .destructive,
            title: "Cancel".localizeString(id: "scheduled_messages_cancel", arguments: [])
        ) { [weak self] _, _, completion in
            guard let self else {
                completion(false)
                return
            }
            self.cancel(item: self.items[indexPath.row])
            completion(true)
        }
        action.accessibilityLabel = "Cancel".localizeString(id: "scheduled_messages_cancel", arguments: [])
        return UISwipeActionsConfiguration(actions: [action])
    }
}

final class ScheduledMessageCell: UITableViewCell {
    static let reuseIdentifier = "ScheduledMessageCell"

    private let previewLabel = UILabel()
    private let detailLabel = UILabel()
    private let statusLabel = UILabel()
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        previewLabel.font = .systemFont(ofSize: 16, weight: .regular)
        previewLabel.textColor = .label
        previewLabel.numberOfLines = 2

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 13, weight: .regular)
        detailLabel.textColor = .secondaryLabel

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .right
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        contentView.addSubview(previewLabel)
        contentView.addSubview(detailLabel)
        contentView.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            previewLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            previewLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            previewLabel.trailingAnchor.constraint(equalTo: statusLabel.leadingAnchor, constant: -12),

            statusLabel.topAnchor.constraint(equalTo: previewLabel.topAnchor, constant: 2),
            statusLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 52),

            detailLabel.topAnchor.constraint(equalTo: previewLabel.bottomAnchor, constant: 4),
            detailLabel.leadingAnchor.constraint(equalTo: previewLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            detailLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10)
        ])
    }

    func configure(with item: ScheduledMessageListItem) {
        previewLabel.text = item.bodyPreview.isEmpty
            ? "Scheduled message".localizeString(id: "scheduled_message_preview_fallback", arguments: [])
            : item.bodyPreview
        detailLabel.text = dateFormatter.string(from: item.deliverAt)
        switch item.status {
        case .pending:
            statusLabel.text = "Pending".localizeString(id: "scheduled_message_status_pending", arguments: [])
            statusLabel.textColor = .secondaryLabel
        case .failed:
            statusLabel.text = "Failed".localizeString(id: "scheduled_message_status_failed", arguments: [])
            statusLabel.textColor = .systemRed
        }
    }
}
