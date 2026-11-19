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

final class ChatStickerKeyboardInputView: UIInputView {
    var panelHeight: CGFloat {
        didSet {
            guard panelHeight != oldValue else { return }
            invalidateIntrinsicContentSize()
        }
    }

    init(width: CGFloat, height: CGFloat) {
        panelHeight = height
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: height), inputViewStyle: .keyboard)
        allowsSelfSizing = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: panelHeight)
    }
}

final class ChatStickerKeyboardInputController: UIInputViewController {
    let keyboard: ChatStickerKeyboardInputView

    init(keyboard: ChatStickerKeyboardInputView) {
        self.keyboard = keyboard
        super.init(nibName: nil, bundle: nil)
        inputView = keyboard
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func embed(_ panel: ChatStickerPickerViewController) {
        addChild(panel)
        let panelView = panel.view!
        panelView.translatesAutoresizingMaskIntoConstraints = false
        keyboard.addSubview(panelView)
        NSLayoutConstraint.activate([
            panelView.leadingAnchor.constraint(equalTo: keyboard.leadingAnchor),
            panelView.trailingAnchor.constraint(equalTo: keyboard.trailingAnchor),
            panelView.topAnchor.constraint(equalTo: keyboard.topAnchor),
            panelView.bottomAnchor.constraint(equalTo: keyboard.bottomAnchor)
        ])
        panel.didMove(toParent: self)
    }
}

final class ChatStickerKeyboardResponder: UIView, UIKeyInput {
    let keyboardController: ChatStickerKeyboardInputController

    init(keyboardController: ChatStickerKeyboardInputController) {
        self.keyboardController = keyboardController
        super.init(frame: .zero)
        accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var canBecomeFirstResponder: Bool { true }
    override var inputViewController: UIInputViewController? { keyboardController }

    var hasText: Bool { false }
    func insertText(_ text: String) {}
    func deleteBackward() {}
}

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
        let context = self.makeAttachmentFlowContext()
        let coordinator = ChatAttachmentFlowCoordinator(
            presentingViewController: self,
            context: context,
            scheduledMode: .schedule(
                canSchedule: { [weak self] in
                    guard let self, self.isCurrentScheduleAttachmentContext(context) else { return false }
                    return self.scheduledMessageService.validateScheduledAttachmentRoute(
                        owner: context.owner, conversation: context.jid, conversationType: context.conversationType
                    ) == nil
                },
                submit: { [weak self] references, caption, date, completion in
                    guard let self, self.isCurrentScheduleAttachmentContext(context) else {
                        completion(.failure(.sendRejected))
                        return
                    }
                    ChatScheduledMessageSendCoordinator(service: self.scheduledMessageService).scheduleAttachments(
                        references, caption: caption, context: context, deliverAt: date, completion: completion
                    )
                },
                didSchedule: { [weak self] in
                    guard let self, self.isCurrentScheduleAttachmentContext(context) else { return }
                    self.refreshScheduledMessagesComposerButtonState()
                    self.presentScheduledMessagesIfVisible()
                },
                review: { [weak self] presenter in
                    guard let self, self.isCurrentScheduleAttachmentContext(context) else { return }
                    self.openScheduledMessagesModal(from: presenter)
                }
            )
        )
        coordinator.delegate = self
        self.chatAttachmentFlowCoordinator = coordinator
        coordinator.start()
    }

    private func isCurrentScheduleAttachmentContext(_ context: ChatAttachmentFlowContext) -> Bool {
        self.owner == context.owner && self.jid == context.jid && self.conversationType == context.conversationType
    }

    private func presentChatAttachmentError(_ message: String) {
        self.view.makeToast(
            message,
            duration: 2,
            image: imageLiteral("exclamationmark.circle"),
            danger: true
        )
    }

    var inlineStickerPanelContentHeight: CGFloat {
        ChatStickerPanelLayout.contentHeight(
            viewHeight: view.bounds.height,
            topSafeAreaHeight: view.safeAreaInsets.top,
            bottomSafeAreaHeight: view.safeAreaInsets.bottom,
            dockedKeyboardHeight: lastDockedStickerPanelKeyboardHeight
        )
    }

    var isShowingStickerPackSettings: Bool {
        guard let settings = stickerPackSettingsController,
              let stack = navigationController?.viewControllers,
              let chatIndex = stack.firstIndex(where: { $0 === self }),
              let settingsIndex = stack.firstIndex(where: { $0 === settings }) else {
            return false
        }
        return settingsIndex == chatIndex + 1
    }

    func installInlineStickerPanel(_ panel: ChatStickerPickerViewController) {
        inlineStickerPanel = panel
        if #available(iOS 26.0, *),
           traitCollection.userInterfaceIdiom == .phone,
           view.window != nil {
            let height = inlineStickerPanelContentHeight + view.safeAreaInsets.bottom
            let keyboard = ChatStickerKeyboardInputView(width: view.bounds.width, height: height)
            // Keep the picker in the keyboard's controller hierarchy when UIKit moves it to its input window.
            let keyboardController = ChatStickerKeyboardInputController(keyboard: keyboard)
            let responder = ChatStickerKeyboardResponder(keyboardController: keyboardController)
            view.addSubview(responder)
            stickerKeyboardResponder = responder
            panel.setKeyboardHostBottomInset(view.safeAreaInsets.bottom)
            keyboardController.embed(panel)
        } else {
            attachStickerPanelToChat(panel)
        }
    }

    private func attachStickerPanelToChat(_ panel: ChatStickerPickerViewController) {
        addChild(panel)
        panel.setKeyboardHostBottomInset(nil)
        let panelView = panel.view!
        panelView.isHidden = true
        panelView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panelView)
        let height = panelView.heightAnchor.constraint(
            equalToConstant: inlineStickerPanelContentHeight + view.safeAreaInsets.bottom
        )
        NSLayoutConstraint.activate([
            panelView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panelView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panelView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            height
        ])
        inlineStickerPanelHeightConstraint = height
        panel.didMove(toParent: self)
        UIView.performWithoutAnimation {
            view.layoutIfNeeded()
            panelView.layoutIfNeeded()
        }
    }

    func suspendStickerKeyboard() {
        _ = stickerKeyboardResponder?.resignFirstResponder()
    }

    func restoreStickerKeyboardIfNeeded() {
        guard isInlineStickerPanelVisible, stickerKeyboardInputView != nil,
              viewIfLoaded?.window != nil, presentedViewController == nil,
              navigationController == nil || navigationController?.topViewController === self else { return }
        _ = stickerKeyboardResponder?.becomeFirstResponder()
    }

    func setInlineStickerPanelVisible(
        _ visible: Bool,
        focusComposer: Bool = false,
        animated: Bool = true
    ) {
        guard let panel = inlineStickerPanel, let panelView = panel.viewIfLoaded,
              let inputView = xabberInputView,
              isInlineStickerPanelVisible != visible else { return }
        let wasNearBottom = isNearBottom()
        let historyAnchor = wasNearBottom ? nil : capturePagingAnchorIfNeeded(direction: .older)
        let height = inlineStickerPanelContentHeight + view.safeAreaInsets.bottom
        let offscreen = CGAffineTransform(translationX: 0, y: height)
        inlineStickerPanelHeightConstraint?.constant = height
        stickerKeyboardInputView?.panelHeight = height
        isInlineStickerPanelVisible = visible
        panelView.isUserInteractionEnabled = visible
        panelView.accessibilityElementsHidden = !visible
        if visible {
            composerFirstFocusRecoveryWorkItem?.cancel()
            composerFirstFocusRecoveryWorkItem = nil
            lastAppliedChatKeyboardLayoutSignature = nil
            currentChatKeyboardVisibleHeight = 0
            if let responder = stickerKeyboardResponder, !responder.becomeFirstResponder() {
                panel.willMove(toParent: nil)
                panelView.removeFromSuperview()
                panel.removeFromParent()
                responder.removeFromSuperview()
                stickerKeyboardResponder = nil
                attachStickerPanelToChat(panel)
            }
            if stickerKeyboardInputView == nil {
                // Settle the geometry before moving the panel, including after a resize while closed.
                if panelView.isHidden {
                    UIView.performWithoutAnimation {
                        panelView.transform = .identity
                        view.layoutIfNeeded()
                        panelView.layoutIfNeeded()
                        panelView.transform = offscreen
                        panelView.isHidden = false
                    }
                }
                view.endEditing(true)
            }
        }
        messagesCollectionView.keyboardDismissMode =
            visible && stickerKeyboardInputView != nil ? .none : .interactive
        inputView.isHidden = visible
        if !visible {
            if focusComposer {
                let selection = inputView.textField.selectedRange
                if inputView.textField.becomeFirstResponder() {
                    inputView.textField.selectedRange = selection
                } else {
                    suspendStickerKeyboard()
                }
            } else {
                suspendStickerKeyboard()
            }
        }

        let updates = {
            if self.stickerKeyboardInputView == nil {
                panelView.transform = visible ? .identity : offscreen
            }
            self.applyChatComposerFrameUpdate(
                inputHeight: self.currentChatComposerKeyboardLayoutMetrics().collectionObstructionHeight,
                source: .stickerPanel,
                wasNearBottom: wasNearBottom,
                visibleAnchor: historyAnchor
            )
            self.view.layoutIfNeeded()
        }
        let completion: (Bool) -> Void = { [weak self, weak panelView] _ in
            guard let self, let panelView, self.inlineStickerPanel?.viewIfLoaded === panelView,
                  self.isInlineStickerPanelVisible == visible else { return }
            if self.stickerKeyboardInputView == nil {
                panelView.isHidden = !visible
            }
            if visible, UIAccessibility.isVoiceOverRunning {
                UIAccessibility.post(notification: .layoutChanged, argument: panelView)
            }
        }
        if animated && !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(
                withDuration: 0.25,
                delay: 0,
                options: [.beginFromCurrentState, .curveEaseInOut, .allowUserInteraction],
                animations: updates,
                completion: completion
            )
        } else {
            UIView.performWithoutAnimation(updates)
            completion(true)
        }
    }

    func updateInlineStickerPanelLayout() {
        guard isInlineStickerPanelVisible else { return }
        let bottomInset = view.safeAreaInsets.bottom
        if stickerKeyboardInputView != nil {
            inlineStickerPanel?.setKeyboardHostBottomInset(bottomInset)
        }
        let obstruction = inlineStickerPanelContentHeight + bottomInset
        let previousHeight = stickerKeyboardInputView?.panelHeight ?? inlineStickerPanelHeightConstraint?.constant
        guard let previousHeight, abs(previousHeight - obstruction) > 0.5 else { return }
        let wasNearBottom = isNearBottom()
        let historyAnchor = wasNearBottom ? nil : capturePagingAnchorIfNeeded(direction: .older)
        inlineStickerPanelHeightConstraint?.constant = obstruction
        stickerKeyboardInputView?.panelHeight = obstruction
        applyChatComposerFrameUpdate(
            inputHeight: obstruction,
            source: .stickerPanel,
            wasNearBottom: wasNearBottom,
            visibleAnchor: historyAnchor
        )
    }

    func removeInlineStickerPanel() {
        guard let panel = inlineStickerPanel else { return }
        let wasVisible = isInlineStickerPanelVisible
        isInlineStickerPanelVisible = false
        suspendStickerKeyboard()
        panel.willMove(toParent: nil)
        panel.viewIfLoaded?.removeFromSuperview()
        panel.removeFromParent()
        stickerKeyboardResponder?.removeFromSuperview()
        stickerKeyboardResponder = nil
        inlineStickerPanel = nil
        inlineStickerPanelHeightConstraint = nil
        stickerPackSettingsController = nil
        messagesCollectionView.keyboardDismissMode = .interactive
        xabberInputView?.isHidden = false
        if wasVisible {
            updateChatCollectionInsets()
        }
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
            !self.isInlineStickerPanelVisible &&
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
        guard !self.isInlineStickerPanelVisible,
              let userInfo = notification.userInfo,
              let frameValue = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue,
              self.xabberInputView != nil else {
            return
        }

        let keyboardFrame = view.convert(frameValue.cgRectValue, from: view.window)
        let keyboardVisibleHeight = Self.keyboardOverlapHeight(
            viewBounds: view.bounds, keyboardFrameInView: keyboardFrame
        )
        if !self.isChatSearchInputKeyboardOwned, self.xabberInputView.textField.isFirstResponder,
           let dockedHeight = ChatStickerPanelLayout.dockedKeyboardHeight(
               in: view.bounds, keyboardFrame: keyboardFrame
           ) {
            self.lastDockedStickerPanelKeyboardHeight = dockedHeight
        }
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
        guard let retainedCoordinator = chatAttachmentFlowCoordinator,
              retainedCoordinator === coordinator else { return }
        clearChatAttachmentFlowCoordinatorIfNeeded(coordinator)
        let context = coordinator.context
        guard self.owner == context.owner, self.jid == context.jid,
              self.conversationType == context.conversationType,
              self.attachedMessagesIds.value == context.forwardedMessageIds,
              self.composerForwardIntent == context.forwardIntent else { return }
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
