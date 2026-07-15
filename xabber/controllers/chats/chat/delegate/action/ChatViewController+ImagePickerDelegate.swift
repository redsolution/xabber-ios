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

extension ChatViewController: ImagePickerViewDelegate {
    func checkProgress(for messageId: String, total: Int, progress: Int) {
        guard let message = datasource.last(where: {
            $0.messageId == messageId || $0.primary == messageId
        }) else { return }
        let normalizedProgress = total > 0
            ? Double(progress) / Double(total)
            : 0
        publishFileTransferState(
            .transferring(progress: normalizedProgress),
            files: message.files,
            containerPrimary: message.primary
        )
        message.forwards.forEach {
            publishFileTransferStateRecursively(
                .transferring(progress: normalizedProgress),
                attachment: $0
            )
        }
    }

    private func publishFileTransferStateRecursively(
        _ state: ChatFileTransferState,
        attachment: MessageAttachment
    ) {
        publishFileTransferState(
            state,
            files: attachment.files,
            containerPrimary: attachment.primary
        )
        attachment.subforwards.forEach {
            publishFileTransferStateRecursively(state, attachment: $0)
        }
    }

    private func publishFileTransferState(
        _ state: ChatFileTransferState,
        files: [FileAttachment],
        containerPrimary: String
    ) {
        files.forEach {
            ChatFileAttachmentPipeline.shared.publish(
                state,
                for: $0.representedRequest(containerPrimary: containerPrimary)
            )
        }
    }
    
    func onSendMessage() {
        finishOutgoingAttachmentSend(requestScroll: true)
    }

    internal func finishOutgoingAttachmentSend(requestScroll: Bool) {
        let updates = {
            if requestScroll {
                self.requestOutgoingAutoScrollAfterDatasourceUpdate()
            }
            self.forwardedIds.accept(Set<String>())
            self.attachedMessagesIds.accept([])
            self.unreadMessagePositionId = nil
        }

        if Thread.isMainThread {
            updates()
        } else {
            DispatchQueue.main.async(execute: updates)
        }
    }
    
    func onDismissPicker() {
        self.inputAccessoryView?.isHidden = false
    }
}
