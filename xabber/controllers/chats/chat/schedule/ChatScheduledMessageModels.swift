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
        if context.conversationType.isEncrypted {
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
        var components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: date
        )
        components.second = 0
        components.nanosecond = 0
        components.timeZone = timeZone
        return calendar.date(from: components) ?? date
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
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func dateTimeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
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

    static func == (lhs: ChatScheduledMessageSendRequest, rhs: ChatScheduledMessageSendRequest) -> Bool {
        lhs.owner == rhs.owner
            && lhs.conversation == rhs.conversation
            && lhs.conversationType == rhs.conversationType
            && lhs.deliverAt == rhs.deliverAt
            && lhs.body == rhs.body
            && lhs.forwardedMessagePrimaries == rhs.forwardedMessagePrimaries
            && lhs.references.map(\.primary) == rhs.references.map(\.primary)
    }
}

protocol ChatScheduledMessageServicing: AnyObject {
    func isScheduleAvailable(owner: String) -> Bool

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
}

final class AccountChatScheduledMessageService: ChatScheduledMessageServicing {
    func isScheduleAvailable(owner: String) -> Bool {
        AccountManager.shared.find(for: owner)?.messageSchedule.isAvailable == true
    }

    @discardableResult
    func schedulePlaintextMessage(
        _ request: ChatScheduledMessageSendRequest,
        callback: XMPPMessageScheduleManager.ScheduleCallback?
    ) -> String? {
        guard let account = AccountManager.shared.find(for: request.owner) else {
            return nil
        }

        var queryId: String?
        account.unsafeAction { user, stream in
            queryId = user.messageSchedule.schedulePlaintextMessage(
                stream,
                conversation: request.conversation,
                conversationType: request.conversationType,
                deliverAt: request.deliverAt,
                body: request.body,
                references: request.references,
                forwardedMessagePrimaries: request.forwardedMessagePrimaries,
                callback: callback
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
}

enum ScheduledMessageXMLPreviewParser {
    static func bodyPreview(from messageXML: String) -> String {
        guard let document = try? DDXMLDocument(xmlString: messageXML, options: 0),
              let root = document.rootElement() else {
            return ""
        }
        if let body = root.element(forName: "body")?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           body.isNotEmpty {
            return body
        }
        if let body = root.elements(forName: "body").first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           body.isNotEmpty {
            return body
        }
        return ""
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
                ScheduledMessageListItem(
                    scheduledId: $0.scheduledId,
                    deliverAt: $0.deliverAt,
                    status: $0.status,
                    bodyPreview: ScheduledMessageXMLPreviewParser.bodyPreview(from: $0.messageXML)
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
