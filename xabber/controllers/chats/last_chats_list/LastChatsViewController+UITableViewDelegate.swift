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
import RealmSwift
import CocoaLumberjack

extension LastChatsViewController: UITableViewDelegate {
    private static var unreadMentionCandidateLimit: Int { 8 }

    private static func notificationMetadataNeedle(key: String, value: String) -> String? {
        guard let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: .fragmentsAllowed
        ),
        let encodedValue = String(data: data, encoding: .utf8) else {
            return nil
        }

        return "\"\(key)\":\(encodedValue)"
    }

    func tableView(_ tableView: UITableView, canFocusRowAt indexPath: IndexPath) -> Bool {
        false
    }

    func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool {
        false
    }

    internal static func unreadMentionOpenRequest(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        in realm: Realm
    ) -> ChatOpenMessageRequest? {
        guard conversationType == .group,
              let chat = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: jid,
                    owner: owner,
                    conversationType: conversationType
                )
              ),
              let mentionId = chat.mentionId,
              mentionId.isNotEmpty else {
            return nil
        }

        let archivedIdNeedle = Self.notificationMetadataNeedle(
            key: "sourceArchivedId",
            value: mentionId
        )
        let candidates: [NotificationStorageItem]
        let hasPersistedCandidate: Bool
        if let archivedIdNeedle {
            let scopedCandidates = realm.objects(NotificationStorageItem.self)
                .filter(
                    "owner == %@ AND category_ == %@ AND associatedJid == %@ AND metadata_ CONTAINS %@",
                    owner,
                    XMPPNotificationsManager.Category.mention.rawValue,
                    jid,
                    archivedIdNeedle
                )
            candidates = Array(
                scopedCandidates
                    .filter("isRead == false")
                    .sorted(by: [
                        SortDescriptor(keyPath: "date", ascending: false),
                        SortDescriptor(keyPath: "primary", ascending: false)
                    ])
                    .prefix(Self.unreadMentionCandidateLimit)
            )
            hasPersistedCandidate = candidates.isNotEmpty || scopedCandidates.first != nil
        } else {
            candidates = []
            hasPersistedCandidate = false
        }

        let exactCandidates = candidates.filter {
            ($0.sourceConversationType ?? .group) == .group
                && $0.sourceChatJid == jid
                && $0.sourceArchivedId == mentionId
        }
        let notification = exactCandidates.first {
            $0.mentionLinkStatus != .invalidated
                && $0.mentionLinkStatus != .missing
        }
        if notification == nil, hasPersistedCandidate {
            return nil
        }

        let sourceDate = notification?.sourceMessageDate
            ?? notification?.date
            ?? (chat.messageDate == Date(timeIntervalSince1970: 0) ? nil : chat.messageDate)

        let request = ChatOpenMessageRequest(
            chatJid: jid,
            owner: owner,
            conversationType: conversationType,
            anchor: ChatMessageAnchorRef(
                messagePrimary: nil,
                archivedId: mentionId,
                messageId: notification?.sourceMessageId,
                authorId: notification?.sourceSenderId,
                bodyFingerprint: notification?.sourceBodyFingerprint,
                sourceDate: sourceDate
            ),
            highlight: false,
            markReadOnVisible: true,
            source: .mentionNotification
        )

        return request
    }

    internal static func initialOpenRequest(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        explicitOpenMessageRequest: ChatOpenMessageRequest?,
        in realm: Realm
    ) -> ChatOpenMessageRequest? {
        let chat = realm.object(
            ofType: LastChatsStorageItem.self,
            forPrimaryKey: LastChatsStorageItem.genPrimary(
                jid: jid,
                owner: owner,
                conversationType: conversationType
            )
        )

        guard let chat = chat else {
            guard let explicitOpenMessageRequest,
                  ChatOpenMessageRequestHandlingPolicy.shouldHonorMessageAnchorRequest(source: explicitOpenMessageRequest.source) else {
                return nil
            }
            return explicitOpenMessageRequest
        }

        let savedPosition = ChatSavedVisiblePosition(
            messagePrimary: ChatInitialPositionPolicy.normalizedId(chat.lastVisibleMessagePrimary),
            archivedId: ChatInitialPositionPolicy.normalizedId(chat.lastVisibleMessageArchivedId),
            messageId: ChatInitialPositionPolicy.normalizedId(chat.lastVisibleMessageId),
            sourceDate: chat.lastVisibleMessageDate ?? chat.messageDate
        )
        let state = ChatInitialPositionPolicy.ChatState(
            owner: owner,
            jid: jid,
            conversationType: conversationType,
            unread: chat.unread,
            syncUnreadCount: chat.syncUnreadCount,
            syncUnreadAfterId: chat.syncUnreadAfterId,
            lastReadId: chat.lastReadId,
            lastMessageId: chat.lastMessageId,
            syncSnapshotLastArchiveId: chat.syncSnapshotLastArchiveId,
            messageDate: chat.messageDate,
            savedPosition: savedPosition.hasAnchor ? savedPosition : nil,
            savedAtLastMessageId: chat.lastVisiblePositionSavedAtLastMessageId,
            savedAtSnapshotLastArchiveId: chat.lastVisiblePositionSavedAtSnapshotLastArchiveId
        )

        let decision = ChatInitialPositionPolicy.decision(for: state, explicitRequest: explicitOpenMessageRequest)
        let result: ChatOpenMessageRequest?
        switch decision {
        case .open(let request):
            result = request
        case .bottom:
            result = nil
        }
        return result
    }

    internal func unreadMentionOpenRequest(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType
    ) -> ChatOpenMessageRequest? {
        do {
            let realm = try WRealm.safe()
            return Self.unreadMentionOpenRequest(
                owner: owner,
                jid: jid,
                conversationType: conversationType,
                in: realm
            )
        } catch {
            DDLogDebug("LastChatsViewController: \(#function). \(error.localizedDescription)")
            return nil
        }
    }

    internal func initialOpenRequest(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        explicitOpenMessageRequest: ChatOpenMessageRequest? = nil
    ) -> ChatOpenMessageRequest? {
        do {
            let realm = try WRealm.safe()
            return Self.initialOpenRequest(
                owner: owner,
                jid: jid,
                conversationType: conversationType,
                explicitOpenMessageRequest: explicitOpenMessageRequest,
                in: realm
            )
        } catch {
            DDLogDebug("LastChatsViewController: \(#function). \(error.localizedDescription)")
            guard let explicitOpenMessageRequest,
                  ChatOpenMessageRequestHandlingPolicy.shouldHonorMessageAnchorRequest(source: explicitOpenMessageRequest.source) else {
                return nil
            }
            return explicitOpenMessageRequest
        }
    }

    internal static func voicePlayerOpenRequest(route: VoiceMessagePlaybackRoute) -> ChatOpenMessageRequest {
        ChatOpenMessageRequest(
            chatJid: route.jid,
            owner: route.owner,
            conversationType: route.conversationType,
            anchor: ChatMessageAnchorRef(
                messagePrimary: route.messagePrimary,
                archivedId: route.archivedId,
                messageId: nil,
                authorId: nil,
                bodyFingerprint: nil,
                sourceDate: route.sourceDate
            ),
            highlight: true,
            markReadOnVisible: false,
            source: .voicePlayer
        )
    }

    private func applyInitialOpenIntent(
        to chatVc: ChatViewController,
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        explicitOpenMessageRequest: ChatOpenMessageRequest? = nil
    ) {
        if let initialRequest = self.initialOpenRequest(
            owner: owner,
            jid: jid,
            conversationType: conversationType,
            explicitOpenMessageRequest: explicitOpenMessageRequest
        ) {
            chatVc.queueOpenMessageRequest(initialRequest)
            return
        }

        if chatVc.pendingOpenMessageRequest != nil || chatVc.activeAnchorExecutionState != nil {
            chatVc.performPendingOpenMessageRequestIfNeeded()
            return
        }

        if !chatVc.pendingForceLatestOpen,
           ChatOpenMessageRequestHandlingPolicy.shouldForceLatestOnOpen() {
            chatVc.requestForceLatestOpen(animated: false)
        }
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if isShowingSearchResults {
            return 84
        }
        guard let item = self.item(at: indexPath) else { return 0 }
        switch item.specialMessageKind {
            case .none: return 84
            default: return 48
        }
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if isShowingSearchResults {
            guard let item = chatSearchResultsController.item(at: indexPath) else { return }
            openSearchResult(item)
            return
        }
        if self.showSkeleton.value {
            return
        }
        guard let item = self.item(at: indexPath) else {
            return
        }
        switch item.specialMessageKind {
            case .contact:
                self.leftMenuSelectRootCategoryDelegate?.selectRootScreenAndCategory(screen: "contacts", category: "show_all_contacts")
            case .invite:
                self.leftMenuSelectRootCategoryDelegate?.selectRootScreenAndCategory(screen: "groups", category: "show_all_invites")
            case .premiumPromotion:
                SubscribtionsPresenter().present(
                    animated: true,
                    owner: item.owner,
                    parent: self,
                    modalPresentationStyle: .pageSheet
                )
            case .none:
                let openMessageRequest = item.conversationType == .group
                    ? self.unreadMentionOpenRequest(
                        owner: item.owner,
                        jid: item.jid,
                        conversationType: item.conversationType
                    )
                    : nil
#if DEBUG || CHAT_PERFORMANCE_LAB
                self.performanceChatRowSelectionObserver?(
                    item,
                    indexPath,
                    openMessageRequest
                )
#endif
                self.stackNewChat(
                    owner: item.owner,
                    jid: item.jid,
                    conversationType: item.conversationType,
                    openMessageRequest: openMessageRequest
                )
        }
    }
    
    private func chatNavigationDestination(
        _ chat: ChatViewController,
        matches target: LastChatsNavigationSingleFlightCoordinator.Target
    ) -> Bool {
        chat.owner == target.owner &&
            chat.jid == target.jid &&
            chat.conversationType == target.conversationType
    }

    private func visibleChatNavigationDestination(
        in navigationController: UINavigationController?,
        matching target: LastChatsNavigationSingleFlightCoordinator.Target
    ) -> ChatViewController? {
        guard let chat = navigationController?.topViewController as? ChatViewController,
              chatNavigationDestination(chat, matches: target) else {
            return nil
        }
        return chat
    }

    @discardableResult
    internal func acceptChatOpenIntent(
        on destination: ChatViewController,
        target: LastChatsNavigationSingleFlightCoordinator.Target,
        openMessageRequest: ChatOpenMessageRequest?,
        navigationSource explicitNavigationSource: ChatOpenNavigationSource? = nil,
        configure configureCallback: ((ChatViewController?) -> Void)?
    ) -> LastChatsResolvedChatOpenIntent {
        let navigationSource = resolvedNavigationSource(
            explicitNavigationSource,
            request: openMessageRequest
        )
        let destinationIdentifier = ObjectIdentifier(destination)
        let retainsExistingNotificationOwnership =
            chatOpenIntentOwnership?.target == target &&
            chatOpenIntentOwnership?.destinationIdentifier == destinationIdentifier &&
            chatOpenIntentOwnership?.navigationSource == .notification
        let ownershipNavigationSource: ChatOpenNavigationSource =
            retainsExistingNotificationOwnership || navigationSource == .notification
                ? .notification
                : .standard
        let intent: LastChatsResolvedChatOpenIntent
        if let ownership = chatOpenIntentOwnership,
           ownership.target == target,
           ownership.destinationIdentifier == destinationIdentifier,
           openMessageRequest == nil || ownership.intent == .message(openMessageRequest!) {
            intent = ownership.intent
        } else {
            let resolvedRequest: ChatOpenMessageRequest?
            if let chatOpenMessageRequestResolverOverride {
                resolvedRequest = chatOpenMessageRequestResolverOverride(
                    target,
                    openMessageRequest
                )
            } else {
                resolvedRequest = initialOpenRequest(
                    owner: target.owner,
                    jid: target.jid,
                    conversationType: target.conversationType,
                    explicitOpenMessageRequest: openMessageRequest
                )
            }
            intent = resolvedRequest.map(LastChatsResolvedChatOpenIntent.message)
                ?? .latest
        }

        let tracePurpose: ChatOpenPerformanceTracePurpose
        if ownershipNavigationSource == .notification {
            tracePurpose = .notificationRoute
        } else {
            switch intent {
            case .message:
                tracePurpose = .explicitTargetRoute
            case .latest:
                tracePurpose = .normalRoute
            }
        }
        let traceRequest: ChatOpenMessageRequest?
        switch intent {
        case .message(let request):
            traceRequest = request
        case .latest:
            traceRequest = nil
        }
        _ = destination.acceptChatOpenPerformanceTrace(
            purpose: tracePurpose,
            semanticTargetFingerprint:
                destination.chatOpenPerformanceSemanticTargetFingerprint(
                    for: traceRequest
                )
        )
        configureCallback?(destination)

        if chatOpenIntentOwnership?.target != target ||
            chatOpenIntentOwnership?.destinationIdentifier != destinationIdentifier ||
            chatOpenIntentOwnership?.intent != intent {
            chatOpenIntentDeliveryHandler(intent, destination)
        }
        updateChatOpenIntentOwnershipIfNeeded(
            target: target,
            destinationIdentifier: destinationIdentifier,
            intent: intent,
            navigationSource: ownershipNavigationSource
        )
        if ownershipNavigationSource == .notification {
            destination.chatOpenStableVisibilityAcknowledgementHandler = {
                [weak self, weak destination] context, semanticTarget in
                guard let self, let destination,
                      destination.chatOpenPerformanceTraceContext == context,
                      destination.chatOpenPerformanceTraceTargetFingerprint ==
                        semanticTarget,
                      destination.viewIfLoaded?.window != nil,
                      destination.navigationController?.topViewController ===
                        destination,
                      UIApplication.shared.applicationState == .active,
                      let ownership = self.chatOpenIntentOwnership,
                      ownership.target == target,
                      ownership.destinationIdentifier == destinationIdentifier,
                      ownership.intent == intent,
                      ownership.navigationSource == .notification else {
                    return
                }
                self.enqueuePendingMessageNotificationRouteWakeup()
            }
        } else {
            destination.chatOpenStableVisibilityAcknowledgementHandler = nil
        }
        return intent
    }

    private func resolvedNavigationSource(
        _ navigationSource: ChatOpenNavigationSource?,
        request: ChatOpenMessageRequest?
    ) -> ChatOpenNavigationSource {
        navigationSource ?? (
            request?.source == .pushNotification
                ? .notification
                : .standard
        )
    }

    private func expandedSplitDetailChat(
        in splitViewController: UISplitViewController
    ) -> ChatViewController? {
        let secondary = splitViewController.viewController(for: .secondary)
        if let navigationController = secondary as? UINavigationController {
            return navigationController.topViewController as? ChatViewController
        }
        return secondary as? ChatViewController
    }

    private func expandedSplitDetailChat(
        matching target: LastChatsNavigationSingleFlightCoordinator.Target,
        in splitViewController: UISplitViewController
    ) -> ChatViewController? {
        guard let chat = expandedSplitDetailChat(in: splitViewController),
              chatNavigationDestination(chat, matches: target) else {
            return nil
        }
        return chat
    }

    private func expandedSplitSecondarySnapshot(
        in splitViewController: UISplitViewController
    ) -> LastChatsExpandedSplitSecondarySnapshot {
        let container = splitViewController.viewController(for: .secondary)
        let top = (container as? UINavigationController)?.topViewController
            ?? container
        return LastChatsExpandedSplitSecondarySnapshot(
            container: container,
            topViewController: top
        )
    }

    private func sameControllerIdentity(
        _ lhs: UIViewController?,
        _ rhs: UIViewController?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return lhs === rhs
        default:
            return false
        }
    }

    private func expandedSplitPresentationState(
        container: UIViewController?,
        topViewController: UIViewController?
    ) -> LastChatsExpandedSplitPresentationState {
        if let expandedSplitPresentationStateOverride {
            return expandedSplitPresentationStateOverride(
                container,
                topViewController
            )
        }
        return LastChatsExpandedSplitPresentationState(
            hasActiveTransition:
                container?.transitionCoordinator != nil ||
                topViewController?.transitionCoordinator != nil,
            hasPresentedModal:
                container?.presentedViewController != nil ||
                topViewController?.presentedViewController != nil
        )
    }

    private func isActiveExpandedSplitSupplementary(
        in splitViewController: UISplitViewController
    ) -> Bool {
        let supplementary = splitViewController.viewController(for: .supplementary)
        if supplementary === self {
            return true
        }
        guard let navigationController = supplementary as? UINavigationController else {
            return false
        }
        return navigationController.topViewController === self
    }

    private func stableExpandedSplitDetailChat(
        matching target: LastChatsNavigationSingleFlightCoordinator.Target,
        in splitViewController: UISplitViewController
    ) -> ChatViewController? {
        guard chatNavigationRouteResolver(self) == .splitDetailReplacement,
              isActiveExpandedSplitSupplementary(in: splitViewController),
              let chat = expandedSplitDetailChat(
                matching: target,
                in: splitViewController
              ) else {
            return nil
        }
        let snapshot = expandedSplitSecondarySnapshot(in: splitViewController)
        let detailPresentationState = expandedSplitPresentationState(
            container: snapshot.container,
            topViewController: snapshot.topViewController
        )
        let supplementary = splitViewController.viewController(
            for: .supplementary
        )
        let supplementaryTop = (supplementary as? UINavigationController)?
            .topViewController ?? supplementary
        let detailNavigationController = chat.navigationController
        let window = splitViewController.viewIfLoaded?.window
        let hasStableAttachment =
            UIApplication.shared.applicationState == .active &&
            window != nil &&
            window?.isHidden == false &&
            (window?.alpha ?? 0) > 0 &&
            window?.isKeyWindow == true &&
            window?.windowScene?.activationState == .foregroundActive &&
            viewIfLoaded?.window === window &&
            chat.viewIfLoaded?.window === window &&
            (expandedSplitStableVisibilityOverride?(chat) ?? true)
        guard hasStableAttachment,
              splitViewController.transitionCoordinator == nil,
              supplementary?.transitionCoordinator == nil,
              supplementaryTop?.transitionCoordinator == nil,
              navigationController?.transitionCoordinator == nil,
              detailNavigationController?.transitionCoordinator == nil,
              !detailPresentationState.hasActiveTransition,
              splitViewController.presentedViewController == nil,
              supplementary?.presentedViewController == nil,
              supplementaryTop?.presentedViewController == nil,
              navigationController?.presentedViewController == nil,
              detailNavigationController?.presentedViewController == nil,
              !detailPresentationState.hasPresentedModal else {
            return nil
        }
        return chat
    }

    private struct ExpandedSplitChatNavigationEligibility {
        let fingerprint: LastChatsExpandedSplitEligibilityFingerprint
        let canCommit: Bool
        let transitionOwner: UIViewController?
    }

    private func activeExpandedSplitTransitionOwner(
        among candidates: [UIViewController?]
    ) -> UIViewController? {
        let resolvedCandidates = candidates.compactMap { $0 }
        if let expandedSplitTransitionOwnerOverride {
            return expandedSplitTransitionOwnerOverride(resolvedCandidates)
        }
        return resolvedCandidates.first {
            $0.transitionCoordinator != nil
        }
    }

    private func expandedSplitChatNavigationEligibility(
        transaction: LastChatsExpandedSplitChatNavigationTransaction,
        splitViewController: UISplitViewController
    ) -> ExpandedSplitChatNavigationEligibility {
        let supplementary = splitViewController.viewController(
            for: .supplementary
        )
        let supplementaryTop = (supplementary as? UINavigationController)?
            .topViewController ?? supplementary
        let secondary = expandedSplitSecondarySnapshot(
            in: splitViewController
        )
        let currentAccountEpoch = chatNavigationAccountEpochResolver(
            transaction.target
        )
        let window = splitViewController.viewIfLoaded?.window
        let transitionCandidates: [UIViewController?] = [
            splitViewController,
            supplementary,
            supplementaryTop,
            navigationController,
            secondary.container,
            secondary.topViewController,
            transaction.destination.navigationController,
            transaction.destination
        ]
        let transitionOwner = activeExpandedSplitTransitionOwner(
            among: transitionCandidates
        )
        let presentedController = transitionCandidates
            .compactMap { $0?.presentedViewController }
            .first
        let supplementaryContainerIdentifier = supplementary
            .map(ObjectIdentifier.init)
        let supplementaryTopIdentifier = supplementaryTop
            .map(ObjectIdentifier.init)
        let expectedSupplementaryMatches =
            supplementaryContainerIdentifier ==
                transaction.expectedSupplementaryContainerIdentifier &&
            supplementaryTopIdentifier ==
                transaction.expectedSupplementaryTopViewControllerIdentifier
        let currentSecondaryMatches = sameControllerIdentity(
            secondary.container,
            transaction.previousSecondarySnapshot.container
        ) && sameControllerIdentity(
            secondary.topViewController,
            transaction.previousSecondarySnapshot.topViewController
        )
        let sourceIsStructurallyCurrent: Bool
        if let activationContext = transaction.activationContext {
            sourceIsStructurallyCurrent =
                activationContext.splitViewController === splitViewController &&
                expectedSupplementaryMatches &&
                activationContext.validate()
        } else {
            sourceIsStructurallyCurrent =
                expectedSupplementaryMatches &&
                isActiveExpandedSplitSupplementary(
                    in: splitViewController
                )
        }
        let hasCurrentChatConflict: Bool
        if let previousVisibleDetail = transaction.previousVisibleDetail {
            hasCurrentChatConflict = currentChatVC != nil &&
                currentChatVC !== previousVisibleDetail
        } else {
            hasCurrentChatConflict = currentChatVC != nil
        }
        let isWindowVisible = window != nil &&
            window?.isHidden == false &&
            (window?.alpha ?? 0) > 0
        let isApplicationActive =
            UIApplication.shared.applicationState == .active
        let isKeyWindow = window?.isKeyWindow == true
        let isForegroundActiveScene =
            window?.windowScene?.activationState == .foregroundActive
        let route = chatNavigationRouteResolver(self)
        let fingerprint = LastChatsExpandedSplitEligibilityFingerprint(
            route: route,
            accountEpoch: currentAccountEpoch,
            isApplicationActive: isApplicationActive,
            windowIdentifier: window.map(ObjectIdentifier.init),
            isWindowVisible: isWindowVisible,
            isKeyWindow: isKeyWindow,
            isForegroundActiveScene: isForegroundActiveScene,
            supplementaryContainerIdentifier:
                supplementaryContainerIdentifier,
            supplementaryTopIdentifier: supplementaryTopIdentifier,
            secondaryContainerIdentifier:
                secondary.container.map(ObjectIdentifier.init),
            secondaryTopIdentifier:
                secondary.topViewController.map(ObjectIdentifier.init),
            hasActiveTransition: transitionOwner != nil,
            presentedControllerIdentifier:
                presentedController.map(ObjectIdentifier.init)
        )
        let canCommit =
            route == .splitDetailReplacement &&
            transaction.accountEpoch.isExactValidMatch(
                for: currentAccountEpoch
            ) &&
            isApplicationActive &&
            isWindowVisible &&
            isKeyWindow &&
            isForegroundActiveScene &&
            sourceIsStructurallyCurrent &&
            currentSecondaryMatches &&
            transitionOwner == nil &&
            presentedController == nil &&
            !hasCurrentChatConflict
        return ExpandedSplitChatNavigationEligibility(
            fingerprint: fingerprint,
            canCommit: canCommit,
            transitionOwner: transitionOwner
        )
    }

    private func shouldCommitExpandedSplitChatNavigation(
        token: UUID,
        target: LastChatsNavigationSingleFlightCoordinator.Target,
        destination: ChatViewController,
        splitViewController: UISplitViewController
    ) -> Bool {
        guard let transaction = expandedSplitChatNavigationTransaction,
              transaction.token == token,
              transaction.target == target,
              transaction.destination === destination,
              transaction.phase == .preparing,
              chatNavigationDestination(destination, matches: target) else {
            return false
        }
        return expandedSplitChatNavigationEligibility(
            transaction: transaction,
            splitViewController: splitViewController
        ).canCommit
    }

    @discardableResult
    private func presentExpandedSplitChatNavigation(
        token: UUID,
        target: LastChatsNavigationSingleFlightCoordinator.Target,
        destination: ChatViewController,
        splitViewController: UISplitViewController,
        destinationIsPrepared: Bool
    ) -> Bool {
        guard let transaction = expandedSplitChatNavigationTransaction,
              transaction.token == token,
              transaction.target == target,
              transaction.destination === destination,
              transaction.phase == .preparing else {
            return false
        }
        let presenter: UIViewController = transaction.activationContext?
            .presentationPresenter ?? self
        expandedSplitPresentationAttemptObserver?(
            destination,
            destinationIsPrepared
        )
        let presentationHandler = destinationIsPrepared
            ? expandedSplitPreparedChatPresentationHandler
            : expandedSplitChatPresentationHandler
        let handle = presentationHandler(
            destination,
            presenter,
            { [weak self, weak destination, weak splitViewController] in
                guard let self, let destination, let splitViewController,
                      self.shouldCommitExpandedSplitChatNavigation(
                        token: token,
                        target: target,
                        destination: destination,
                        splitViewController: splitViewController
                      ) else {
                    return false
                }
                if let activationContext = self
                    .expandedSplitChatNavigationTransaction?
                    .activationContext,
                   !activationContext.commit() {
                    return false
                }
                return self.markExpandedSplitChatNavigationPresenting(
                    token: token,
                    target: target,
                    destination: destination
                )
            },
            { [weak self, weak destination, weak splitViewController] didPresent in
                guard let self, let destination, let splitViewController,
                      let transaction = self.expandedSplitChatNavigationTransaction,
                      transaction.token == token,
                      transaction.target == target,
                      transaction.destination === destination else {
                    return
                }
                if didPresent,
                   self.expandedSplitDetailChat(in: splitViewController)
                    === destination,
                   self.completeExpandedSplitChatNavigationPresentation(
                    token: token,
                    target: target,
                    destination: destination,
                    transitionOwner: splitViewController
                   ) {
                    DDLogDebug(
                        "LAST_CHATS_NAVIGATION event=splitPresented phase=presented"
                    )
                    return
                }

                guard !didPresent else {
                    let navigationSource = transaction.navigationSource
                    let validationFailure = transaction.activationContext?
                        .validationFailure
                    if validationFailure != nil {
                        _ = self.rollbackCancelledExpandedSplitSecondaryIfOwned(
                            transaction: transaction,
                            splitViewController: splitViewController
                        )
                    }
                    self.resetExpandedSplitChatNavigationTransaction(
                        restorePreviousDetail: true,
                        preserveIntentOwnership:
                            navigationSource == .notification
                    )
                    if navigationSource == .notification,
                       let transitionOwner = self
                        .expandedSplitTransitionOwner(
                            splitViewController: splitViewController,
                            destination: destination
                        ) {
                        self.schedulePendingMessageNotificationRouteRetryOrEnqueue(
                            after: transitionOwner
                        )
                    }
                    validationFailure?()
                    return
                }

                if let validationFailure = transaction.activationContext?
                    .validationFailure {
                    if transaction.phase == .presenting {
                        _ = self.rollbackCancelledExpandedSplitSecondaryIfOwned(
                            transaction: transaction,
                            splitViewController: splitViewController
                        )
                    }
                    self.resetExpandedSplitChatNavigationTransaction(
                        restorePreviousDetail: true
                    )
                    validationFailure()
                    return
                }

                let completedCancelledNativePresentation =
                    transaction.phase == .presenting
                let restoredCancelledSecondary =
                    completedCancelledNativePresentation &&
                    self.rollbackCancelledExpandedSplitSecondaryIfOwned(
                        transaction: transaction,
                        splitViewController: splitViewController
                    )
                let eligibility = self.expandedSplitChatNavigationEligibility(
                    transaction: transaction,
                    splitViewController: splitViewController
                )
                guard self.retainExpandedSplitChatNavigationForEligibilityWakeup(
                    token: token,
                    target: target,
                    destination: destination,
                    fingerprint: eligibility.fingerprint,
                    permitsOneUnchangedEligibilityRetry:
                        restoredCancelledSecondary
                ) else {
                    return
                }
                if transaction.navigationSource == .notification,
                   let transitionOwner = eligibility.transitionOwner {
                    self.schedulePendingMessageNotificationRouteRetryOrEnqueue(
                        after: transitionOwner
                    )
                } else if transaction.navigationSource == .notification,
                          completedCancelledNativePresentation {
                    self.enqueuePendingMessageNotificationRouteWakeup()
                }
            }
        )
        return registerExpandedSplitChatNavigationPreparation(
            handle,
            token: token
        )
    }

    private func expandedSplitTransitionOwner(
        splitViewController: UISplitViewController,
        destination: ChatViewController
    ) -> UIViewController? {
        let supplementary = splitViewController.viewController(
            for: .supplementary
        )
        let supplementaryTop = (supplementary as? UINavigationController)?
            .topViewController ?? supplementary
        let secondary = expandedSplitSecondarySnapshot(
            in: splitViewController
        )
        return activeExpandedSplitTransitionOwner(among: [
            splitViewController,
            supplementary,
            supplementaryTop,
            navigationController,
            secondary.container,
            secondary.topViewController,
            destination.navigationController,
            destination
        ])
    }

    /// `showStacked` installs the secondary synchronously and only later learns
    /// whether UIKit cancelled the owning native epoch. Restore the captured
    /// hierarchy only while the currently installed navigation container still
    /// owns this exact destination; a newer secondary owner always wins.
    @discardableResult
    private func rollbackCancelledExpandedSplitSecondaryIfOwned(
        transaction: LastChatsExpandedSplitChatNavigationTransaction,
        splitViewController: UISplitViewController
    ) -> Bool {
        let currentSecondary = expandedSplitSecondarySnapshot(
            in: splitViewController
        )
        guard currentSecondary.topViewController === transaction.destination,
              let currentNavigationController =
                currentSecondary.container as? UINavigationController,
              currentNavigationController.topViewController
                === transaction.destination,
              transaction.destination.navigationController
                === currentNavigationController else {
            return false
        }

        splitViewController.setViewController(
            transaction.previousSecondarySnapshot.container,
            for: .secondary
        )
        let restoredSecondary = expandedSplitSecondarySnapshot(
            in: splitViewController
        )
        let didRestore = sameControllerIdentity(
            restoredSecondary.container,
            transaction.previousSecondarySnapshot.container
        ) && sameControllerIdentity(
            restoredSecondary.topViewController,
            transaction.previousSecondarySnapshot.topViewController
        )
        if didRestore {
            // The prepared destination remains retained by the transaction,
            // but must be detached from the now off-screen provisional wrapper
            // before a later production retry wraps the same instance again.
            currentNavigationController.setViewControllers(
                [],
                animated: false
            )
        }
        return didRestore
    }

    private func beginExpandedSplitChatNavigation(
        target: LastChatsNavigationSingleFlightCoordinator.Target,
        openMessageRequest: ChatOpenMessageRequest?,
        navigationSource: ChatOpenNavigationSource,
        configure configureCallback: ((ChatViewController?) -> Void)?,
        splitViewController: UISplitViewController,
        activationContext: LastChatsExpandedSplitActivationContext? = nil
    ) -> Bool {
        ChatUIResponsivenessGate.shared.activate(
            reason: .chatOpen,
            duration: ChatUIResponsivenessGate.chatOpenHoldDuration
        )
        setSelectedChat(
            jid: target.jid,
            owner: target.owner,
            conversationType: target.conversationType,
            animated: navigationSource != .notification
        )
        let destination = expandedSplitChatDestinationFactory()
        destination.owner = target.owner
        destination.jid = target.jid
        destination.conversationType = target.conversationType
        destination.sharedPlayerPaneldelegae = self
        destination.lastChatsDisplayDelegate = self
        acceptChatOpenIntent(
            on: destination,
            target: target,
            openMessageRequest: openMessageRequest,
            navigationSource: navigationSource,
            configure: configureCallback
        )
        let token = UUID()
        let previousSecondarySnapshot = expandedSplitSecondarySnapshot(
            in: splitViewController
        )
        let supplementary = splitViewController.viewController(
            for: .supplementary
        )
        let supplementaryTop = (supplementary as? UINavigationController)?
            .topViewController ?? supplementary
        installExpandedSplitChatNavigationTransaction(
            token: token,
            target: target,
            destination: destination,
            previousVisibleDetail: expandedSplitDetailChat(in: splitViewController),
            previousSecondarySnapshot: previousSecondarySnapshot,
            accountEpoch: chatNavigationAccountEpochResolver(target),
            navigationSource: navigationSource,
            activationContext: activationContext,
            expectedSupplementaryContainerIdentifier:
                activationContext?.expectedSupplementaryContainerIdentifier
                    ?? supplementary.map(ObjectIdentifier.init),
            expectedSupplementaryTopViewControllerIdentifier:
                activationContext?
                    .expectedSupplementaryTopViewControllerIdentifier
                    ?? supplementaryTop.map(ObjectIdentifier.init)
        )
        _ = presentExpandedSplitChatNavigation(
            token: token,
            target: target,
            destination: destination,
            splitViewController: splitViewController,
            destinationIsPrepared: false
        )
        return LastChatsChatOpenAcknowledgementPolicy.shouldAcknowledge(
            navigationSource: navigationSource,
            request: openMessageRequest,
            isStableVisibleDestination: false,
            hasStableTargetAcknowledgement: false
        )
    }

    private func stackNewChatInExpandedSplit(
        target: LastChatsNavigationSingleFlightCoordinator.Target,
        openMessageRequest: ChatOpenMessageRequest?,
        navigationSource: ChatOpenNavigationSource,
        configure configureCallback: ((ChatViewController?) -> Void)?,
        activationContext: LastChatsExpandedSplitActivationContext? = nil
    ) -> Bool {
        guard let splitViewController = activationContext?.splitViewController
            ?? self.splitViewController else {
            return false
        }
        if let stableDestination = stableExpandedSplitDetailChat(
            matching: target,
            in: splitViewController
        ) {
            if navigationSource == .notification {
                let currentAccountEpoch = chatNavigationAccountEpochResolver(
                    target
                )
                guard currentAccountEpoch.isValidForChatNavigation else {
                    return false
                }
                if let transaction = expandedSplitChatNavigationTransaction,
                   transaction.target == target,
                   transaction.destination === stableDestination,
                   !transaction.accountEpoch.isExactValidMatch(
                    for: currentAccountEpoch
                   ) {
                    return false
                }
            }
            currentChatVC = stableDestination
            playerViewToolbar.delegate = stableDestination
            acceptChatOpenIntent(
                on: stableDestination,
                target: target,
                openMessageRequest: openMessageRequest,
                navigationSource: navigationSource,
                configure: configureCallback
            )
            let acknowledgement = LastChatsChatOpenAcknowledgementPolicy.shouldAcknowledge(
                navigationSource: navigationSource,
                request: openMessageRequest,
                isStableVisibleDestination: true,
                hasStableTargetAcknowledgement: stableDestination
                    .hasStableChatOpenAcknowledgement(
                        for: openMessageRequest
                    )
            )
            if let transaction = expandedSplitChatNavigationTransaction {
                resetExpandedSplitChatNavigationTransaction(
                    restorePreviousDetail:
                        transaction.destination !== stableDestination,
                    preserveIntentOwnership:
                        transaction.destination === stableDestination
                )
            }
            if acknowledgement {
                clearChatOpenIntentOwnership(destination: stableDestination)
            }
            return acknowledgement
        }

        if let transaction = expandedSplitChatNavigationTransaction {
            if transaction.target == target {
                acceptChatOpenIntent(
                    on: transaction.destination,
                    target: target,
                    openMessageRequest: openMessageRequest,
                    navigationSource: navigationSource,
                    configure: configureCallback
                )
                if navigationSource == .notification {
                    promoteExpandedSplitChatNavigationSourceToNotification(
                        token: transaction.token
                    )
                }
                if let retainedTransaction = expandedSplitChatNavigationTransaction,
                   retainedTransaction.token == transaction.token {
                    let currentAccountEpoch = chatNavigationAccountEpochResolver(
                        target
                    )
                    if retainedTransaction.phase == .preparing,
                       navigationSource == .notification {
                        _ = adoptExpandedSplitChatNavigationAccountEpochDuringPreparation(
                            token: retainedTransaction.token,
                            target: target,
                            destination: retainedTransaction.destination,
                            currentAccountEpoch: currentAccountEpoch
                        )
                    } else if retainedTransaction.phase ==
                                .waitingForEligibility {
                        let eligibility = expandedSplitChatNavigationEligibility(
                            transaction: retainedTransaction,
                            splitViewController: splitViewController
                        )
                        if let preparedTransaction =
                            prepareRetainedExpandedSplitChatNavigationForRetry(
                                token: retainedTransaction.token,
                                currentAccountEpoch: currentAccountEpoch,
                                currentFingerprint: eligibility.fingerprint
                            ) {
                            _ = presentExpandedSplitChatNavigation(
                                token: preparedTransaction.token,
                                target: target,
                                destination: preparedTransaction.destination,
                                splitViewController: splitViewController,
                                destinationIsPrepared: true
                            )
                        } else if navigationSource == .notification,
                                  let transitionOwner =
                                    eligibility.transitionOwner {
                            schedulePendingMessageNotificationRouteRetryOrEnqueue(
                                after: transitionOwner
                            )
                        }
                    }
                }
                return LastChatsChatOpenAcknowledgementPolicy.shouldAcknowledge(
                    navigationSource: navigationSource,
                    request: openMessageRequest,
                    isStableVisibleDestination: false,
                    hasStableTargetAcknowledgement: false
                )
            }

            switch transaction.phase {
            case .preparing, .waitingForEligibility:
                resetExpandedSplitChatNavigationTransaction(
                    restorePreviousDetail: true
                )
            case .presenting:
                return false
            case .presented:
                guard expandedSplitDetailChat(
                    matching: transaction.target,
                    in: splitViewController
                ) === transaction.destination else {
                    return false
                }
                resetExpandedSplitChatNavigationTransaction(
                    restorePreviousDetail: false
                )
            }
        } else if let installedMatchingDestination = expandedSplitDetailChat(
            matching: target,
            in: splitViewController
        ) {
            currentChatVC = installedMatchingDestination
            playerViewToolbar.delegate = installedMatchingDestination
            acceptChatOpenIntent(
                on: installedMatchingDestination,
                target: target,
                openMessageRequest: openMessageRequest,
                navigationSource: navigationSource,
                configure: configureCallback
            )
            if navigationSource == .notification,
               let transitionOwner = expandedSplitTransitionOwner(
                splitViewController: splitViewController,
                destination: installedMatchingDestination
               ) {
                schedulePendingMessageNotificationRouteRetryOrEnqueue(
                    after: transitionOwner
                )
            }
            return LastChatsChatOpenAcknowledgementPolicy.shouldAcknowledge(
                navigationSource: navigationSource,
                request: openMessageRequest,
                isStableVisibleDestination: false,
                hasStableTargetAcknowledgement: false
            )
        }

        return beginExpandedSplitChatNavigation(
            target: target,
            openMessageRequest: openMessageRequest,
            navigationSource: navigationSource,
            configure: configureCallback,
            splitViewController: splitViewController,
            activationContext: activationContext
        )
    }

    @discardableResult
    internal func stackNewChatForExpandedSplitActivation(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        openMessageRequest: ChatOpenMessageRequest?,
        navigationSource: ChatOpenNavigationSource,
        activationContext: LastChatsExpandedSplitActivationContext,
        configure configureCallback: ((ChatViewController?) -> Void)?
    ) -> Bool {
        stackNewChatInExpandedSplit(
            target: LastChatsNavigationSingleFlightCoordinator.Target(
                owner: owner,
                jid: jid,
                conversationType: conversationType
            ),
            openMessageRequest: openMessageRequest,
            navigationSource: navigationSource,
            configure: configureCallback,
            activationContext: activationContext
        )
    }

    @discardableResult
    internal func stackNewChatForCompactActivation(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        activationContext: LastChatsCompactActivationContext,
        configure configureCallback: ((ChatViewController?) -> Void)?
    ) -> Bool {
        stackNewChat(
            owner: owner,
            jid: jid,
            conversationType: conversationType,
            openMessageRequest: nil,
            navigationSource: .standard,
            compactActivationContext: activationContext,
            configure: configureCallback
        )
    }

    @discardableResult
    public func stackNewChat(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        openMessageRequest: ChatOpenMessageRequest? = nil,
        navigationSource: ChatOpenNavigationSource? = nil,
        configure configureCallback: ((ChatViewController?) -> Void)? = nil
    ) -> Bool {
        stackNewChat(
            owner: owner,
            jid: jid,
            conversationType: conversationType,
            openMessageRequest: openMessageRequest,
            navigationSource: navigationSource,
            compactActivationContext: nil,
            configure: configureCallback
        )
    }

    @discardableResult
    private func stackNewChat(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        openMessageRequest: ChatOpenMessageRequest?,
        navigationSource: ChatOpenNavigationSource?,
        compactActivationContext: LastChatsCompactActivationContext?,
        configure configureCallback: ((ChatViewController?) -> Void)?
    ) -> Bool {
        let navigationSource = resolvedNavigationSource(
            navigationSource,
            request: openMessageRequest
        )
        let route: StackedNavigationRoute = compactActivationContext == nil
            ? chatNavigationRouteResolver(self)
            : .currentNavigationPush
        let usesSplitDetailColumn = route == .splitDetailReplacement
        let navigationTarget = LastChatsNavigationSingleFlightCoordinator.Target(
            owner: owner,
            jid: jid,
            conversationType: conversationType
        )
        let expectedNavigationController = compactActivationContext?
            .navigationController ?? self.navigationController
        var navigationToken: UUID?
        var presentationSource: UIViewController = self
        var retainedPreparedDestination: ChatViewController?
        var retainedPreparedAccountEpoch: LastChatsChatNavigationAccountEpoch?

        if let compactActivationContext {
            guard self.navigationController === expectedNavigationController,
                  compactActivationContext.validateBeforePush() else {
                compactActivationContext.fallback()
                return false
            }
        }

        if usesSplitDetailColumn {
            return stackNewChatInExpandedSplit(
                target: navigationTarget,
                openMessageRequest: openMessageRequest,
                navigationSource: navigationSource,
                configure: configureCallback
            )
        }

        if let transaction = expandedSplitChatNavigationTransaction,
           transaction.target == navigationTarget,
           transaction.phase == .waitingForEligibility {
            let currentAccountEpoch = chatNavigationAccountEpochResolver(
                navigationTarget
            )
            guard currentAccountEpoch.isValidForChatNavigation else {
                return false
            }
            retainedPreparedDestination = transaction.destination
            retainedPreparedAccountEpoch = currentAccountEpoch
            resetExpandedSplitChatNavigationTransaction(
                restorePreviousDetail: true,
                preserveIntentOwnership: true
            )
        }
        if navigationSource == .notification,
           retainedPreparedAccountEpoch == nil {
            let currentAccountEpoch = chatNavigationAccountEpochResolver(
                navigationTarget
            )
            if currentAccountEpoch.isValidForChatNavigation {
                retainedPreparedAccountEpoch = currentAccountEpoch
            }
        }
        if let compactActivationContext,
           retainedPreparedAccountEpoch == nil {
            let currentAccountEpoch = chatNavigationAccountEpochResolver(
                navigationTarget
            )
            guard currentAccountEpoch.isValidForChatNavigation else {
                compactActivationContext.fallback()
                return false
            }
            retainedPreparedAccountEpoch = currentAccountEpoch
        }

        if !usesSplitDetailColumn {
            guard expectedNavigationController != nil else {
                return false
            }
            switch chatNavigationSingleFlight.request(target: navigationTarget) {
            case .started(let token):
                navigationToken = token
                DDLogDebug("LAST_CHATS_NAVIGATION event=started phase=preparing")
            case .coalesced(let token):
                DDLogDebug("LAST_CHATS_NAVIGATION event=coalesced phase=preparing")
                guard let destination = retainedCompactChatNavigationDestination(
                    token: token,
                    target: navigationTarget
                ) else {
                    return false
                }
                acceptChatOpenIntent(
                    on: destination,
                    target: navigationTarget,
                    openMessageRequest: openMessageRequest,
                    navigationSource: navigationSource,
                    configure: configureCallback
                )
                return LastChatsChatOpenAcknowledgementPolicy.shouldAcknowledge(
                    navigationSource: navigationSource,
                    request: openMessageRequest,
                    isStableVisibleDestination: false,
                    hasStableTargetAcknowledgement: false
                )
            case .ignored(let token):
                guard let state = chatNavigationSingleFlight.state,
                      state.token == token else {
                    return false
                }

                switch state.phase {
                case .pushing:
                    if let destination = visibleChatNavigationDestination(
                        in: expectedNavigationController,
                        matching: navigationTarget
                    ) ?? retainedCompactChatNavigationDestination(
                        token: token,
                        target: navigationTarget
                    ) {
                        acceptChatOpenIntent(
                            on: destination,
                            target: navigationTarget,
                            openMessageRequest: openMessageRequest,
                            navigationSource: navigationSource,
                            configure: configureCallback
                        )
                        return LastChatsChatOpenAcknowledgementPolicy.shouldAcknowledge(
                            navigationSource: navigationSource,
                            request: openMessageRequest,
                            isStableVisibleDestination: false,
                            hasStableTargetAcknowledgement: false
                        )
                    }
                    DDLogDebug("LAST_CHATS_NAVIGATION event=ignored phase=pushing")
                    // NotifyManager remains the single owner of a different exact
                    // route until the current push is presented and requests retry.
                    return false
                case .presented:
                    if let destination = visibleChatNavigationDestination(
                        in: expectedNavigationController,
                        matching: navigationTarget
                    ) {
                        acceptChatOpenIntent(
                            on: destination,
                            target: navigationTarget,
                            openMessageRequest: openMessageRequest,
                            navigationSource: navigationSource,
                            configure: configureCallback
                        )
                        let hasActiveTransition =
                            destination.transitionCoordinator != nil ||
                            expectedNavigationController?.transitionCoordinator != nil
                        let acknowledgement = LastChatsChatOpenAcknowledgementPolicy.shouldAcknowledge(
                            navigationSource: navigationSource,
                            request: openMessageRequest,
                            isStableVisibleDestination: !hasActiveTransition,
                            hasStableTargetAcknowledgement: destination
                                .hasStableChatOpenAcknowledgement(
                                    for: openMessageRequest
                                )
                        )
                        if acknowledgement {
                            clearChatOpenIntentOwnership(destination: destination)
                        } else if navigationSource == .notification {
                            let transitionOwner: UIViewController? =
                                destination.transitionCoordinator != nil
                                    ? destination
                                    : expectedNavigationController
                            if let transitionOwner {
                                schedulePendingMessageNotificationRouteRetryOrEnqueue(
                                    after: transitionOwner
                                )
                            }
                        }
                        return acknowledgement
                    }
                    if let destination = retainedCompactChatNavigationDestination(
                        token: token,
                        target: navigationTarget
                    ) {
                        acceptChatOpenIntent(
                            on: destination,
                            target: navigationTarget,
                            openMessageRequest: openMessageRequest,
                            navigationSource: navigationSource,
                            configure: configureCallback
                        )
                        return LastChatsChatOpenAcknowledgementPolicy.shouldAcknowledge(
                            navigationSource: navigationSource,
                            request: openMessageRequest,
                            isStableVisibleDestination: false,
                            hasStableTargetAcknowledgement: false
                        )
                    }
                    DDLogDebug("LAST_CHATS_NAVIGATION event=ignored phase=presented")
                    guard state.target != navigationTarget,
                          let currentChat = expectedNavigationController?.topViewController as? ChatViewController,
                          currentChat.transitionCoordinator == nil,
                          expectedNavigationController?.transitionCoordinator == nil,
                          currentChat.presentedViewController == nil,
                          expectedNavigationController?.presentedViewController == nil else {
                        return false
                    }
                    presentationSource = currentChat
                    chatNavigationSingleFlight.reset()
                    guard case .started(let replacementToken) =
                            chatNavigationSingleFlight.request(target: navigationTarget) else {
                        return false
                    }
                    navigationToken = replacementToken
                    DDLogDebug("LAST_CHATS_NAVIGATION event=started reason=presentedTargetReplacement phase=preparing")
                case .preparing:
                    if let destination = retainedCompactChatNavigationDestination(
                        token: token,
                        target: navigationTarget
                    ) {
                        acceptChatOpenIntent(
                            on: destination,
                            target: navigationTarget,
                            openMessageRequest: openMessageRequest,
                            navigationSource: navigationSource,
                            configure: configureCallback
                        )
                        return LastChatsChatOpenAcknowledgementPolicy.shouldAcknowledge(
                            navigationSource: navigationSource,
                            request: openMessageRequest,
                            isStableVisibleDestination: false,
                            hasStableTargetAcknowledgement: false
                        )
                    }
                    return false
                }
            }
        }

        ChatUIResponsivenessGate.shared.activate(
            reason: .chatOpen,
            duration: ChatUIResponsivenessGate.chatOpenHoldDuration
        )
        if let navigationToken {
            beginOutgoingChatOpenNavigationDeferral(token: navigationToken)
        }
        setSelectedChat(
            jid: jid,
            owner: owner,
            conversationType: conversationType,
            animated: navigationSource != .notification
        )

        if !usesSplitDetailColumn {
            self.currentChatVC = nil
        }

        self.currentChatVC = nil
        let vc = retainedPreparedDestination ?? compactChatDestinationFactory()
        vc.owner = owner
        vc.jid = jid
        vc.conversationType = conversationType
        vc.sharedPlayerPaneldelegae = self
        vc.lastChatsDisplayDelegate = self
        acceptChatOpenIntent(
            on: vc,
            target: navigationTarget,
            openMessageRequest: openMessageRequest,
            navigationSource: navigationSource,
            configure: configureCallback
        )
        if usesSplitDetailColumn {
            self.currentChatVC = vc
            self.playerViewToolbar.delegate = vc
        }

        guard let navigationToken else {
            showStacked(vc, in: self)
            return true
        }
        retainCompactChatNavigationDestination(
            vc,
            token: navigationToken,
            target: navigationTarget,
            accountEpoch: retainedPreparedAccountEpoch
        )

        let preparationHandle = showStacked(
            vc,
            in: presentationSource,
            using: route,
            destinationIsPrepared: retainedPreparedDestination != nil,
            commitPresentation: { [weak self, weak presentationSource] in
                guard let self, let presentationSource else {
                    return false
                }
                let currentNavigationController = presentationSource.navigationController
                if let retainedPreparedAccountEpoch {
                    guard retainedPreparedAccountEpoch.isExactValidMatch(
                        for: self.chatNavigationAccountEpochResolver(
                            navigationTarget
                        )
                    ) else {
                        return false
                    }
                }
                if let compactActivationContext {
                    guard currentNavigationController ===
                            expectedNavigationController,
                          compactActivationContext.validateBeforePush(),
                          compactActivationContext
                            .prepareNavigationControllerForPush() else {
                        return false
                    }
                } else {
                    let presenterWindow = presentationSource.viewIfLoaded?.window
                    let presenterIsVisible = presenterWindow != nil &&
                        (presentationSource !== self || self.isAppeared)
                    guard LastChatsNavigationPresenterIdentityPolicy.shouldCommit(
                        expectedNavigationController: expectedNavigationController,
                        currentNavigationController: currentNavigationController,
                        isPresenterTopViewController:
                            currentNavigationController?.topViewController === presentationSource,
                        isPresenterVisibleInWindow: presenterIsVisible,
                        isPresenterInSelectedTabHierarchy:
                            LastChatsNavigationPresenterHierarchyPolicy
                                .isInSelectedTabHierarchy(presentationSource),
                        isForegroundActiveScene:
                            presenterWindow?.windowScene?.activationState == .foregroundActive,
                        isCurrentNavigationPushRoute:
                            stackedNavigationRoute(for: presentationSource) == .currentNavigationPush,
                        presenterHasPresentedViewController:
                            presentationSource.presentedViewController != nil,
                        navigationControllerHasPresentedViewController:
                            currentNavigationController?.presentedViewController != nil
                    ) else { return false }
                }
                return self.commitChatNavigationPush(
                    token: navigationToken,
                    target: navigationTarget
                )
            },
            completion: { [weak self] didPresent in
                guard let self else {
                    return
                }
                if let compactActivationContext {
                    guard didPresent else {
                        _ = self.cancelChatNavigationPreparation(
                            token: navigationToken,
                            reason: .presentationGuardRejected
                        )
                        compactActivationContext.fallback()
                        return
                    }
                    if let retainedPreparedAccountEpoch,
                       !retainedPreparedAccountEpoch.isExactValidMatch(
                        for: self.chatNavigationAccountEpochResolver(
                            navigationTarget
                        )
                       ) {
                        self.resetChatNavigationTransaction(cancelled: true)
                        compactActivationContext.fallback()
                        return
                    }
                    compactActivationContext
                        .installPreparedNavigationController(vc) {
                            [weak self, weak vc] didInstall in
                            guard let self, let vc else {
                                return
                            }
                            guard didInstall else {
                                if self.chatNavigationSingleFlight.state?.token
                                    == navigationToken {
                                    self.resetChatNavigationTransaction(
                                        cancelled: true
                                    )
                                }
                                compactActivationContext.fallback()
                                return
                            }
                            if let retainedPreparedAccountEpoch,
                               !retainedPreparedAccountEpoch.isExactValidMatch(
                                for: self.chatNavigationAccountEpochResolver(
                                    navigationTarget
                                )
                               ) {
                                self.resetChatNavigationTransaction(
                                    cancelled: true
                                )
                                compactActivationContext.fallback()
                                return
                            }
                            guard let state = self
                                .chatNavigationSingleFlight.state,
                                  state.token == navigationToken,
                                  state.target == navigationTarget,
                                  state.phase == .pushing else {
                                return
                            }
                            self.currentChatVC = vc
                            self.playerViewToolbar.delegate = vc
                            if self.completeChatNavigationPresentation(
                                token: navigationToken,
                                target: navigationTarget,
                                destination: vc
                            ) {
                                DDLogDebug(
                                    "LAST_CHATS_NAVIGATION " +
                                        "event=presented phase=presented"
                                )
                            } else {
                                if self.currentChatVC === vc {
                                    self.currentChatVC = nil
                                }
                                if self.playerViewToolbar.delegate === vc {
                                    self.playerViewToolbar.delegate = nil
                                }
                                self.resetChatNavigationTransaction(
                                    cancelled: true
                                )
                                compactActivationContext.fallback()
                            }
                        }
                    return
                }
                if didPresent {
                    if self.completeChatNavigationPresentation(
                        token: navigationToken,
                        target: navigationTarget,
                        destination: vc
                    ) {
                        DDLogDebug("LAST_CHATS_NAVIGATION event=presented phase=presented")
                    }
                } else {
                    self.cancelChatNavigationPreparation(
                        token: navigationToken,
                        reason: .presentationGuardRejected
                    )
                    if navigationSource == .notification {
                        self.schedulePendingMessageNotificationRouteRetryOrEnqueue(
                            after: presentationSource
                        )
                    }
                }
            }
        )
        let registered = registerOutgoingChatOpenNavigationPreparation(
            preparationHandle,
            token: navigationToken
        )
        if registered {
            return LastChatsChatOpenAcknowledgementPolicy.shouldAcknowledge(
                navigationSource: navigationSource,
                request: openMessageRequest,
                isStableVisibleDestination: false,
                hasStableTargetAcknowledgement: false
            )
        }
        if let state = chatNavigationSingleFlight.state,
           state.token == navigationToken,
           state.target == navigationTarget,
           state.phase == .pushing || state.phase == .presented {
            return LastChatsChatOpenAcknowledgementPolicy.shouldAcknowledge(
                navigationSource: navigationSource,
                request: openMessageRequest,
                isStableVisibleDestination: false,
                hasStableTargetAcknowledgement: false
            )
        }
        clearRetainedCompactChatNavigationDestination(token: navigationToken)
        return false
    }
}

protocol LastChatsDisplayDelegate: AnyObject {
    func shouldMakeDialogSelected(jid: String, owner: String, conversationType: ClientSynchronizationManager.ConversationType)
}

extension LastChatsViewController: LastChatsDisplayDelegate {
    func shouldMakeDialogSelected(jid: String, owner: String, conversationType: ClientSynchronizationManager.ConversationType) {
        setSelectedChat(
            jid: jid,
            owner: owner,
            conversationType: conversationType,
            animated: true,
            scrollPosition: .middle
        )
    }
    
    
}
