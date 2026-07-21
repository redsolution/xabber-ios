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

extension ChatViewController {

    @objc
    internal func showImagePicker() {
        self.view.endEditing(false)
        DispatchQueue.main.async {
            guard let account = AccountManager.shared.find(for: self.owner) else {
                ToastPresenter().presentError(message: "File transfer is unavailable for this account.".localizeString(id: "media_picker_error_upload_unavailable", arguments: []))
                return
            }
            let route = ChatAttachmentPickerRoutingPolicy.route(
                isTelegramAttachmentPickerEnabled: CommonConfigManager.shared.config.use_telegram_attachment_picker,
                availabilityState: account.cloudStorage.availabilityRelay.value
            )

            switch route {
            case .telegramAttachmentFlow:
                self.presentTelegramAttachmentFlow()
            case .blocked(.cloudStorageUnavailable):
                ToastPresenter().presentError(message: "File transfer is unavailable for this account.".localizeString(id: "media_picker_error_upload_unavailable", arguments: []))
            case .blocked(.cloudStoragePending):
                account.cloudStorage.resumeAvailabilityWorkIfNeeded(
                    stream: account.xmppStream,
                    disco: account.disco
                )
                ToastPresenter().present(
                    message: "Cloud Storage is still connecting. Please try again shortly."
                        .localizeString(id: "media_picker_cloud_storage_connecting", arguments: [])
                )
            }
        }
    }

    private func presentTelegramAttachmentFlow() {
        let coordinator = ChatAttachmentFlowCoordinator(
            presentingViewController: self,
            context: ChatAttachmentFlowContext(
                owner: self.owner,
                jid: self.jid,
                conversationType: self.conversationType,
                forwardedMessageIds: self.attachedMessagesIds.value,
                composerTintColor: self.accountPallete.tint600
            )
        )
        coordinator.delegate = self
        self.chatAttachmentFlowCoordinator = coordinator
        coordinator.start()
    }
    
    @objc
    func keyboardWillChangeFrameNotification(_ notification: Notification) {
        self.handleKeyboardFrameChange(notification)
    }
    
    @objc
    func keyboardWillShowNotification(_ notification: Notification) {
        self.handleKeyboardFrameChange(notification)
    }
    
    @objc func keyboardWillHideNotification(_ notification: NSNotification) {
        self.handleKeyboardFrameChange(notification as Notification)
    }

    internal static func keyboardOverlapHeight(viewBounds: CGRect, keyboardFrameInView: CGRect) -> CGFloat {
        guard viewBounds.width > 0,
              viewBounds.height > 0,
              !keyboardFrameInView.isEmpty else {
            return 0
        }

        let intersection = viewBounds.intersection(keyboardFrameInView)
        guard !intersection.isNull, !intersection.isEmpty else {
            return 0
        }

        return max(0, intersection.height)
    }

    internal func keyboardOverlapHeight(from keyboardFrameInScreenCoordinates: CGRect) -> CGFloat {
        let keyboardFrameInView = self.view.convert(keyboardFrameInScreenCoordinates, from: self.view.window)
        return Self.keyboardOverlapHeight(
            viewBounds: self.view.bounds,
            keyboardFrameInView: keyboardFrameInView
        )
    }

    private func handleKeyboardFrameChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let frameValue = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue,
              self.xabberInputView != nil else {
            return
        }

        let keyboardVisibleHeight = self.keyboardOverlapHeight(from: frameValue.cgRectValue)
        let layoutSignature = ChatKeyboardLayoutUpdateSignature(
            visibleHeight: keyboardVisibleHeight,
            viewSize: self.view.bounds.size,
            searchOwnsKeyboard: self.isChatSearchInputKeyboardOwned
        )
        guard ChatKeyboardLayoutUpdatePolicy.shouldApply(
            previous: self.lastAppliedChatKeyboardLayoutSignature,
            next: layoutSignature
        ) else {
            return
        }
        self.lastAppliedChatKeyboardLayoutSignature = layoutSignature

        let duration = (userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0
        let curveValue = (userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue
        let options = curveValue
            .map { UIView.AnimationOptions(rawValue: $0 << 16).union(.beginFromCurrentState) }
            ?? [.beginFromCurrentState, .curveEaseInOut]
        let wasNearBottom = self.isNearBottom()
        let visibleAnchor = ChatKeyboardFrameViewportPolicy.shouldCaptureVisibleAnchor(
            wasNearBottom: wasNearBottom
        ) ? self.capturePagingAnchorIfNeeded(direction: .older) : nil
        ChatUIResponsivenessGate.shared.activate(
            reason: .keyboardFrame,
            duration: ChatUIResponsivenessGate.holdDuration(keyboardAnimationDuration: duration)
        )

        let updates = {
            let inputHeight = self.updateChatInputViewForCurrentKeyboardLayout(
                visibleKeyboardHeight: keyboardVisibleHeight
            )
            self.applyChatComposerFrameUpdate(
                inputHeight: inputHeight,
                source: .keyboardFrame,
                wasNearBottom: wasNearBottom,
                visibleAnchor: visibleAnchor
            )
        }

        let shouldAnimateKeyboardMutation = ChatSearchMotionMutationPolicy.shouldAnimate(
            requestedAnimated: duration > 0,
            isNavigationTransitionActive: self.isNavigationTransitionActive,
            isPreparingFirstFrame: self.isPreparingStackedNavigationPresentation,
            isInteractiveKeyboardUpdate: self.isChatSearchInputKeyboardOwned &&
                self.messagesCollectionView.keyboardDismissMode == .interactive
        )
        if shouldAnimateKeyboardMutation {
            UIView.animate(
                withDuration: TimeInterval(duration),
                delay: 0,
                options: options,
                animations: updates,
                completion: nil
            )
        } else {
            updates()
        }
    }
}

extension ChatViewController: ChatAttachmentFlowCoordinatorDelegate {
    func chatAttachmentFlowCoordinatorWillSend(_ coordinator: ChatAttachmentFlowCoordinator) {
        requestOutgoingAutoScrollAfterDatasourceUpdate()
    }

    func chatAttachmentFlowCoordinatorDidSend(_ coordinator: ChatAttachmentFlowCoordinator) {
        clearChatAttachmentFlowCoordinatorIfNeeded(coordinator)
        finishOutgoingAttachmentSend(requestScroll: false)
    }

    func chatAttachmentFlowCoordinatorDidDismiss(_ coordinator: ChatAttachmentFlowCoordinator) {
        restoreInputAccessoryAfterAttachmentPickerDismissal()
        clearChatAttachmentFlowCoordinatorIfNeeded(coordinator)
    }

    func chatAttachmentFlowCoordinator(
        _ coordinator: ChatAttachmentFlowCoordinator,
        didRequestPremiumFor owner: String
    ) {
        SubscribtionsPresenter().present(animated: true, owner: owner, parent: self)
    }

    func chatAttachmentFlowCoordinator(
        _ coordinator: ChatAttachmentFlowCoordinator,
        didFailWith error: ChatAttachmentFlowError
    ) {
        clearChatAttachmentFlowCoordinatorIfNeeded(coordinator)
        ToastPresenter().presentError(
            message: "Unable to open attachment picker.".localizeString(
                id: "media_picker_error_open_failed",
                arguments: []
            )
        )
    }

    private func clearChatAttachmentFlowCoordinatorIfNeeded(_ coordinator: ChatAttachmentFlowCoordinator) {
        guard let retainedCoordinator = chatAttachmentFlowCoordinator,
              retainedCoordinator === coordinator else {
            return
        }

        chatAttachmentFlowCoordinator = nil
    }
}
