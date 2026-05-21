//
//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
//  General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//
//

import Foundation
import UIKit
import MaterialComponents.MDCPalettes
import CocoaLumberjack

extension ChatViewController: ChatViewMessagesPanelDelegate {
    func messagesPanelOnClose() {
        switch self.xabberInputView.activeContextPreviewMode {
        case .edit:
            self.editMessageId.accept(nil)
        case .forward:
            self.attachedMessagesIds.accept([])
        case nil:
            if self.editMessageId.value != nil {
                self.editMessageId.accept(nil)
            } else {
                self.attachedMessagesIds.accept([])
            }
        }
    }
    
    func messagesPanelOnIndicatorTouch() {
        switch self.xabberInputView.activeContextPreviewMode {
        case .edit:
            guard let editMessageId = self.editMessageId.value else {
                return
            }
            self.openEditMessagePreviewTarget(messagePrimary: editMessageId)
        case .forward:
            self.openAttachedMessagePreviewTarget()
        case nil:
            if let editMessageId = self.editMessageId.value {
                self.openEditMessagePreviewTarget(messagePrimary: editMessageId)
            } else {
                self.openAttachedMessagePreviewTarget()
            }
        }

    }

    private func openEditMessagePreviewTarget(messagePrimary: String) {
        guard messagePrimary.isNotEmpty else {
            return
        }

        if let loadedIndex = ChatEditPreviewNavigationPolicy.loadedTargetIndex(
            in: self.datasource,
            editMessageId: messagePrimary
        ), self.datasource.indices.contains(loadedIndex) {
            let item = self.datasource[loadedIndex]
            self.queueOpenMessageRequest(
                self.openRequestForComposerPreview(
                    messagePrimary: item.primary,
                    archivedId: item.archivedId?.isNotEmpty == true ? item.archivedId : nil,
                    messageId: item.messageId.isNotEmpty ? item.messageId : nil,
                    authorId: item.groupchatAuthorId.isNotEmpty ? item.groupchatAuthorId : nil,
                    sourceDate: item.sentDate,
                    source: .composerEditPreview
                ),
                hooks: self.composerPreviewNavigationHooks()
            )
            return
        }

        do {
            let realm = try WRealm.safe()
            guard let item = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: messagePrimary),
                  item.owner == self.owner,
                  item.opponent == self.jid,
                  item.conversationType == self.conversationType else {
                return
            }

            self.queueOpenMessageRequest(
                self.openRequestForComposerPreview(
                    messagePrimary: item.primary,
                    archivedId: item.archivedId.isNotEmpty ? item.archivedId : nil,
                    messageId: item.messageId.isNotEmpty ? item.messageId : nil,
                    authorId: item.groupchatAuthorId?.isNotEmpty == true ? item.groupchatAuthorId : nil,
                    sourceDate: item.date,
                    source: .composerEditPreview
                ),
                hooks: self.composerPreviewNavigationHooks()
            )
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
    }

    private func openAttachedMessagePreviewTarget() {
        let attachedIds = self.attachedMessagesIds.value
        guard attachedIds.isNotEmpty else {
            return
        }

        if let loadedIndex = ChatForwardPreviewNavigationPolicy.loadedTargetIndex(
            in: self.datasource,
            attachedMessageIds: attachedIds
        ), self.datasource.indices.contains(loadedIndex) {
            let item = self.datasource[loadedIndex]
            self.queueOpenMessageRequest(
                self.openRequestForComposerPreview(
                    messagePrimary: item.primary,
                    archivedId: item.archivedId?.isNotEmpty == true ? item.archivedId : nil,
                    messageId: item.messageId.isNotEmpty ? item.messageId : nil,
                    authorId: item.groupchatAuthorId.isNotEmpty ? item.groupchatAuthorId : nil,
                    sourceDate: item.sentDate,
                    source: .composerReferencePreview
                ),
                hooks: self.composerPreviewNavigationHooks()
            )
            return
        }

        do {
            let realm = try WRealm.safe()
            let attachedMessages = realm.objects(MessageStorageItem.self)
                .filter("primary IN %@", attachedIds)
                .toArray()
                .filter {
                    $0.owner == self.owner
                        && $0.opponent == self.jid
                        && $0.conversationType == self.conversationType
                }
                .sorted { lhs, rhs in
                    if lhs.date != rhs.date {
                        return lhs.date < rhs.date
                    }
                    let lhsIndex = attachedIds.firstIndex(of: lhs.primary) ?? Int.max
                    let rhsIndex = attachedIds.firstIndex(of: rhs.primary) ?? Int.max
                    return lhsIndex < rhsIndex
                }

            guard let item = attachedMessages.first else {
                return
            }

            self.queueOpenMessageRequest(
                self.openRequestForComposerPreview(
                    messagePrimary: item.primary,
                    archivedId: item.archivedId.isNotEmpty ? item.archivedId : nil,
                    messageId: item.messageId.isNotEmpty ? item.messageId : nil,
                    authorId: item.groupchatAuthorId?.isNotEmpty == true ? item.groupchatAuthorId : nil,
                    sourceDate: item.date,
                    source: .composerReferencePreview
                ),
                hooks: self.composerPreviewNavigationHooks()
            )
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
    }

    private func openRequestForComposerPreview(
        messagePrimary: String,
        archivedId: String?,
        messageId: String?,
        authorId: String?,
        sourceDate: Date,
        source: ChatOpenMessageRequestSource
    ) -> ChatOpenMessageRequest {
        ChatOpenMessageRequest(
            chatJid: self.jid,
            owner: self.owner,
            conversationType: self.conversationType,
            anchor: ChatMessageAnchorRef(
                messagePrimary: messagePrimary,
                archivedId: archivedId,
                messageId: messageId,
                authorId: authorId,
                bodyFingerprint: nil,
                sourceDate: sourceDate
            ),
            highlight: true,
            markReadOnVisible: false,
            source: source
        )
    }

    private func composerPreviewNavigationHooks() -> ChatAnchorExecutionHooks {
        ChatAnchorExecutionHooks(
            direction: .up,
            animatedScroll: true,
            onFailed: nil,
            onPositioned: nil
        )
    }
}
