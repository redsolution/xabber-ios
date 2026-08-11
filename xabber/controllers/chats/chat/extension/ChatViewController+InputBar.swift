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

struct ChatComposerFirstFocusRecoveryEligibility: Equatable {
    let isComposerFirstResponder: Bool
    let isComposerAttached: Bool
    let isSceneForegroundActive: Bool
    let isChatVisible: Bool
    let isNavigationStable: Bool
    let isInteractiveDismissalActive: Bool

    static let fullyEligible = ChatComposerFirstFocusRecoveryEligibility(
        isComposerFirstResponder: true,
        isComposerAttached: true,
        isSceneForegroundActive: true,
        isChatVisible: true,
        isNavigationStable: true,
        isInteractiveDismissalActive: false
    )

    var allowsRecovery: Bool {
        isComposerFirstResponder &&
            isComposerAttached &&
            isSceneForegroundActive &&
            isChatVisible &&
            isNavigationStable &&
            !isInteractiveDismissalActive
    }
}

struct ChatComposerFirstFocusRecoveryState: Equatable {
    private enum Phase: Equatable {
        case idle
        case editing
        case presenting
        case retryConsumed
        case completed
    }

    private var phase: Phase = .idle

    mutating func noteEditingBegan() {
        guard phase == .idle else { return }
        phase = .editing
    }

    mutating func noteEditingEnded() {
        switch phase {
        case .completed:
            break
        case .retryConsumed:
            phase = .completed
        case .idle, .editing, .presenting:
            phase = .idle
        }
    }

    mutating func noteKeyboardWillShow(isComposerFirstResponder: Bool) {
        guard isComposerFirstResponder, phase == .editing else { return }
        phase = .presenting
    }

    mutating func noteKeyboardDidShow(isComposerFirstResponder: Bool) {
        guard isComposerFirstResponder else { return }
        phase = .completed
    }

    mutating func consumeRetryOnKeyboardWillHide(
        eligibility: ChatComposerFirstFocusRecoveryEligibility
    ) -> Bool {
        guard phase == .presenting else {
            return false
        }
        let shouldRetry = eligibility.allowsRecovery
        phase = shouldRetry ? .retryConsumed : .completed
        return shouldRetry
    }

    var allowsScheduledRecovery: Bool {
        phase == .retryConsumed
    }
}

extension ChatViewController {

    @objc
    internal func showImagePicker() {
        NSLog("ATTACHMENT_TAP event=show_image_picker_entry presented=%@", String(describing: self.presentedViewController))
        self.view.endEditing(false)
#if DEBUG
        if let entryHandler = self.chatAttachmentPickerEntryHandlerForTesting {
            entryHandler()
            return
        }
#endif
        DispatchQueue.main.async {
            guard self.chatAttachmentFlowCoordinator == nil else {
                NSLog("ATTACHMENT_TAP event=blocked reason=coordinator_active")
                return
            }
            guard let account = AccountManager.shared.find(for: self.owner) else {
                NSLog("ATTACHMENT_TAP event=blocked reason=account_missing")
                self.presentChatAttachmentError(
                    "File transfer is unavailable for this account."
                        .localizeString(
                            id: "media_picker_error_upload_unavailable",
                            arguments: []
                        )
                )
                return
            }
            let availabilityState = account.cloudStorage.availabilityRelay.value
            let entryPlan = ChatAttachmentPickerEntryPlan.make(
                isTelegramAttachmentPickerEnabled: CommonConfigManager.shared.config.use_telegram_attachment_picker,
                availabilityState: availabilityState
            )
            let availabilityDiagnostic: String
            switch availabilityState {
            case .discovering:
                availabilityDiagnostic = "discovering"
            case .authorizing:
                availabilityDiagnostic = "authorizing"
            case .ready:
                availabilityDiagnostic = "ready"
            case .unsupported:
                availabilityDiagnostic = "unsupported"
            case .retryableFailure(let stage, _):
                availabilityDiagnostic = "retryable-\(stage.rawValue)"
            }
            NSLog(
                "ATTACHMENT_TAP event=route_resolved presents_picker=%@ resumes_availability=%@ availability=%@ presented=%@",
                entryPlan.presentsPicker.description,
                entryPlan.resumesAvailability.description,
                availabilityDiagnostic,
                String(describing: self.presentedViewController)
            )

            if entryPlan.resumesAvailability {
                account.cloudStorage.resumeAvailabilityWorkIfNeeded(
                    stream: account.xmppStream,
                    disco: account.disco
                )
            }
            guard entryPlan.presentsPicker else { return }
            self.presentTelegramAttachmentFlow()
        }
    }

    private func presentTelegramAttachmentFlow() {
        guard self.chatAttachmentFlowCoordinator == nil else {
            return
        }
        NSLog("ATTACHMENT_TAP event=coordinator_create")
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

    private func presentChatAttachmentError(_ message: String) {
        self.view.makeToast(
            message,
            duration: 2,
            image: imageLiteral("exclamationmark.circle"),
            danger: true
        )
    }
    
    @objc
    func keyboardWillChangeFrameNotification(_ notification: Notification) {
        self.handleKeyboardFrameChange(notification)
    }
    
    @objc
    func keyboardWillShowNotification(_ notification: Notification) {
        self.composerFirstFocusRecoveryState.noteKeyboardWillShow(
            isComposerFirstResponder:
                self.xabberInputView?.textField.isFirstResponder == true
        )
        self.handleKeyboardFrameChange(notification)
    }

    @objc
    func keyboardDidShowNotification(_ notification: Notification) {
        self.composerFirstFocusRecoveryState.noteKeyboardDidShow(
            isComposerFirstResponder:
                self.xabberInputView?.textField.isFirstResponder == true
        )
        guard !self.composerFirstFocusRecoveryState.allowsScheduledRecovery else {
            return
        }
        self.composerFirstFocusRecoveryWorkItem?.cancel()
        self.composerFirstFocusRecoveryWorkItem = nil
    }

    @objc func keyboardWillHideNotification(_ notification: NSNotification) {
        self.handleKeyboardFrameChange(notification as Notification)
        let eligibility = self.composerFirstFocusRecoveryEligibility()
        guard self.composerFirstFocusRecoveryState
                .consumeRetryOnKeyboardWillHide(eligibility: eligibility) else {
            return
        }
        self.scheduleComposerFirstFocusRecovery(notification: notification)
    }

    private func composerFirstFocusRecoveryEligibility()
        -> ChatComposerFirstFocusRecoveryEligibility {
        let textField = self.xabberInputView?.textField
        let window = textField?.window
        let navigationController = self.navigationController
        let isTopChat = navigationController?.topViewController === self ||
            navigationController == nil
        let isVisible = self.viewIfLoaded?.window != nil && isTopChat
        let isNavigationStable =
            !self.isNavigationTransitionActive &&
            self.transitionCoordinator == nil &&
            navigationController?.transitionCoordinator == nil &&
            self.presentedViewController == nil &&
            navigationController?.presentedViewController == nil &&
            !self.inSearchMode.value &&
            self.xabberInputView?.state == .normal
        let isInteractiveDismissalActive =
            self.messagesCollectionView.isTracking ||
            self.messagesCollectionView.isDragging ||
            self.messagesCollectionView.isDecelerating
        return ChatComposerFirstFocusRecoveryEligibility(
            isComposerFirstResponder: textField?.isFirstResponder == true,
            isComposerAttached: window != nil,
            isSceneForegroundActive:
                window?.windowScene?.activationState == .foregroundActive,
            isChatVisible: isVisible,
            isNavigationStable: isNavigationStable,
            isInteractiveDismissalActive: isInteractiveDismissalActive
        )
    }

    private func scheduleComposerFirstFocusRecovery(
        notification: NSNotification
    ) {
        self.composerFirstFocusRecoveryWorkItem?.cancel()
        let animationDuration =
            (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey]
                as? NSNumber)?.doubleValue ?? 0
        let delay = min(max(animationDuration, 0.05), 0.5)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.composerFirstFocusRecoveryWorkItem = nil
            guard self.composerFirstFocusRecoveryState.allowsScheduledRecovery,
                  self.composerFirstFocusRecoveryEligibility().allowsRecovery,
                  let textField = self.xabberInputView?.textField else {
                return
            }
            // The captured failure kept this view as first responder. Reload
            // the invalid system session, then repeat the activation that
            // succeeded on the user's second tap.
            textField.reloadInputViews()
            _ = textField.becomeFirstResponder()
        }
        self.composerFirstFocusRecoveryWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + delay,
            execute: workItem
        )
    }

    internal static func keyboardOverlapHeight(viewBounds: CGRect, keyboardFrameInView: CGRect) -> CGFloat {
        guard viewBounds.width > 0,
              viewBounds.height > 0,
              !keyboardFrameInView.isEmpty,
              keyboardFrameInView.maxY >= viewBounds.maxY else {
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
        let diagnostics = ChatComposerFirstFocusDiagnostics.shared
        let diagnosticSpan = diagnostics.beginSpan(
            stage: .appFrameHandlerBegin
        )
        defer {
            diagnostics.endSpan(
                diagnosticSpan,
                stage: .appFrameHandlerEnd
            )
        }
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
            let inputMetrics = self.updateChatInputViewForCurrentKeyboardLayout(
                visibleKeyboardHeight: keyboardVisibleHeight
            )
            self.applyChatComposerFrameUpdate(
                inputHeight: inputMetrics.collectionObstructionHeight,
                source: .keyboardFrame,
                wasNearBottom: wasNearBottom,
                visibleAnchor: visibleAnchor
            )
        }

        let usesInteractiveDismissMode =
            self.messagesCollectionView.keyboardDismissMode == .interactive
        let isInteractiveKeyboardUpdate =
            (self.isChatSearchInputKeyboardOwned && usesInteractiveDismissMode) ||
            ChatKeyboardMotionPolicy.isInteractiveUpdate(
                usesInteractiveDismissMode: usesInteractiveDismissMode,
                isTracking: self.messagesCollectionView.isTracking,
                isDragging: self.messagesCollectionView.isDragging
            )
        let shouldAnimateKeyboardMutation = ChatSearchMotionMutationPolicy.shouldAnimate(
            requestedAnimated: duration > 0,
            isNavigationTransitionActive: self.isNavigationTransitionActive,
            isPreparingFirstFrame: self.isPreparingStackedNavigationPresentation,
            isInteractiveKeyboardUpdate: isInteractiveKeyboardUpdate
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
        presentChatAttachmentError(
            "Unable to open attachment picker.".localizeString(
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
