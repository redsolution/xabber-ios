//
//  XMPPAbuseManager.swift
//  xabber
//
//  Created by Игорь Болдин on 13.02.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import XMPPFramework
import RealmSwift
import CocoaLumberjack

enum ReportTargetType: String, Codable, CaseIterable {
    case message
    case media
    case user
    case room
}

enum ReportReason: String, Codable, CaseIterable {
    case harassmentOrBullying
    case hateSpeech
    case sexualContentOrNudity
    case violenceOrThreats
    case spamScamOrPhishing
    case illegalContent
    case impersonation
    case sharingPrivateInformation
    case other

    var title: String {
        switch self {
        case .harassmentOrBullying:
            return "Harassment or bullying".localizeString(id: "report_reason_harassment_or_bullying", arguments: [])
        case .hateSpeech:
            return "Hate speech".localizeString(id: "report_reason_hate_speech", arguments: [])
        case .sexualContentOrNudity:
            return "Sexual content or nudity".localizeString(id: "report_reason_sexual_content_or_nudity", arguments: [])
        case .violenceOrThreats:
            return "Violence or threats".localizeString(id: "report_reason_violence_or_threats", arguments: [])
        case .spamScamOrPhishing:
            return "Spam, scam, or phishing".localizeString(id: "report_reason_spam_scam_or_phishing", arguments: [])
        case .illegalContent:
            return "Illegal content".localizeString(id: "report_reason_illegal_content", arguments: [])
        case .impersonation:
            return "Impersonation".localizeString(id: "report_reason_impersonation", arguments: [])
        case .sharingPrivateInformation:
            return "Sharing private information".localizeString(id: "report_reason_sharing_private_information", arguments: [])
        case .other:
            return "Other".localizeString(id: "report_reason_other", arguments: [])
        }
    }
}

enum ModerationReportSubmissionState: Equatable {
    case success
    case missingConfiguration
    case networkError
    case serverError
    case validationError
}

enum ModerationLocalReportState: String {
    case pending
    case submitted
    case failed
}

struct ModerationReport: Codable {
    let reportId: String
    let createdAt: Date
    let reporterAccountJid: String?
    let reporterInstallationId: String?
    let reportedUserJid: String?
    let serverDomain: String?
    let roomJid: String?
    let conversationId: String?
    let messageId: String?
    let stanzaId: String?
    let messageTimestamp: Date?
    let messageKind: String?
    let attachmentId: String?
    let mediaType: String?
    let mimeType: String?
    let mediaUrlHashOrIdentifier: String?
    let reportTargetType: ReportTargetType
    let reason: ReportReason
    let comment: String?
    let includeMessageExcerpt: Bool
    let messageExcerpt: String?
    let appVersion: String
    let platform: String
    let osVersion: String
    let locale: String?

    var jsonString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    var abuseMessageBody: String {
        var lines: [String] = [
            "Moderation report",
            ""
        ]

        append("Target type", reportTargetType.bodyTitle, to: &lines)
        append("Reported user JID", reportedUserJid, to: &lines)
        append("Reporter account JID", reporterAccountJid, to: &lines)
        append("Room JID", roomJid, to: &lines)
        append("Conversation ID", conversationId, to: &lines)
        append("Server domain", serverDomain, to: &lines)
        append("Message ID", messageId, to: &lines)
        append("Stanza ID", stanzaId, to: &lines)
        append("Message timestamp", messageTimestamp.map(Self.isoDateFormatter.string(from:)), to: &lines)
        append("Message kind", messageKind, to: &lines)
        append("Attachment ID", attachmentId, to: &lines)
        append("Media type", mediaType, to: &lines)
        append("MIME type", mimeType, to: &lines)
        append("Media identifier", mediaUrlHashOrIdentifier, to: &lines)
        append("Reason", reason.bodyTitle, to: &lines)
        append("Created at", Self.isoDateFormatter.string(from: createdAt), to: &lines)
        append("Platform", "\(platform) \(osVersion)".trimmingCharacters(in: .whitespacesAndNewlines), to: &lines)
        append("App version", appVersion, to: &lines)
        append("Locale", locale, to: &lines)
        append("Report ID", reportId, to: &lines)

        if let messageExcerpt = messageExcerpt?.trimmingCharacters(in: .whitespacesAndNewlines), messageExcerpt.isNotEmpty {
            lines.append("")
            lines.append("Message excerpt:")
            lines.append(messageExcerpt)
        }

        if let comment = comment?.trimmingCharacters(in: .whitespacesAndNewlines), comment.isNotEmpty {
            lines.append("")
            lines.append("Reporter comment:")
            lines.append(comment)
        }

        return lines.joined(separator: "\n")
    }

    private static let isoDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private func append(_ label: String, _ value: String?, to lines: inout [String]) {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), value.isNotEmpty else {
            return
        }
        lines.append("\(label): \(value)")
    }
}

private extension ReportTargetType {
    var bodyTitle: String {
        switch self {
        case .message:
            return "Message"
        case .media:
            return "Media"
        case .user:
            return "User"
        case .room:
            return "Room"
        }
    }
}

private extension ReportReason {
    var bodyTitle: String {
        switch self {
        case .harassmentOrBullying:
            return "Harassment or bullying"
        case .hateSpeech:
            return "Hate speech"
        case .sexualContentOrNudity:
            return "Sexual content or nudity"
        case .violenceOrThreats:
            return "Violence or threats"
        case .spamScamOrPhishing:
            return "Spam, scam, or phishing"
        case .illegalContent:
            return "Illegal content"
        case .impersonation:
            return "Impersonation"
        case .sharingPrivateInformation:
            return "Sharing private information"
        case .other:
            return "Other"
        }
    }
}

struct ModerationReportConfiguration {
    static var configuredSubmissionAddress: String? {
        let report = CommonConfigManager.shared.config.default_report_address.trimmingCharacters(in: .whitespacesAndNewlines)
        if report.isNotEmpty {
            return report
        }
        let support = CommonConfigManager.shared.config.support_jid.trimmingCharacters(in: .whitespacesAndNewlines)
        return support.isNotEmpty ? support : nil
    }

    static var supportEmail: String {
        return configuredSubmissionAddress ?? "support@xabber.com"
    }

    static var developerOperatedDomains: [String] {
        var domains = CommonConfigManager.shared.config.developer_operated_xmpp_domains ?? []
        domains.append(contentsOf: CommonConfigManager.shared.config.allowed_hosts)
        domains.append(CommonConfigManager.shared.config.locked_host)
        domains.append(CommonConfigManager.shared.config.domain)
        if let reportDomain = XMPPJID(string: supportEmail)?.domain {
            domains.append(reportDomain)
        }
        return Array(Set(domains
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { $0.isNotEmpty }))
    }

    static func isDeveloperOperated(serverDomain: String?) -> Bool {
        guard let serverDomain = serverDomain?.lowercased(), serverDomain.isNotEmpty else {
            return false
        }
        return developerOperatedDomains.contains(serverDomain)
    }
}

struct ModerationReportFactory {
    static func reporterInstallationId() -> String {
        let key = "moderation_reporter_installation_id"
        let defaults = UserDefaults(suiteName: CredentialsManager.uniqueAccessGroup()) ?? .standard
        if let value = defaults.string(forKey: key), value.isNotEmpty {
            return value
        }
        let value = UUID().uuidString
        defaults.set(value, forKey: key)
        return value
    }

    static func messageReport(
        message: MessageStorageItem,
        reason: ReportReason,
        comment: String?,
        includeMessageExcerpt: Bool
    ) -> ModerationReport {
        let reportedUserJid: String?
        let roomJid: String?
        if message.conversationType == .group {
            reportedUserJid = message.groupchatMetadata?["jid"] as? String ?? message.groupchatAuthorId
            roomJid = message.opponent
        } else {
            reportedUserJid = message.outgoing ? nil : message.opponent
            roomJid = nil
        }
        return baseReport(
            targetType: .message,
            owner: message.owner,
            reportedUserJid: reportedUserJid,
            serverDomain: domain(for: roomJid ?? reportedUserJid ?? message.opponent),
            roomJid: roomJid,
            conversationId: message.opponent,
            messageId: message.messageId,
            stanzaId: message.archivedId.isNotEmpty ? message.archivedId : nil,
            messageTimestamp: message.date,
            messageKind: message.messageType,
            attachmentId: nil,
            mediaType: nil,
            mimeType: nil,
            mediaUrlHashOrIdentifier: nil,
            reason: reason,
            comment: comment,
            includeMessageExcerpt: includeMessageExcerpt,
            messageExcerpt: includeMessageExcerpt ? message.displayedBody() : nil
        )
    }

    static func mediaReport(
        message: MessageStorageItem?,
        reference: MessageReferenceStorageItem?,
        attachment: MessageMediaAttachmentStorageItem?,
        owner: String,
        conversationJid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        reason: ReportReason,
        comment: String?,
        includeMessageExcerpt: Bool
    ) -> ModerationReport {
        let reportedUserJid: String?
        let roomJid: String?
        if conversationType == .group {
            reportedUserJid = message?.groupchatMetadata?["jid"] as? String ?? message?.groupchatAuthorId
            roomJid = conversationJid
        } else {
            reportedUserJid = conversationJid
            roomJid = nil
        }
        let mediaUrl = reference?.url ?? attachment?.url_ ?? reference?.downloadUrl?.absoluteString ?? attachment?.url?.absoluteString
        return baseReport(
            targetType: .media,
            owner: owner,
            reportedUserJid: reportedUserJid,
            serverDomain: domain(for: roomJid ?? reportedUserJid ?? conversationJid),
            roomJid: roomJid,
            conversationId: conversationJid,
            messageId: message?.messageId ?? reference?.messageId,
            stanzaId: message?.archivedId.isNotEmpty == true ? message?.archivedId : attachment?.archiveId,
            messageTimestamp: message?.date ?? attachment?.date,
            messageKind: message?.messageType,
            attachmentId: reference?.primary ?? attachment?.primary,
            mediaType: reference?.kind.rawValue ?? attachment?.kind.rawValue,
            mimeType: reference?.mimeType,
            mediaUrlHashOrIdentifier: mediaIdentifier(for: mediaUrl, fallback: reference?.filehash ?? reference?.fileID.map { "\($0)" }),
            reason: reason,
            comment: comment,
            includeMessageExcerpt: includeMessageExcerpt,
            messageExcerpt: includeMessageExcerpt ? message?.displayedBody() : nil
        )
    }

    static func userReport(
        owner: String,
        reportedUserJid: String,
        roomJid: String?,
        conversationId: String?,
        reason: ReportReason,
        comment: String?
    ) -> ModerationReport {
        baseReport(
            targetType: .user,
            owner: owner,
            reportedUserJid: reportedUserJid,
            serverDomain: domain(for: roomJid ?? reportedUserJid),
            roomJid: roomJid,
            conversationId: conversationId,
            messageId: nil,
            stanzaId: nil,
            messageTimestamp: nil,
            messageKind: nil,
            attachmentId: nil,
            mediaType: nil,
            mimeType: nil,
            mediaUrlHashOrIdentifier: nil,
            reason: reason,
            comment: comment,
            includeMessageExcerpt: false,
            messageExcerpt: nil
        )
    }

    static func roomReport(owner: String, roomJid: String, reason: ReportReason, comment: String?) -> ModerationReport {
        baseReport(
            targetType: .room,
            owner: owner,
            reportedUserJid: nil,
            serverDomain: domain(for: roomJid),
            roomJid: roomJid,
            conversationId: roomJid,
            messageId: nil,
            stanzaId: nil,
            messageTimestamp: nil,
            messageKind: nil,
            attachmentId: nil,
            mediaType: nil,
            mimeType: nil,
            mediaUrlHashOrIdentifier: nil,
            reason: reason,
            comment: comment,
            includeMessageExcerpt: false,
            messageExcerpt: nil
        )
    }

    static func domain(for jid: String?) -> String? {
        guard let jid = jid, jid.isNotEmpty else { return nil }
        return XMPPJID(string: jid)?.domain
    }

    private static func mediaIdentifier(for url: String?, fallback: String?) -> String? {
        if let fallback = fallback, fallback.isNotEmpty {
            return fallback
        }
        guard let url = url, url.isNotEmpty else {
            return nil
        }
        return url.sha256Data.hexEncodedString()
    }

    private static func baseReport(
        targetType: ReportTargetType,
        owner: String,
        reportedUserJid: String?,
        serverDomain: String?,
        roomJid: String?,
        conversationId: String?,
        messageId: String?,
        stanzaId: String?,
        messageTimestamp: Date?,
        messageKind: String?,
        attachmentId: String?,
        mediaType: String?,
        mimeType: String?,
        mediaUrlHashOrIdentifier: String?,
        reason: ReportReason,
        comment: String?,
        includeMessageExcerpt: Bool,
        messageExcerpt: String?
    ) -> ModerationReport {
        return ModerationReport(
            reportId: UUID().uuidString,
            createdAt: Date(),
            reporterAccountJid: owner.isNotEmpty ? owner : nil,
            reporterInstallationId: reporterInstallationId(),
            reportedUserJid: reportedUserJid,
            serverDomain: serverDomain,
            roomJid: roomJid,
            conversationId: conversationId,
            messageId: messageId,
            stanzaId: stanzaId,
            messageTimestamp: messageTimestamp,
            messageKind: messageKind,
            attachmentId: attachmentId,
            mediaType: mediaType,
            mimeType: mimeType,
            mediaUrlHashOrIdentifier: mediaUrlHashOrIdentifier,
            reportTargetType: targetType,
            reason: reason,
            comment: comment?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            includeMessageExcerpt: includeMessageExcerpt,
            messageExcerpt: messageExcerpt?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            appVersion: getAppVersion(),
            platform: "iOS",
            osVersion: UIDevice.current.systemVersion,
            locale: Locale.current.identifier
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        return isEmpty ? nil : self
    }
}

class XMPPAbuseManager: AbstractXMPPManager {
    enum ManagerErrorType: Error {
        case notAvailable
    }
    
    static let xmlns: String = "urn:xabber:favorites:0"
    
    open var node: String? = nil
    
    var defaultAdress: String = ModerationReportConfiguration.configuredSubmissionAddress ?? ""
    
    override func namespaces() -> [String] {
        return [
            XMPPAbuseManager.xmlns
        ]
    }
    
    override func getPrimaryNamespace() -> String {
        return XMPPFavoritesManager.xmlns
    }
    
    override init(withOwner owner: String) {
        super.init(withOwner: owner)
        loadLocal()
    }
    
    private func loadLocal() {
        
    }
    
    public func register(address: String, for owner: String, isGroup: Bool) {
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: XMPPAbuseConfigStorageItem.self, forPrimaryKey: XMPPAbuseConfigStorageItem.genPrimary(owner: owner)) {
                try realm.write {
                    instance.updateAt = Date()
                }
            } else {
                let instance = XMPPAbuseConfigStorageItem()
                instance.owner = owner
                instance.abuseAddress = address
                instance.group = isGroup
                instance.primary = XMPPAbuseConfigStorageItem.genPrimary(owner: owner)
                instance.updateAt = Date()
                try realm.write {
                    realm.add(instance)
                }
            }
        } catch {
            DDLogDebug("XMPPAbuseManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    public func report(_ xmppStream: XMPPStream, message primary: String, reason: String) {
        do {
            let realm = try WRealm.safe()
            if let messageInstance = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary) {
                let report = ModerationReportFactory.messageReport(
                    message: messageInstance,
                    reason: .other,
                    comment: reason,
                    includeMessageExcerpt: false
                )
                self.report(xmppStream, report: report, completion: nil)
            }
        } catch {
            DDLogDebug("XMPPAbuseManager: \(#function). \(error.localizedDescription)")
        }
    }

    public func report(_ xmppStream: XMPPStream, report: ModerationReport, completion: ((ModerationReportSubmissionState) -> Void)?) {
        guard report.reason.rawValue.isNotEmpty else {
            completion?(.validationError)
            return
        }
        guard let abuseJid = abuseAddress(for: report), abuseJid.isNotEmpty else {
            completion?(.missingConfiguration)
            return
        }
        guard xmppStream.isAuthenticated else {
            completion?(.networkError)
            return
        }
        guard let account = AccountManager.shared.find(for: self.owner) else {
            completion?(.networkError)
            return
        }
        _ = account
            .messages
            .sendSimpleMessage(report.abuseMessageBody, to: abuseJid, forwarded: [], conversationType: .regular, isReport: true)
        completion?(.success)
    }

    private func abuseAddress(for report: ModerationReport) -> String? {
        do {
            let realm = try WRealm.safe()
            let key = report.roomJid ?? report.conversationId ?? report.reporterAccountJid ?? self.owner
            let configured = realm.object(ofType: XMPPAbuseConfigStorageItem.self, forPrimaryKey: key)?.abuseAddress
            if let configured = configured, configured.trimmingCharacters(in: .whitespacesAndNewlines).isNotEmpty {
                return configured
            }
            let fallback = defaultAdress.trimmingCharacters(in: .whitespacesAndNewlines)
            if fallback.isNotEmpty {
                return fallback
            }
            let support = CommonConfigManager.shared.config.support_jid.trimmingCharacters(in: .whitespacesAndNewlines)
            return support.isNotEmpty ? support : nil
        } catch {
            DDLogDebug("XMPPAbuseManager: \(#function). \(error.localizedDescription)")
            return defaultAdress.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
    }
}

struct ModerationReportLocalStateWriter {
    static func record(report: ModerationReport, state: ModerationLocalReportState, hideLocally: Bool) {
        do {
            let realm = try WRealm.safe()
            try realm.write {
                let item = XMPPAbuseReportStorageItem()
                item.primary = report.reportId
                item.reportId = report.reportId
                item.createdAt = report.createdAt
                item.owner = report.reporterAccountJid ?? ""
                item.jid = report.conversationId ?? report.reportedUserJid ?? report.roomJid ?? ""
                item.conversationType_ = ""
                item.abuseAddress = ModerationReportConfiguration.supportEmail
                item.messageId = report.messageId ?? ""
                item.targetType = report.reportTargetType.rawValue
                item.reason = report.reason.rawValue
                item.comment = report.comment
                item.state = state.rawValue
                item.includeMessageExcerpt = report.includeMessageExcerpt
                item.messageExcerpt = report.messageExcerpt
                item.payload = report.jsonString
                realm.add(item, update: .modified)

                applyLocalState(report: report, state: state, hideLocally: hideLocally, realm: realm)
            }
        } catch {
            DDLogDebug("ModerationReportLocalStateWriter: \(#function). \(error.localizedDescription)")
        }
    }

    private static func applyLocalState(report: ModerationReport, state: ModerationLocalReportState, hideLocally: Bool, realm: Realm) {
        let now = Date()
        if let messageId = report.messageId,
           let message = realm.objects(MessageStorageItem.self)
            .filter("owner == %@ AND messageId == %@", report.reporterAccountJid ?? "", messageId)
            .first {
            message.localReportState = state.rawValue
            message.lastReportedAt = now
            message.lastReportReason = report.reason.rawValue
            message.reportCount += 1
            if hideLocally && report.reportTargetType == .message {
                message.isLocallyHiddenByReport = true
                message.queryIds = "\(message.queryIds ?? "") report_hidden_\(now.timeIntervalSince1970)"
            }
        }

        if let attachmentId = report.attachmentId {
            if let reference = realm.object(ofType: MessageReferenceStorageItem.self, forPrimaryKey: attachmentId) {
                reference.localReportState = state.rawValue
                reference.lastReportedAt = now
                reference.lastReportReason = report.reason.rawValue
                reference.reportCount += 1
                if hideLocally {
                    reference.isLocallyHiddenByReport = true
                }
                if let message = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: reference.messageId) {
                    message.localReportState = state.rawValue
                    message.lastReportedAt = now
                    message.lastReportReason = report.reason.rawValue
                    message.reportCount += 1
                    message.queryIds = "\(message.queryIds ?? "") report_media_\(now.timeIntervalSince1970)"
                }
                if hideLocally,
                   let url = reference.url ?? reference.downloadUrl?.absoluteString {
                    realm.objects(MessageMediaAttachmentStorageItem.self)
                        .filter("owner == %@ AND messagePrimary == %@ AND url_ == %@", reference.owner, reference.messageId, url)
                        .forEach { attachment in
                            attachment.isLocallyHiddenByReport = true
                            attachment.localReportState = state.rawValue
                            attachment.lastReportedAt = now
                            attachment.lastReportReason = report.reason.rawValue
                            attachment.reportCount += 1
                        }
                }
            }
            if let attachment = realm.object(ofType: MessageMediaAttachmentStorageItem.self, forPrimaryKey: attachmentId) {
                attachment.localReportState = state.rawValue
                attachment.lastReportedAt = now
                attachment.lastReportReason = report.reason.rawValue
                attachment.reportCount += 1
                if hideLocally {
                    attachment.isLocallyHiddenByReport = true
                }
                if hideLocally,
                   let message = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: attachment.messagePrimary) {
                    message.references
                        .filter { $0.url == attachment.url_ || $0.downloadUrl?.absoluteString == attachment.url_ }
                        .forEach { $0.isLocallyHiddenByReport = true }
                    message.queryIds = "\(message.queryIds ?? "") report_media_\(now.timeIntervalSince1970)"
                }
            }
        }
    }
}
