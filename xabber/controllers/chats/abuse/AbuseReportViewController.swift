//
//  AbuseReportViewController.swift
//  xabber
//
//  Created by Игорь Болдин on 12.02.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import RealmSwift
import CocoaLumberjack
import XMPPFramework.XMPPJID

enum AbuseReportTargetContext {
    case message(primary: String)
    case media(messagePrimary: String?, referencePrimary: String?, attachmentPrimary: String?)
    case user(reportedUserJid: String, roomJid: String?)
    case room(roomJid: String)
}

class AbuseReportViewController: SimpleBaseViewController {
    private enum Section: Int, CaseIterable {
        case explanation
        case metadata
        case reasons
        case options
        case comment
    }

    private enum Option {
        case includeExcerpt
        case hideLocally
    }

    final class CommentCell: UITableViewCell, UITextViewDelegate {
        static let cellName = "AbuseReportCommentCell"

        let textView: UITextView = {
            let textView = UITextView()
            textView.font = UIFont.preferredFont(forTextStyle: .body)
            textView.adjustsFontForContentSizeCategory = true
            textView.isScrollEnabled = false
            textView.backgroundColor = .clear
            textView.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
            textView.accessibilityIdentifier = "report.comment"
            return textView
        }()

        var onChange: ((String) -> Void)?

        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            selectionStyle = .none
            contentView.addSubview(textView)
            textView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                textView.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
                textView.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
                textView.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
                textView.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
                textView.heightAnchor.constraint(greaterThanOrEqualToConstant: 96)
            ])
            textView.delegate = self
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func configure(text: String, placeholder: String) {
            textView.text = text
            textView.accessibilityLabel = placeholder
        }

        func textViewDidChange(_ textView: UITextView) {
            onChange?(textView.text)
        }
    }

    let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .insetGrouped)
        view.register(UITableViewCell.self, forCellReuseIdentifier: "ReportCell")
        view.register(UITableViewCell.self, forCellReuseIdentifier: "ReportValueCell")
        view.register(CommentCell.self, forCellReuseIdentifier: CommentCell.cellName)
        view.estimatedRowHeight = 56
        view.rowHeight = UITableView.automaticDimension
        return view
    }()

    open var message: String = ""
    open var conversationType: ClientSynchronizationManager.ConversationType = .regular

    private var targetContext: AbuseReportTargetContext?
    private var metadataRows: [(title: String, value: String)] = []
    private var selectedReason: ReportReason?
    private var includeMessageExcerpt: Bool = false
    private var hideLocally: Bool = false
    private var comment: String = ""
    private var isSubmitting: Bool = false

    private lazy var submitButton: UIBarButtonItem = {
        let button = UIBarButtonItem(
            title: "Submit Report".localizeString(id: "report_submit_button", arguments: []),
            style: .done,
            target: self,
            action: #selector(onSubmit)
        )
        button.accessibilityIdentifier = "report.submit"
        button.isEnabled = false
        return button
    }()

    private lazy var cancelButton: UIBarButtonItem = {
        let button = UIBarButtonItem(
            title: "Cancel".localizeString(id: "cancel", arguments: []),
            style: .plain,
            target: self,
            action: #selector(onCancel)
        )
        button.accessibilityIdentifier = "report.cancel"
        return button
    }()

    func configureMessageReport(owner: String, jid: String, conversationType: ClientSynchronizationManager.ConversationType, messagePrimary: String) {
        self.owner = owner
        self.jid = jid
        self.conversationType = conversationType
        self.message = messagePrimary
        self.targetContext = .message(primary: messagePrimary)
    }

    func configureMediaReport(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        messagePrimary: String? = nil,
        referencePrimary: String? = nil,
        mediaAttachmentPrimary: String? = nil
    ) {
        self.owner = owner
        self.jid = jid
        self.conversationType = conversationType
        self.targetContext = .media(
            messagePrimary: messagePrimary,
            referencePrimary: referencePrimary,
            attachmentPrimary: mediaAttachmentPrimary
        )
    }

    func configureUserReport(owner: String, jid: String, reportedUserJid: String, roomJid: String? = nil, conversationType: ClientSynchronizationManager.ConversationType = .regular) {
        self.owner = owner
        self.jid = jid
        self.conversationType = conversationType
        self.targetContext = .user(reportedUserJid: reportedUserJid, roomJid: roomJid)
    }

    func configureRoomReport(owner: String, roomJid: String) {
        self.owner = owner
        self.jid = roomJid
        self.conversationType = .group
        self.targetContext = .room(roomJid: roomJid)
    }

    override func setupSubviews() {
        super.setupSubviews()
        view.addSubview(tableView)
        tableView.fillSuperview()
    }

    override func configure() {
        super.configure()
        title = "Report".localizeString(id: "report_title", arguments: [])
        view.accessibilityIdentifier = "report.screen"
        tableView.delegate = self
        tableView.dataSource = self
        navigationItem.leftBarButtonItem = cancelButton
        navigationItem.rightBarButtonItem = submitButton
    }

    override func subscribe() {
        super.subscribe()
        if targetContext == nil, message.isNotEmpty {
            targetContext = .message(primary: message)
        }
        metadataRows = makeMetadataRows()
        updateSubmitState()
    }

    private var effectiveTarget: AbuseReportTargetContext? {
        if let targetContext = targetContext {
            return targetContext
        }
        if message.isNotEmpty {
            return .message(primary: message)
        }
        return nil
    }

    private var options: [Option] {
        guard let target = effectiveTarget else {
            return []
        }
        switch target {
        case .message:
            return [.includeExcerpt, .hideLocally]
        case .media:
            return [.hideLocally]
        case .user, .room:
            return []
        }
    }

    private func makeMetadataRows() -> [(String, String)] {
        guard let target = effectiveTarget else {
            return []
        }
        do {
            let realm = try WRealm.safe()
            switch target {
            case .message(let primary):
                guard let message = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary) else {
                    return [("Conversation".localizeString(id: "report_metadata_conversation", arguments: []), jid)]
                }
                var rows = commonRows(conversationJid: message.opponent, roomJid: message.conversationType == .group ? message.opponent : nil)
                if message.conversationType == .group {
                    if let author = message.groupchatMetadata?["jid"] as? String ?? message.groupchatAuthorId {
                        rows.append(("Reported user JID".localizeString(id: "report_metadata_reported_user_jid", arguments: []), author))
                    }
                } else if !message.outgoing {
                    rows.append(("Reported user JID".localizeString(id: "report_metadata_reported_user_jid", arguments: []), message.opponent))
                }
                rows.append(("Conversation".localizeString(id: "report_metadata_conversation", arguments: []), message.opponent))
                rows.append(("Message timestamp".localizeString(id: "report_metadata_message_timestamp", arguments: []), DateFormatter.localizedString(from: message.date, dateStyle: .medium, timeStyle: .short)))
                if message.messageId.isNotEmpty {
                    rows.append(("Message ID".localizeString(id: "report_metadata_message_id", arguments: []), message.messageId))
                }
                if message.archivedId.isNotEmpty {
                    rows.append(("Stanza ID".localizeString(id: "report_metadata_stanza_id", arguments: []), message.archivedId))
                }
                let preview = message.displayedBody()
                if preview.isNotEmpty {
                    rows.append(("Message preview".localizeString(id: "report_metadata_message_preview", arguments: []), preview))
                }
                return rows
            case .media(let messagePrimary, let referencePrimary, let attachmentPrimary):
                let reference = referencePrimary.flatMap { realm.object(ofType: MessageReferenceStorageItem.self, forPrimaryKey: $0) }
                let attachment = attachmentPrimary.flatMap { realm.object(ofType: MessageMediaAttachmentStorageItem.self, forPrimaryKey: $0) }
                let resolvedMessagePrimary = messagePrimary ?? reference?.messageId ?? attachment?.messagePrimary
                let message = resolvedMessagePrimary.flatMap { realm.object(ofType: MessageStorageItem.self, forPrimaryKey: $0) }
                var rows = commonRows(conversationJid: message?.opponent ?? attachment?.jid ?? jid, roomJid: conversationType == .group ? jid : nil)
                rows.append(("Conversation".localizeString(id: "report_metadata_conversation", arguments: []), message?.opponent ?? attachment?.jid ?? jid))
                if let primary = reference?.primary ?? attachment?.primary {
                    rows.append(("Attachment ID".localizeString(id: "report_metadata_attachment_id", arguments: []), primary))
                }
                if let kind = reference?.kind.rawValue ?? attachment?.kind.rawValue, kind.isNotEmpty {
                    rows.append(("Media type".localizeString(id: "report_metadata_media_type", arguments: []), kind))
                }
                if let mimeType = reference?.mimeType, mimeType.isNotEmpty {
                    rows.append(("MIME type".localizeString(id: "report_metadata_mime_type", arguments: []), mimeType))
                }
                if let filename = reference?.filename ?? reference?.name ?? attachment?.filename, filename.isNotEmpty {
                    rows.append(("File name".localizeString(id: "report_metadata_file_name", arguments: []), filename))
                }
                return rows
            case .user(let reportedUserJid, let roomJid):
                var rows = commonRows(conversationJid: roomJid ?? reportedUserJid, roomJid: roomJid)
                rows.append(("Reported user JID".localizeString(id: "report_metadata_reported_user_jid", arguments: []), reportedUserJid))
                return rows
            case .room(let roomJid):
                var rows = commonRows(conversationJid: roomJid, roomJid: roomJid)
                rows.append(("Room JID".localizeString(id: "report_metadata_room_jid", arguments: []), roomJid))
                return rows
            }
        } catch {
            DDLogDebug("AbuseReportViewController: \(#function). \(error.localizedDescription)")
            return []
        }
    }

    private func commonRows(conversationJid: String, roomJid: String?) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let domain = XMPPJID(string: roomJid ?? conversationJid)?.domain {
            rows.append(("Server domain".localizeString(id: "report_metadata_server_domain", arguments: []), domain))
        }
        if let roomJid = roomJid, roomJid.isNotEmpty {
            rows.append(("Room JID".localizeString(id: "report_metadata_room_jid", arguments: []), roomJid))
        }
        rows.append(("Reporter account".localizeString(id: "report_metadata_reporter_account", arguments: []), owner))
        return rows
    }

    private func makeReport(reason: ReportReason) -> ModerationReport? {
        guard let target = effectiveTarget else {
            return nil
        }
        do {
            let realm = try WRealm.safe()
            switch target {
            case .message(let primary):
                guard let message = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary) else {
                    return nil
                }
                return ModerationReportFactory.messageReport(
                    message: message,
                    reason: reason,
                    comment: comment,
                    includeMessageExcerpt: includeMessageExcerpt
                )
            case .media(let messagePrimary, let referencePrimary, let attachmentPrimary):
                let reference = referencePrimary.flatMap { realm.object(ofType: MessageReferenceStorageItem.self, forPrimaryKey: $0) }
                let attachment = attachmentPrimary.flatMap { realm.object(ofType: MessageMediaAttachmentStorageItem.self, forPrimaryKey: $0) }
                let resolvedMessagePrimary = messagePrimary ?? reference?.messageId ?? attachment?.messagePrimary
                let message = resolvedMessagePrimary.flatMap { realm.object(ofType: MessageStorageItem.self, forPrimaryKey: $0) }
                return ModerationReportFactory.mediaReport(
                    message: message,
                    reference: reference,
                    attachment: attachment,
                    owner: owner,
                    conversationJid: message?.opponent ?? attachment?.jid ?? jid,
                    conversationType: conversationType,
                    reason: reason,
                    comment: comment,
                    includeMessageExcerpt: false
                )
            case .user(let reportedUserJid, let roomJid):
                return ModerationReportFactory.userReport(
                    owner: owner,
                    reportedUserJid: reportedUserJid,
                    roomJid: roomJid,
                    conversationId: roomJid ?? jid,
                    reason: reason,
                    comment: comment
                )
            case .room(let roomJid):
                return ModerationReportFactory.roomReport(owner: owner, roomJid: roomJid, reason: reason, comment: comment)
            }
        } catch {
            DDLogDebug("AbuseReportViewController: \(#function). \(error.localizedDescription)")
            return nil
        }
    }

    private func updateSubmitState() {
        submitButton.isEnabled = selectedReason != nil && !isSubmitting
    }

    private func messageForFailure(_ state: ModerationReportSubmissionState) -> String {
        switch state {
        case .missingConfiguration:
            return "Report submission is not configured. Please contact support at %@."
                .localizeString(id: "report_error_missing_configuration", arguments: [ModerationReportConfiguration.supportEmail])
        case .networkError:
            return "Report could not be submitted. Please check your connection and try again."
                .localizeString(id: "report_error_network", arguments: [])
        case .serverError:
            return "Report could not be submitted due to a server error. Please try again later or contact support at %@."
                .localizeString(id: "report_error_server", arguments: [ModerationReportConfiguration.supportEmail])
        case .validationError:
            return "Please select a reason before submitting your report."
                .localizeString(id: "report_error_validation", arguments: [])
        case .success:
            return ""
        }
    }

    private func successMessage(for report: ModerationReport) -> String {
        if ModerationReportConfiguration.isDeveloperOperated(serverDomain: report.serverDomain) {
            return "Report submitted. Thank you for helping keep the service safe. Reports for developer-operated services are reviewed within 24 hours."
                .localizeString(id: "report_success_developer_operated", arguments: [])
        }
        return "Report submitted. Because this server may be operated by a third party, moderation actions may depend on the server operator."
            .localizeString(id: "report_success_third_party", arguments: [])
    }

    @objc private func onCancel() {
        dismiss(animated: true)
    }

    @objc private func onSubmit() {
        guard let reason = selectedReason else {
            view.makeToast(messageForFailure(.validationError), danger: true)
            return
        }
        guard let report = makeReport(reason: reason) else {
            view.makeToast("Internal error".localizeString(id: "message_manager_error_internal", arguments: []), danger: true)
            return
        }
        guard let account = AccountManager.shared.find(for: owner) else {
            ModerationReportLocalStateWriter.record(report: report, state: .failed, hideLocally: false)
            view.makeToast(messageForFailure(.networkError), danger: true)
            return
        }
        isSubmitting = true
        updateSubmitState()
        ModerationReportLocalStateWriter.record(report: report, state: .pending, hideLocally: false)
        account.action { [weak self] user, stream in
            user.abuse.report(stream, report: report) { state in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.isSubmitting = false
                    self.updateSubmitState()
                    switch state {
                    case .success:
                        ModerationReportLocalStateWriter.record(report: report, state: .submitted, hideLocally: self.hideLocally)
                        let message = self.successMessage(for: report)
                        self.dismiss(animated: true) {
                            ToastPresenter().presentSuccess(message: message)
                        }
                    default:
                        ModerationReportLocalStateWriter.record(report: report, state: .failed, hideLocally: false)
                        self.view.makeToast(self.messageForFailure(state), danger: true)
                    }
                }
            }
        }
    }
}

extension AbuseReportViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        return Section.allCases.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .explanation:
            return 1
        case .metadata:
            return metadataRows.count
        case .reasons:
            return ReportReason.allCases.count
        case .options:
            return options.count
        case .comment:
            return 1
        case .none:
            return 0
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .metadata:
            return metadataRows.isEmpty ? nil : "Details".localizeString(id: "report_section_details", arguments: [])
        case .reasons:
            return "Reason".localizeString(id: "report_section_reason", arguments: [])
        case .options:
            return options.isEmpty ? nil : "Options".localizeString(id: "report_section_options", arguments: [])
        case .comment:
            return "Additional details".localizeString(id: "report_section_comment", arguments: [])
        default:
            return nil
        }
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard Section(rawValue: section) == .options,
              conversationType.isEncrypted,
              options.contains(.includeExcerpt) else {
            return nil
        }
        return "Including the excerpt will submit the displayed decrypted message text for moderation review."
            .localizeString(id: "report_encrypted_excerpt_warning", arguments: [])
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section) {
        case .explanation:
            let cell = tableView.dequeueReusableCell(withIdentifier: "ReportCell", for: indexPath)
            var config = cell.defaultContentConfiguration()
            config.text = "Reports help us review objectionable content and abusive behavior. For developer-operated services, reports are reviewed within 24 hours. For third-party XMPP servers, moderation actions may depend on the server operator."
                .localizeString(id: "report_explanation", arguments: [])
            config.textProperties.font = UIFont.preferredFont(forTextStyle: .body)
            config.textProperties.adjustsFontForContentSizeCategory = true
            config.textProperties.numberOfLines = 0
            cell.contentConfiguration = config
            cell.selectionStyle = .none
            return cell
        case .metadata:
            let cell = tableView.dequeueReusableCell(withIdentifier: "ReportValueCell", for: indexPath)
            let row = metadataRows[indexPath.row]
            var config = cell.defaultContentConfiguration()
            config.text = row.title
            config.secondaryText = row.value
            config.textProperties.font = UIFont.preferredFont(forTextStyle: .body)
            config.secondaryTextProperties.font = UIFont.preferredFont(forTextStyle: .body)
            config.textProperties.adjustsFontForContentSizeCategory = true
            config.secondaryTextProperties.adjustsFontForContentSizeCategory = true
            config.secondaryTextProperties.color = .secondaryLabel
            config.prefersSideBySideTextAndSecondaryText = false
            cell.contentConfiguration = config
            cell.selectionStyle = .none
            return cell
        case .reasons:
            let reason = ReportReason.allCases[indexPath.row]
            let cell = tableView.dequeueReusableCell(withIdentifier: "ReportCell", for: indexPath)
            var config = cell.defaultContentConfiguration()
            config.text = reason.title
            config.textProperties.font = UIFont.preferredFont(forTextStyle: .body)
            config.textProperties.adjustsFontForContentSizeCategory = true
            cell.contentConfiguration = config
            cell.accessoryType = reason == selectedReason ? .checkmark : .none
            cell.accessibilityIdentifier = "report.reason.\(reason.rawValue)"
            cell.accessibilityTraits = [.button]
            return cell
        case .options:
            let option = options[indexPath.row]
            let cell = tableView.dequeueReusableCell(withIdentifier: "ReportCell", for: indexPath)
            var config = cell.defaultContentConfiguration()
            switch option {
            case .includeExcerpt:
                config.text = "Include message excerpt in report".localizeString(id: "report_include_excerpt", arguments: [])
                config.image = UIImage(systemName: includeMessageExcerpt ? "checkmark.square.fill" : "square")
                cell.accessibilityIdentifier = "report.include_excerpt"
                cell.accessibilityValue = includeMessageExcerpt ? "Selected" : "Not selected"
            case .hideLocally:
                config.text = "Hide this content locally".localizeString(id: "report_hide_locally", arguments: [])
                config.image = UIImage(systemName: hideLocally ? "checkmark.square.fill" : "square")
                cell.accessibilityIdentifier = "report.hide_locally"
                cell.accessibilityValue = hideLocally ? "Selected" : "Not selected"
            }
            config.textProperties.font = UIFont.preferredFont(forTextStyle: .body)
            config.textProperties.adjustsFontForContentSizeCategory = true
            config.textProperties.numberOfLines = 0
            config.imageProperties.tintColor = .tintColor
            cell.contentConfiguration = config
            cell.accessibilityTraits = [.button]
            return cell
        case .comment:
            guard let cell = tableView.dequeueReusableCell(withIdentifier: CommentCell.cellName, for: indexPath) as? CommentCell else {
                fatalError()
            }
            cell.configure(
                text: comment,
                placeholder: "Optional extra details".localizeString(id: "report_comment_placeholder", arguments: [])
            )
            cell.onChange = { [weak self] text in
                self?.comment = text
            }
            return cell
        case .none:
            return UITableViewCell()
        }
    }
}

extension AbuseReportViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Section(rawValue: indexPath.section) {
        case .reasons:
            selectedReason = ReportReason.allCases[indexPath.row]
            updateSubmitState()
            tableView.reloadSections(IndexSet(integer: indexPath.section), with: .none)
        case .options:
            switch options[indexPath.row] {
            case .includeExcerpt:
                includeMessageExcerpt.toggle()
            case .hideLocally:
                hideLocally.toggle()
            }
            tableView.reloadRows(at: [indexPath], with: .none)
        default:
            break
        }
    }
}
