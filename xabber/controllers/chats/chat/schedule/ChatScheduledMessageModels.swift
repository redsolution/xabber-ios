//
//  ChatScheduledMessageModels.swift
//  xabber
//
//  Created by Codex on 15.06.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import Foundation
import RealmSwift
import UIKit
import XMPPFramework

struct ChatScheduleActionContext: Equatable {
    let scheduleAvailable: Bool
    let isEditingMessage: Bool
    let hasRecordedAudio: Bool
    let hasUnsupportedMediaAttachment: Bool
    let conversationType: ClientSynchronizationManager.ConversationType
    var omemo2Ready: Bool = false
}

enum ChatSendOptionsDisabledReason: Equatable {
    case silentSendUnsupported
    case scheduleUnavailable
    case editingMessage
    case unsupportedMedia
    case encryptedConversation
}

struct ChatSendOptionState: Equatable {
    let isEnabled: Bool
    let disabledReason: ChatSendOptionsDisabledReason?
}

struct ChatSendOptionsMenuState: Equatable {
    let sendWithoutSound: ChatSendOptionState
    let schedule: ChatSendOptionState
}

enum ChatSendOptionsMenuPolicy {
    static func shouldPresentTextSendMenu(
        actionMode: ModernXabberInputView.ComposerActionMode,
        inputState: ModernXabberInputView.InputBarState,
        isSendButtonEnabled: Bool,
        body: String
    ) -> Bool {
        guard actionMode == .textSend,
              inputState == .normal,
              isSendButtonEnabled else {
            return false
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines).isNotEmpty
    }

    static func makeMenuState(scheduleContext: ChatScheduleActionContext) -> ChatSendOptionsMenuState {
        ChatSendOptionsMenuState(
            sendWithoutSound: ChatSendOptionState(
                isEnabled: false,
                disabledReason: .silentSendUnsupported
            ),
            schedule: scheduleState(for: scheduleContext)
        )
    }

    private static func scheduleState(for context: ChatScheduleActionContext) -> ChatSendOptionState {
        if !context.scheduleAvailable {
            return ChatSendOptionState(isEnabled: false, disabledReason: .scheduleUnavailable)
        }
        if context.isEditingMessage {
            return ChatSendOptionState(isEnabled: false, disabledReason: .editingMessage)
        }
        if context.hasRecordedAudio || context.hasUnsupportedMediaAttachment {
            return ChatSendOptionState(isEnabled: false, disabledReason: .unsupportedMedia)
        }
        if context.conversationType.isEncrypted && (context.conversationType != .omemo || !context.omemo2Ready) {
            return ChatSendOptionState(isEnabled: false, disabledReason: .encryptedConversation)
        }
        return ChatSendOptionState(isEnabled: true, disabledReason: nil)
    }
}

enum ChatSendOptionsContextMenuBuilder {
    static let sendWithoutSoundValue = "send_without_sound"
    static let scheduleValue = "schedule_message"

    static func configure(_ menu: ContextMenu) {
        menu.MenuConstants.verticalPlacement = .aboveTarget
        menu.MenuConstants.horizontalDirection = .right
        menu.MenuConstants.MenuWidth = 250
        menu.MenuConstants.ItemDefaultHeight = 44
        menu.MenuConstants.MenuMarginSpace = 10
        menu.MenuConstants.HorizontalMarginSpace = 16
        menu.MenuConstants.MenuCornerRadius = 12
        menu.MenuConstants.BlurEffectEnabled = true
        menu.MenuConstants.BlurEffectDefault = UIBlurEffect(style: .regular)
        menu.MenuConstants.targetedViewShadowEnabled = false
        menu.MenuConstants.roundedTargetSnapshotRadius = NativeGlassBarStyle.cornerRadius
    }

    static func makeItems(menuState: ChatSendOptionsMenuState) -> [[ContextMenuItem]] {
        [[
            ContextMenuItemWithImage(
                title: "Send Without Sound".localizeString(id: "send_without_sound_action", arguments: []),
                image: UIImage(systemName: "bell.slash"),
                value: sendWithoutSoundValue,
                danger: false,
                isEnabled: menuState.sendWithoutSound.isEnabled
            ),
            ContextMenuItemWithImage(
                title: "Schedule Message".localizeString(id: "schedule_message_action", arguments: []),
                image: UIImage(systemName: "calendar.badge.clock") ?? UIImage(systemName: "clock"),
                value: scheduleValue,
                danger: false,
                isEnabled: menuState.schedule.isEnabled
            )
        ]]
    }

    static func handleSelection(_ value: String, onSchedule: () -> Void) -> Bool {
        guard value == scheduleValue else {
            return false
        }
        onSchedule()
        return true
    }
}

struct ScheduledMessageDatePolicy {
    let calendar: Calendar
    let locale: Locale
    let timeZone: TimeZone

    init(
        calendar: Calendar = Calendar.current,
        locale: Locale = Locale.current,
        timeZone: TimeZone = TimeZone.current
    ) {
        var calendar = calendar
        calendar.timeZone = timeZone
        self.calendar = calendar
        self.locale = locale
        self.timeZone = timeZone
    }

    func minimumDate(now: Date = Date()) -> Date {
        now.addingTimeInterval(60)
    }

    func canConfirm(_ selectedDate: Date, now: Date = Date()) -> Bool {
        selectedDate >= minimumDate(now: now)
    }

    func normalizedToMinute(_ date: Date) -> Date {
        calendar.dateInterval(of: .minute, for: date)?.start ?? date
    }

    func initialDate(preferred: Date?, now: Date) -> Date {
        let proposed = normalizedToMinute(preferred ?? now.addingTimeInterval(3600))
        guard !canConfirm(proposed, now: now) else { return proposed }
        let minimum = minimumDate(now: now)
        let minute = normalizedToMinute(minimum)
        return minute < minimum ? minute.addingTimeInterval(60) : minute
    }

    func countdown(for selectedDate: Date, now: Date) -> String {
        let seconds = selectedDate.timeIntervalSince(now)
        guard seconds > 0 else {
            return L10n.text("scheduled_message_due_now", fallback: "Due now")
        }
        let minutes = Int(seconds / 60)
        guard minutes > 0 else {
            return L10n.text("scheduled_message_under_minute", fallback: "In less than a minute")
        }

        let components: DateComponents
        switch minutes {
        case ..<60: components = DateComponents(minute: minutes)
        case ..<1440: components = DateComponents(hour: minutes / 60)
        case ..<43200: components = DateComponents(day: minutes / 1440)
        default: components = DateComponents(month: minutes / 43200)
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.dateTimeStyle = .numeric
        return formatter.localizedString(from: components)
    }

    func confirmTitle(for selectedDate: Date, now: Date = Date()) -> String {
        if calendar.isDate(selectedDate, inSameDayAs: now) {
            return "Send today at %@".localizeString(
                id: "schedule_send_today_at",
                arguments: [timeString(from: selectedDate)]
            )
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
           calendar.isDate(selectedDate, inSameDayAs: tomorrow) {
            return "Send tomorrow at %@".localizeString(
                id: "schedule_send_tomorrow_at",
                arguments: [timeString(from: selectedDate)]
            )
        }
        return "Send on %@".localizeString(
            id: "schedule_send_on",
            arguments: [dateTimeString(from: selectedDate)]
        )
    }

    private func timeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func dateTimeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

struct ChatScheduledMessageSendRequest: Equatable {
    let owner: String
    let conversation: String
    let conversationType: ClientSynchronizationManager.ConversationType
    let deliverAt: Date
    let body: String
    let references: [MessageReferenceStorageItem]
    let forwardedMessagePrimaries: [String]
    let groupMentionIntent: GroupMessageMentionIntent
    let groupMentionSenderRole: GroupMemberRole?
    let groupMentionAllCapabilityGranted: Bool

    init(
        owner: String, conversation: String, conversationType: ClientSynchronizationManager.ConversationType,
        deliverAt: Date, body: String, references: [MessageReferenceStorageItem], forwardedMessagePrimaries: [String],
        groupMentionIntent: GroupMessageMentionIntent = .absent, groupMentionSenderRole: GroupMemberRole? = nil,
        groupMentionAllCapabilityGranted: Bool = false
    ) {
        self.owner = owner
        self.conversation = conversation
        self.conversationType = conversationType
        self.deliverAt = deliverAt
        self.body = body
        self.references = references
        self.forwardedMessagePrimaries = forwardedMessagePrimaries
        self.groupMentionIntent = groupMentionIntent
        self.groupMentionSenderRole = groupMentionSenderRole
        self.groupMentionAllCapabilityGranted = groupMentionAllCapabilityGranted
    }

    static func == (lhs: ChatScheduledMessageSendRequest, rhs: ChatScheduledMessageSendRequest) -> Bool {
        lhs.owner == rhs.owner
            && lhs.conversation == rhs.conversation
            && lhs.conversationType == rhs.conversationType
            && lhs.deliverAt == rhs.deliverAt
            && lhs.body == rhs.body
            && lhs.forwardedMessagePrimaries == rhs.forwardedMessagePrimaries
            && lhs.groupMentionIntent == rhs.groupMentionIntent
            && lhs.groupMentionSenderRole == rhs.groupMentionSenderRole
            && lhs.groupMentionAllCapabilityGranted == rhs.groupMentionAllCapabilityGranted
            && lhs.references.map(\.primary) == rhs.references.map(\.primary)
    }
}

protocol ChatScheduledMessageServicing: AnyObject {
    func isScheduleAvailable(owner: String) -> Bool

    func validateOMEMO2ScheduleRoute(owner: String, conversation: String) -> XMPPMessageScheduleManager.ScheduleError?

    func scheduleOMEMO2Message(
        _ request: ChatScheduledMessageSendRequest,
        callback: @escaping XMPPMessageScheduleManager.ScheduleCallback
    )

    func scheduleOMEMO2PreparedMessage(
        _ payload: XMPPMessage, owner: String, conversation: String, deliverAt: Date,
        callback: @escaping XMPPMessageScheduleManager.ScheduleCallback
    )

    func validateScheduledAttachmentRoute(
        owner: String, conversation: String, conversationType: ClientSynchronizationManager.ConversationType
    ) -> XMPPMessageScheduleManager.ScheduleError?

    @discardableResult
    func schedulePlaintextMessage(
        _ request: ChatScheduledMessageSendRequest,
        callback: XMPPMessageScheduleManager.ScheduleCallback?
    ) -> String?

    @discardableResult
    func listScheduledMessages(
        owner: String,
        conversation: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        callback: XMPPMessageScheduleManager.ListCallback?
    ) -> String?

    @discardableResult
    func cancelScheduledMessage(
        owner: String,
        scheduledId: String,
        callback: XMPPMessageScheduleManager.CancelCallback?
    ) -> String?

    func validateScheduledAction(
        _ action: ScheduledMessageAction,
        on item: ScheduledMessageListItem
    ) -> XMPPMessageScheduleManager.ScheduleError?

    @discardableResult
    func schedulePreparedMessage(
        _ payload: XMPPMessage,
        for item: ScheduledMessageListItem,
        deliverAt: Date,
        callback: XMPPMessageScheduleManager.ScheduleCallback?
    ) -> String?

    @discardableResult
    func schedulePreparedMessage(
        _ payload: XMPPMessage,
        owner: String,
        conversation: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        deliverAt: Date,
        callback: XMPPMessageScheduleManager.ScheduleCallback?
    ) -> String?

    func sendScheduledMessageNow(
        _ payload: XMPPMessage,
        for item: ScheduledMessageListItem,
        completion: @escaping (Result<Void, XMPPMessageScheduleManager.ScheduleError>) -> Void
    )
}

extension ChatScheduledMessageServicing {
    func validateOMEMO2ScheduleRoute(owner: String, conversation: String) -> XMPPMessageScheduleManager.ScheduleError? {
        .forbidden
    }

    func scheduleOMEMO2Message(
        _ request: ChatScheduledMessageSendRequest,
        callback: @escaping XMPPMessageScheduleManager.ScheduleCallback
    ) {
        callback(.failure(.forbidden))
    }

    func scheduleOMEMO2PreparedMessage(
        _ payload: XMPPMessage, owner: String, conversation: String, deliverAt: Date,
        callback: @escaping XMPPMessageScheduleManager.ScheduleCallback
    ) {
        callback(.failure(.forbidden))
    }

    func validateScheduledAttachmentRoute(
        owner: String, conversation: String, conversationType: ClientSynchronizationManager.ConversationType
    ) -> XMPPMessageScheduleManager.ScheduleError? {
        guard !conversationType.isEncrypted else { return .forbidden }
        return isScheduleAvailable(owner: owner) ? nil : .unavailable
    }

    func validateScheduledAction(
        _ action: ScheduledMessageAction,
        on item: ScheduledMessageListItem
    ) -> XMPPMessageScheduleManager.ScheduleError? {
        isScheduleAvailable(owner: item.owner) ? nil : .unavailable
    }

    @discardableResult
    func schedulePreparedMessage(
        _ payload: XMPPMessage,
        for item: ScheduledMessageListItem,
        deliverAt: Date,
        callback: XMPPMessageScheduleManager.ScheduleCallback?
    ) -> String? {
        schedulePreparedMessage(
            payload, owner: item.owner, conversation: item.conversation, conversationType: item.conversationType,
            deliverAt: deliverAt, callback: callback
        )
    }

    @discardableResult
    func schedulePreparedMessage(
        _ payload: XMPPMessage,
        owner: String,
        conversation: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        deliverAt: Date,
        callback: XMPPMessageScheduleManager.ScheduleCallback?
    ) -> String? {
        callback?(.failure(.sendRejected))
        return nil
    }

    func sendScheduledMessageNow(
        _ payload: XMPPMessage,
        for item: ScheduledMessageListItem,
        completion: @escaping (Result<Void, XMPPMessageScheduleManager.ScheduleError>) -> Void
    ) {
        completion(.failure(.sendRejected))
    }
}

final class AccountChatScheduledMessageService: ChatScheduledMessageServicing {
    func isScheduleAvailable(owner: String) -> Bool {
        AccountManager.shared.find(for: owner)?.messageSchedule.isAvailable == true
    }

    func validateScheduledAttachmentRoute(
        owner: String, conversation: String, conversationType: ClientSynchronizationManager.ConversationType
    ) -> XMPPMessageScheduleManager.ScheduleError? {
        if conversationType == .omemo {
            return validateOMEMO2ScheduleRoute(owner: owner, conversation: conversation)
        }
        guard [.regular, .group, .saved].contains(conversationType),
              XMPPJID(string: conversation)?.bare == conversation else { return .forbidden }
        guard let user = AccountManager.shared.find(for: owner) else { return .sendRejected }
        return validateScheduleTransport(for: owner, user: user) ?? validatePlaintextRoute(
            conversation: conversation, conversationType: conversationType, user: user,
            hasMedia: true, mentions: .absent
        )
    }

    func validateScheduledAction(
        _ action: ScheduledMessageAction,
        on item: ScheduledMessageListItem
    ) -> XMPPMessageScheduleManager.ScheduleError? {
        guard let user = AccountManager.shared.find(for: item.owner) else {
            return .sendRejected
        }
        return validateScheduledAction(action, on: item, user: user)
    }

    private func validateScheduledAction(
        _ action: ScheduledMessageAction,
        on item: ScheduledMessageListItem,
        user: Account
    ) -> XMPPMessageScheduleManager.ScheduleError? {
        if let error = validateScheduleTransport(for: item.owner, user: user) { return error }
        if action == .delete { return nil }
        guard let payload = ScheduledMessageActionPayload.make(action, item: item) else { return .malformedPayload }
        return validatePreparedPayload(payload, conversation: item.conversation,
                                       conversationType: item.conversationType, user: user)
    }

    private func validateScheduleTransport(for owner: String, user: Account) -> XMPPMessageScheduleManager.ScheduleError? {
        guard user.jid == owner, AccountManager.shared.find(for: owner) === user,
              user.sendReadiness.snapshot.canFlushApplicationStanzas else {
            return .sendRejected
        }
        return user.messageSchedule.isAvailable ? nil : .unavailable
    }

    func validateOMEMO2ScheduleRoute(owner: String, conversation: String) -> XMPPMessageScheduleManager.ScheduleError? {
        guard let user = AccountManager.shared.find(for: owner) else { return .sendRejected }
        return validateScheduleTransport(for: owner, user: user) ?? validateOMEMO2Peer(conversation, user: user)
    }

    private func validateOMEMO2Peer(
        _ conversation: String, user: Account
    ) -> XMPPMessageScheduleManager.ScheduleError? {
        guard XMPPJID(string: conversation)?.bare == conversation,
              OMEMO2OptOutPolicy.allowsMessage(owner: user.jid, jid: conversation, storage: user.omemo.omemo2Storage),
              let realm = try? WRealm.safe(),
              OmemoSendAvailabilityPolicy.evaluate(
                owner: user.jid, jid: conversation, conversationType: .omemo, realm: realm
              ).canSend else { return .forbidden }
        return nil
    }

    private func validatePreparedPayload(
        _ payload: XMPPMessage, conversation: String,
        conversationType: ClientSynchronizationManager.ConversationType, user: Account
    ) -> XMPPMessageScheduleManager.ScheduleError? {
        if conversationType == .omemo {
            guard !SCEReceivePolicy.containsOMEMO2(payload),
                  ScheduledOMEMO2.permitsEncryptedFiles(in: payload, owner: user.jid) else { return .malformedPayload }
            return validateOMEMO2Peer(conversation, user: user)
        }
        return validatePlaintextPayload(payload, conversation: conversation, conversationType: conversationType, user: user)
    }

    private func validatePlaintextPayload(
        _ payload: XMPPMessage,
        conversation: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        user: Account
    ) -> XMPPMessageScheduleManager.ScheduleError? {
        guard !SCEReceivePolicy.containsOMEMO2(payload),
              !ScheduledMessageContent.containsFileProtection(payload) else { return .forbidden }
        let references = SCEReceivePolicy.children(
            of: payload, named: "reference", xmlns: "https://xabber.com/protocol/references"
        )
        let hasMedia = ChatStickerWireCodec.containsSticker(in: payload) ||
            references.contains { ["media", "voice", "sticker"].contains(getReferenceType($0) ?? "") }
        return validatePlaintextRoute(
            conversation: conversation, conversationType: conversationType, user: user,
            hasMedia: hasMedia, mentions: GroupMessageMentionsCodec.decode(from: payload)
        )
    }

    private func validatePlaintextRoute(
        conversation: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        user: Account,
        hasMedia: Bool,
        mentions: GroupMessageMentionIntent
    ) -> XMPPMessageScheduleManager.ScheduleError? {
        guard !conversationType.isEncrypted else { return .forbidden }
        guard OMEMO2OptOutPolicy.allowsMessage(
            owner: user.jid, jid: conversation, storage: user.omemo.omemo2Storage
        ) else { return .forbidden }
        if conversationType == .group {
            guard let realm = try? WRealm.safe(),
                  let group = try? GroupRepository(realm: realm).projection(owner: user.jid, groupJID: conversation),
                  group.state.isActive, !group.state.isDeleted, group.capabilities.sendMessages else { return .forbidden }
            if hasMedia, !group.capabilities.sendMedia { return .forbidden }
            switch mentions {
            case .all:
                let role = group.state.members.first { $0.id == group.selfMemberID }?.role
                guard role == .admin || role == .owner else { return .forbidden }
            case .invalid: return .forbidden
            case .members, .absent: break
            }
        }
        return nil
    }

    @discardableResult
    func schedulePreparedMessage(
        _ payload: XMPPMessage,
        owner: String,
        conversation: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        deliverAt: Date,
        callback: XMPPMessageScheduleManager.ScheduleCallback?
    ) -> String? {
        guard let user = AccountManager.shared.find(for: owner), user.jid == owner else {
            callback?(.failure(.sendRejected))
            return nil
        }
        var queryId: String?
        user.unsafeAction { user, stream in
            if let error = self.validateScheduleTransport(for: owner, user: user) ??
                self.validatePlaintextPayload(payload, conversation: conversation,
                                              conversationType: conversationType, user: user) {
                callback?(.failure(error))
            } else if deliverAt <= Date() {
                callback?(.failure(.notAcceptable))
            } else {
                queryId = user.messageSchedule.scheduleMessage(
                    stream, conversation: conversation, conversationType: conversationType,
                    deliverAt: deliverAt, payload: payload, callback: callback
                )
            }
        }
        return queryId
    }

    func sendScheduledMessageNow(
        _ payload: XMPPMessage,
        for item: ScheduledMessageListItem,
        completion: @escaping (Result<Void, XMPPMessageScheduleManager.ScheduleError>) -> Void
    ) {
        guard let user = AccountManager.shared.find(for: item.owner) else {
            completion(.failure(.sendRejected))
            return
        }
        user.action { user, _ in
            if let error = self.validateScheduleTransport(for: item.owner, user: user) ??
                self.validatePreparedPayload(payload, conversation: item.conversation,
                                             conversationType: item.conversationType, user: user) {
                completion(.failure(error))
                return
            }
            completion(user.messages.admitScheduledMessageForImmediateSend(
                payload, to: item.conversation, conversationType: item.conversationType
            ) ? .success(()) : .failure(.sendRejected))
        }
    }

    func sendStickerImmediately(
        _ sticker: ChatStickerDescriptor, owner: String, conversation: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        completion: @escaping (Bool) -> Void
    ) {
        guard let account = AccountManager.shared.find(for: owner),
              let payload = ChatStickerWireCodec.makeMessage(
                sticker, owner: owner, conversation: conversation, conversationType: conversationType
              ) else {
            completion(false)
            return
        }
        account.action { user, _ in
            guard AccountManager.shared.find(for: owner) === user,
                  user.sendReadiness.snapshot.canFlushApplicationStanzas,
                  self.validatePreparedPayload(
                    payload, conversation: conversation, conversationType: conversationType, user: user
                  ) == nil else {
                completion(false)
                return
            }
            completion(user.messages.admitScheduledMessageForImmediateSend(
                payload, to: conversation, conversationType: conversationType
            ))
        }
    }

    func scheduleOMEMO2Message(
        _ request: ChatScheduledMessageSendRequest,
        callback: @escaping XMPPMessageScheduleManager.ScheduleCallback
    ) {
        guard request.conversationType == .omemo, let account = AccountManager.shared.find(for: request.owner) else {
            callback(.failure(.forbidden))
            return
        }
        account.action { user, stream in
            let payload = user.messageSchedule.makePlaintextMessagePayload(
                to: request.conversation, body: request.body, conversationType: .omemo,
                references: request.references, forwardedMessagePrimaries: request.forwardedMessagePrimaries
            )
            payload.setXmlns(SCEReceivePolicy.client)
            self.scheduleProtected(
                payload, owner: request.owner, conversation: request.conversation,
                deliverAt: request.deliverAt, user: user, stream: stream, callback: callback
            )
        }
    }

    func scheduleOMEMO2PreparedMessage(
        _ payload: XMPPMessage, owner: String, conversation: String, deliverAt: Date,
        callback: @escaping XMPPMessageScheduleManager.ScheduleCallback
    ) {
        guard let account = AccountManager.shared.find(for: owner) else {
            callback(.failure(.sendRejected))
            return
        }
        account.action { user, stream in
            self.scheduleProtected(
                payload, owner: owner, conversation: conversation, deliverAt: deliverAt,
                user: user, stream: stream, callback: callback
            )
        }
    }

    private func scheduleProtected(
        _ payload: XMPPMessage, owner: String, conversation: String, deliverAt: Date, user: Account, stream: XMPPStream,
        callback: @escaping XMPPMessageScheduleManager.ScheduleCallback
    ) {
        guard deliverAt > Date() else {
            callback(.failure(.notAcceptable))
            return
        }
        if let error = validateScheduleTransport(for: owner, user: user) ??
            validatePreparedPayload(payload, conversation: conversation, conversationType: .omemo, user: user) {
            callback(.failure(error))
            return
        }
        user.messageSchedule.scheduleOMEMO2Message(
            stream, conversation: conversation, deliverAt: deliverAt, plaintext: payload, omemo: user.omemo, callback: callback
        )
    }

    @discardableResult
    func schedulePlaintextMessage(
        _ request: ChatScheduledMessageSendRequest,
        callback: XMPPMessageScheduleManager.ScheduleCallback?
    ) -> String? {
        guard !request.conversationType.isEncrypted else {
            callback?(.failure(.forbidden))
            return nil
        }
        guard let account = AccountManager.shared.find(for: request.owner) else {
            callback?(.failure(.sendRejected))
            return nil
        }
        if let error = validateScheduleTransport(for: request.owner, user: account) {
            callback?(.failure(error))
            return nil
        }
        guard request.deliverAt > Date() else {
            callback?(.failure(.notAcceptable))
            return nil
        }

        var queryId: String?
        account.unsafeAction { user, stream in
            let mentions = request.conversationType == .group
                ? GroupMessageMentionsCodec.encode(
                    request.groupMentionIntent,
                    capabilityGranted: request.groupMentionAllCapabilityGranted,
                    senderRole: request.groupMentionSenderRole
                ) : nil
            let payload = user.messageSchedule.makePlaintextMessagePayload(
                to: request.conversation, body: request.body, conversationType: request.conversationType,
                references: request.references, forwardedMessagePrimaries: request.forwardedMessagePrimaries,
                additionalChildren: mentions.map { [$0] } ?? []
            )
            if let error = self.validatePlaintextPayload(
                payload, conversation: request.conversation, conversationType: request.conversationType, user: user
            ) {
                callback?(.failure(error))
                return
            }
            queryId = user.messageSchedule.scheduleMessage(
                stream, conversation: request.conversation, conversationType: request.conversationType,
                deliverAt: request.deliverAt, payload: payload, callback: callback
            )
        }
        return queryId
    }

    @discardableResult
    func listScheduledMessages(
        owner: String,
        conversation: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        callback: XMPPMessageScheduleManager.ListCallback?
    ) -> String? {
        guard let account = AccountManager.shared.find(for: owner) else {
            callback?(.failure(.sendRejected))
            return nil
        }

        var queryId: String?
        account.unsafeAction { user, stream in
            queryId = user.messageSchedule.listScheduledMessages(
                stream,
                conversation: conversation,
                conversationType: conversationType,
                callback: callback
            )
        }
        return queryId
    }

    @discardableResult
    func cancelScheduledMessage(
        owner: String,
        scheduledId: String,
        callback: XMPPMessageScheduleManager.CancelCallback?
    ) -> String? {
        guard let account = AccountManager.shared.find(for: owner) else {
            callback?(.failure(.sendRejected))
            return nil
        }

        var queryId: String?
        account.unsafeAction { user, stream in
            if let error = self.validateScheduleTransport(for: owner, user: user) {
                callback?(.failure(error))
                return
            }
            queryId = user.messageSchedule.cancelScheduledMessage(
                stream,
                scheduledId: scheduledId,
                callback: callback
            )
        }
        return queryId
    }
}

final class ChatScheduledMessageSendCoordinator {
    private let service: ChatScheduledMessageServicing

    init(service: ChatScheduledMessageServicing) {
        self.service = service
    }

    func scheduleAttachments(
        _ references: [MessageReferenceStorageItem],
        caption: ChatAttachmentCaptionState,
        context: ChatAttachmentFlowContext,
        deliverAt: Date,
        completion: @escaping (Result<Void, XMPPMessageScheduleManager.ScheduleError>) -> Void
    ) {
        guard deliverAt > Date() else {
            completion(.failure(.notAcceptable))
            return
        }
        if let error = service.validateScheduledAttachmentRoute(
            owner: context.owner, conversation: context.jid, conversationType: context.conversationType
        ) {
            completion(.failure(error))
            return
        }
        guard !references.isEmpty, references.allSatisfy({
            $0.owner == context.owner && $0.jid == context.jid && $0.isUploaded
                && [.media, .voice].contains($0.kind)
        }) else {
            completion(.failure(.malformedPayload))
            return
        }
        var body = caption.isEmpty ? "" : caption.rawText
        var children: [DDXMLElement] = []
        if !context.forwardedMessageIds.isEmpty {
            guard let realm = try? WRealm.safe(),
                  let sources = try? ForwardSourceLoader.load(ids: context.forwardedMessageIds, owner: context.owner, realm: realm),
                  let units = try? ForwardSendPlanner.plan(sources: sources, comment: body, intent: context.forwardIntent),
                  units.count == 1, let unit = units.first else {
                completion(.failure(.malformedPayload))
                return
            }
            body = unit.body
            children = unit.refs
        }
        guard let payload = ScheduledMessageContent.makeMessage(
            owner: context.owner, conversation: context.jid, conversationType: context.conversationType,
            body: body, references: references, additionalChildren: children
        ) else {
            completion(.failure(.malformedPayload))
            return
        }
        submitPrepared(payload, owner: context.owner, conversation: context.jid, conversationType: context.conversationType,
                       deliverAt: deliverAt, completion: completion)
    }

    func scheduleSticker(
        _ sticker: ChatStickerDescriptor, owner: String, conversation: String,
        conversationType: ClientSynchronizationManager.ConversationType, deliverAt: Date,
        completion: @escaping (Result<Void, XMPPMessageScheduleManager.ScheduleError>) -> Void
    ) {
        guard deliverAt > Date() else {
            completion(.failure(.notAcceptable))
            return
        }
        if let error = service.validateScheduledAttachmentRoute(
            owner: owner, conversation: conversation, conversationType: conversationType
        ) {
            completion(.failure(error))
            return
        }
        guard let payload = ChatStickerWireCodec.makeMessage(
            sticker, owner: owner, conversation: conversation, conversationType: conversationType
        ) else {
            completion(.failure(.malformedPayload))
            return
        }
        submitPrepared(payload, owner: owner, conversation: conversation, conversationType: conversationType,
                       deliverAt: deliverAt, completion: completion)
    }

    private func submitPrepared(
        _ payload: XMPPMessage, owner: String, conversation: String,
        conversationType: ClientSynchronizationManager.ConversationType, deliverAt: Date,
        completion: @escaping (Result<Void, XMPPMessageScheduleManager.ScheduleError>) -> Void
    ) {
        let resolve: XMPPMessageScheduleManager.ScheduleCallback = { result in completion(result.map { _ in () }) }
        if conversationType == .omemo {
            service.scheduleOMEMO2PreparedMessage(
                payload, owner: owner, conversation: conversation, deliverAt: deliverAt, callback: resolve
            )
            return
        }
        service.schedulePreparedMessage(
            payload, owner: owner, conversation: conversation, conversationType: conversationType,
            deliverAt: deliverAt, callback: resolve
        )
    }

    @discardableResult
    func schedule(
        _ request: ChatScheduledMessageSendRequest,
        onSuccess: @escaping (XMPPMessageScheduleManager.ScheduledEntry) -> Void,
        onFailure: @escaping (XMPPMessageScheduleManager.ScheduleError) -> Void
    ) -> String? {
        guard request.body.trimmingCharacters(in: .whitespacesAndNewlines).isNotEmpty else {
            onFailure(.malformedPayload)
            return nil
        }
        guard service.isScheduleAvailable(owner: request.owner) else {
            onFailure(.unavailable)
            return nil
        }

        if request.conversationType == .omemo {
            if let error = service.validateOMEMO2ScheduleRoute(owner: request.owner, conversation: request.conversation) {
                onFailure(error)
                return nil
            }
            service.scheduleOMEMO2Message(request) { result in
                switch result {
                case .success(let entry): onSuccess(entry)
                case .failure(let error): onFailure(error)
                }
            }
            return nil
        }
        guard !request.conversationType.isEncrypted else {
            onFailure(.forbidden)
            return nil
        }

        var didCompleteImmediately = false
        let queryId = service.schedulePlaintextMessage(request) { result in
            didCompleteImmediately = true
            switch result {
            case .success(let entry):
                onSuccess(entry)
            case .failure(let error):
                onFailure(error)
            }
        }
        if queryId == nil && !didCompleteImmediately {
            onFailure(.sendRejected)
        }
        return queryId
    }
}

struct ScheduledMessageListItem: Equatable {
    let scheduledId: String
    let deliverAt: Date
    let status: XMPPMessageScheduleStorageItem.Status
    let bodyPreview: String
    let owner: String
    let conversation: String
    let conversationType: ClientSynchronizationManager.ConversationType
    let messageXML: String
    let protectedContentXML: String?

    var contentXML: String? {
        conversationType.isEncrypted ? protectedContentXML : messageXML
    }

    init(
        scheduledId: String, deliverAt: Date, status: XMPPMessageScheduleStorageItem.Status,
        bodyPreview: String, owner: String = "", conversation: String = "",
        conversationType: ClientSynchronizationManager.ConversationType = .regular, messageXML: String = "",
        protectedContentXML: String? = nil
    ) {
        self.scheduledId = scheduledId
        self.deliverAt = deliverAt
        self.status = status
        self.bodyPreview = bodyPreview
        self.owner = owner
        self.conversation = conversation
        self.conversationType = conversationType
        self.messageXML = messageXML
        self.protectedContentXML = protectedContentXML
    }
}

enum ScheduledMessageXMLPreviewParser {
    static func bodyPreview(from messageXML: String) -> String {
        guard let document = try? DDXMLDocument(xmlString: messageXML, options: 0),
              let root = document.rootElement() else {
            return ""
        }
        guard root.localName == "message", root.uri == nil || root.uri == SCEReceivePolicy.client else { return "" }
        let children = (root.children ?? []).compactMap { $0 as? DDXMLElement }
        let bodyElementName = "body"
        guard let body = children.first(where: { $0.localName == bodyElementName && ($0.uri == nil || $0.uri == SCEReceivePolicy.client) }) else {
            return ""
        }
        return body.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

enum ScheduledMessagesListModel {
    static func items(
        owner: String,
        conversation: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        realm: Realm
    ) throws -> [ScheduledMessageListItem] {
        realm.objects(XMPPMessageScheduleStorageItem.self)
            .filter("owner == %@ AND conversation == %@ AND conversationType_ == %@", owner, conversation, conversationType.rawValue)
            .sorted(byKeyPath: "deliverAt", ascending: true)
            .map {
                let contents = conversationType == .omemo
                    ? ScheduledOMEMO2.preview(owner: owner, conversation: conversation, deliverAt: $0.deliverAt, messageXML: $0.messageXML)
                    : nil
                let displayXML = conversationType.isEncrypted ? (contents ?? "") : $0.messageXML
                return ScheduledMessageListItem(
                    scheduledId: $0.scheduledId,
                    deliverAt: $0.deliverAt,
                    status: $0.status,
                    bodyPreview: ScheduledMessageContent.read(
                        messageXML: displayXML, owner: owner, conversation: conversation
                    )?.body ?? ScheduledMessageXMLPreviewParser.bodyPreview(from: displayXML),
                    owner: $0.owner,
                    conversation: $0.conversation,
                    conversationType: $0.conversationType,
                    messageXML: $0.messageXML,
                    protectedContentXML: contents
                )
            }
    }
}

enum ScheduledMessagesComposerButtonPolicy {
    static func shouldShow(
        inputState: ModernXabberInputView.InputBarState,
        body: String,
        hasScheduledMessages: Bool
    ) -> Bool {
        inputState == .normal
            && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && hasScheduledMessages
    }
}

enum ScheduledMessagesComposerButtonModel {
    static func results(
        owner: String,
        conversation: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        realm: Realm
    ) -> Results<XMPPMessageScheduleStorageItem> {
        realm.objects(XMPPMessageScheduleStorageItem.self)
            .filter(
                "owner == %@ AND conversation == %@ AND conversationType_ == %@ AND (status_ == %@ OR status_ == %@)",
                owner,
                conversation,
                conversationType.rawValue,
                XMPPMessageScheduleStorageItem.Status.pending.rawValue,
                XMPPMessageScheduleStorageItem.Status.failed.rawValue
            )
    }

    static func hasRows(
        owner: String,
        conversation: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        realm: Realm
    ) -> Bool {
        !results(
            owner: owner,
            conversation: conversation,
            conversationType: conversationType,
            realm: realm
        ).isEmpty
    }
}
