#!/usr/bin/env bash

# Versioned selector manifest for the ChatViewController smoothness goal.
# It intentionally supports the system Bash 3.2 shipped with macOS.

CHAT_GOAL_MANIFEST_VERSION=1

CHAT_GOAL_TASK_IDS=(
  G00 G01 G02 G03 G04 G05A G05B G06 G07 G08 G09 G10 G11 G12
  G13A G13B G14 G15 G16 G17A G17B G18 G19 G20
)

chat_goal_preflight_selectors() {
  case "$1" in
    G00) cat <<'SELECTORS'
xabberTests/ChatLocalHistoryPageProviderWindowingTests
xabberTests/ChatTimelineCursorTests
xabberTests/ChatDatasourceBoundsTests
xabberTests/ChatScrollCoalescingTests
xabberTests/ChatScrollBoundaryCacheTests
xabberTests/ChatViewportReadBoundaryTests
xabberTests/ChatCollectionPrefetchTests
xabberTests/ChatDatasourceMappingThreadingTests
xabberTests/ChatReloadInvalidationPolicyTests
xabberTests/ChatDisplayModelCacheTests
xabberTests/ChatPerformanceSignpostTests
xabberTests/ChatVirtualTimelineEngineTests
xabberTests/ChatBottomScrollAlignmentPolicyTests
xabberTests/ChatInitialHistoryAppearancePolicyTests
xabberTests/TextMessageCellReuseTests
xabberTests/ChatSearchPresentationStateTests
xabberTests/ChatSearchResultPresentationTests
xabberTests/ChatSearchSessionStateTests
xabberTests/LastChatsViewControllerBehaviorTests
SELECTORS
      ;;
    G01) cat <<'SELECTORS'
xabberTests/TextMessageCellReuseTests
xabberTests/ChatReloadInvalidationPolicyTests
xabberTests/ChatInitialMessageOverlayLayoutTests
SELECTORS
      ;;
    G02) cat <<'SELECTORS'
xabberTests/ChatDatasetPerformanceHelpersTests
xabberTests/ChatSearchResultPresentationTests
xabberTests/ComposerMentionsTests
SELECTORS
      ;;
    G03) cat <<'SELECTORS'
xabberTests/ChatLocalHistoryPageProviderWindowingTests
xabberTests/ChatTimelineCursorTests
xabberTests/ChatLocalHistoryPageProviderTests
SELECTORS
      ;;
    G04) cat <<'SELECTORS'
xabberTests/ChatTimelineSessionTests
xabberTests/ChatTimelineSessionSourcePolicyTests
xabberTests/ChatHistoryRealmMigrationTests
xabberTests/ChatCursorNativeHistoryScaleTests/testMillionRowTimelineSessionKeepsResidentAndOperationsBounded
xabberTests/ChatVirtualTimelineEngineTests
xabberTests/ChatDatasourceBoundsTests
xabberTests/ChatViewportReadBoundaryTests
xabberTests/ChatUnreadMentionsTests
SELECTORS
      ;;
    G05A) cat <<'SELECTORS'
xabberTests/ChatLocalHistoryPageProviderWindowingTests
xabberTests/ChatVirtualTimelineEngineTests
xabberTests/ChatHistoryPagingPolicyTests
xabberTests/ChatHistoryPageAnchorRestorePolicyTests
SELECTORS
      ;;
    G05B) cat <<'SELECTORS'
xabberTests/MessageArchiveQueryCallbackTests
xabberTests/MessageManagerQueueSynchronizationTests
xabberTests/ChatRemoteHistoryApplyPolicyTests
xabberTests/ChatHistoryLoadingTimeoutPolicyTests
SELECTORS
      ;;
    G06) cat <<'SELECTORS'
xabberTests/ChatInitialHistoryAppearancePolicyTests
xabberTests/ChatBootstrapStateTests
xabberTests/ChatFirstFrameLocalHistoryPolicyTests
xabberTests/ChatOpenTimingPolicyTests
SELECTORS
      ;;
    G07) cat <<'SELECTORS'
xabberTests/ChatReloadInvalidationPolicyTests
xabberTests/ChatBottomScrollAlignmentPolicyTests
xabberTests/ChatHistoryPageAnchorRestorePolicyTests
xabberTests/ChatComposerFrameUpdateTests
SELECTORS
      ;;
    G08) cat <<'SELECTORS'
xabberTests/ChatScrollCoalescingTests
xabberTests/ChatScrollBoundaryCacheTests
xabberTests/ChatViewportReadBoundaryTests
xabberTests/VoiceMessagePlaybackCoordinatorTests
SELECTORS
      ;;
    G09) cat <<'SELECTORS'
xabberTests/ChatDiffKeySignatureTests
xabberTests/ChatDatasourceMappingThreadingTests
xabberTests/ChatOutgoingAutoScrollPolicyTests
xabberTests/ChatVirtualTimelineEngineTests
SELECTORS
      ;;
    G10) cat <<'SELECTORS'
xabberTests/ChatDisplayModelCacheTests
xabberTests/ChatReloadInvalidationPolicyTests
xabberTests/ChatInitialMessageOverlayLayoutTests
xabberTests/ChatDatasetPerformanceHelpersTests
SELECTORS
      ;;
    G11) cat <<'SELECTORS'
xabberTests/ChatDisplayModelCacheTests
xabberTests/ChatDatasourceMappingThreadingTests
xabberTests/ChatObserverLifecycleTests
SELECTORS
      ;;
    G12) cat <<'SELECTORS'
xabberTests/TextMessageCellReuseTests
xabberTests/InlineAudiosGridViewContentUpdateTests
xabberTests/ChatCollectionPrefetchTests
SELECTORS
      ;;
    G13A) cat <<'SELECTORS'
xabberTests/ChatCollectionPrefetchTests
xabberTests/TextMessageCellReuseTests
xabberTests/SensitiveMediaAnalysisServiceTests
SELECTORS
      ;;
    G13B) cat <<'SELECTORS'
xabberTests/ChatAttachmentFileSourceTests
xabberTests/ChatAttachmentErrorProgressStateTests
xabberTests/MediaGalleryFilesListTests
xabberTests/TextMessageCellReuseTests
SELECTORS
      ;;
    G14) cat <<'SELECTORS'
xabberTests/ChatAttachmentGeolocationSourceTests
xabberTests/ChatCollectionPrefetchTests
xabberTests/TextMessageCellReuseTests
SELECTORS
      ;;
    G15) cat <<'SELECTORS'
xabberTests/VoiceMessagePlaybackCoordinatorTests
xabberTests/InlineAudioViewVoiceStateRenderingTests
xabberTests/MediaGalleryVoicePlaybackTests
SELECTORS
      ;;
    G16) cat <<'SELECTORS'
xabberTests/ChatBootstrapStateTests
xabberTests/ChatBootstrapSkeletonRenderPolicyTests
xabberTests/ChatInitialHistoryAppearancePolicyTests
xabberTests/LastChatsSkeletonCellLayoutTests
SELECTORS
      ;;
    G17A) cat <<'SELECTORS'
xabberTests/LastChatsViewControllerBehaviorTests
xabberTests/ChatSearchPresentationStateTests
xabberTests/ChatSearchResultPresentationTests
xabberTests/ChatSearchSessionStateTests
xabberTests/ChatInChatSearchQueryLifecycleTests
SELECTORS
      ;;
    G17B) cat <<'SELECTORS'
xabberTests/LastChatsViewControllerBehaviorTests
xabberTests/LastChatsSeparatorAppearanceTests
xabberTests/ChatSearchResultPresentationTests
xabberTests/InfoCardChatSearchRoutingTests
SELECTORS
      ;;
    G18) cat <<'SELECTORS'
xabberTests/ChatMessageAnchorPolicyTests
xabberTests/ChatSearchSessionStateTests
xabberTests/ChatSearchResultNavigationStateTests
xabberTests/MessageArchiveQueryCallbackTests
SELECTORS
      ;;
    G19) cat <<'SELECTORS'
xabberTests/ChatObserverLifecycleTests
xabberTests/ChatDisplayModelCacheTests
xabberTests/ChatCollectionPrefetchTests
xabberTests/ChatDatasourceMappingThreadingTests
SELECTORS
      ;;
    G20) cat <<'SELECTORS'
xabberTests/ChatPerformanceLabTests
xabberTests/ChatRenderOperationCounterTests
xabberTests/ChatPerformanceSignpostTests
xabberTests/ChatLocalHistoryPageProviderWindowingTests
xabberTests/ChatVirtualTimelineEngineTests
xabberTests/ChatDatasourceBoundsTests
xabberTests/ChatScrollCoalescingTests
xabberTests/ChatViewportReadBoundaryTests
xabberTests/ChatDatasourceMappingThreadingTests
xabberTests/ChatReloadInvalidationPolicyTests
xabberTests/ChatDisplayModelCacheTests
xabberTests/TextMessageCellReuseTests
xabberTests/ChatMessageAnchorPolicyTests
xabberTests/ChatSearchSessionStateTests
xabberTests/LastChatsViewControllerBehaviorTests
SELECTORS
      ;;
    *) return 64 ;;
  esac
}

chat_goal_focused_selectors() {
  if [[ "$1" == "G00" ]]; then
    cat <<'SELECTORS'
xabberTests/ChatPerformanceLabTests
xabberTests/ChatRenderOperationCounterTests
xabberTests/ChatPerformanceSignpostTests
SELECTORS
    return
  fi
  if [[ "$1" == "G01" ]]; then
    cat <<'SELECTORS'
xabberTests/TextMessageCellLayoutTests
xabberTests/MessagesCollectionViewLayoutAttributesTests
xabberTests/InlineForwardLayoutOrderingTests
xabberTests/TextMessageCellReuseTests
xabberTests/ChatReloadInvalidationPolicyTests
xabberTests/ChatInitialMessageOverlayLayoutTests
SELECTORS
    return
  fi
  if [[ "$1" == "G02" ]]; then
    cat <<'SELECTORS'
xabberTests/ChatAttributedBodyFormattingTests
xabberTests/MessageLabelLinkHitTestingTests
xabberTests/ChatDiffKeySignatureTests
xabberTests/ChatDatasetPerformanceHelpersTests
xabberTests/ChatSearchResultPresentationTests
xabberTests/ComposerMentionsTests
xabberTests/TextMessageCellReuseTests
xabberTests/ChatAttachmentXMPPCompatibilityTests
SELECTORS
    return
  fi
  if [[ "$1" == "G03" ]]; then
    cat <<'SELECTORS'
xabberTests/ChatCursorNativeHistoryProviderTests
xabberTests/ChatCursorNativeHistoryScaleTests
xabberTests/ChatHistoryRealmMigrationTests
xabberTests/ChatLocalHistoryPageProviderWindowingTests
xabberTests/ChatTimelineCursorTests
xabberTests/ChatLocalHistoryPageProviderTests
SELECTORS
    return
  fi
  chat_goal_preflight_selectors "$1"
}

chat_goal_smoke_selectors() {
  cat <<'SELECTORS'
xabberTests/ChatPerformanceLabTests
xabberTests/ChatRenderOperationCounterTests
xabberTests/ChatPerformanceSignpostTests
xabberTests/ChatLocalHistoryPageProviderWindowingTests
xabberTests/ChatVirtualTimelineEngineTests
xabberTests/ChatDatasourceBoundsTests
xabberTests/ChatScrollCoalescingTests
xabberTests/ChatViewportReadBoundaryTests
xabberTests/ChatDatasourceMappingThreadingTests
xabberTests/ChatReloadInvalidationPolicyTests
xabberTests/ChatDisplayModelCacheTests
xabberTests/TextMessageCellReuseTests
xabberTests/ChatMessageAnchorPolicyTests
xabberTests/ChatSearchSessionStateTests
xabberTests/LastChatsViewControllerBehaviorTests
SELECTORS
}

CHAT_GOAL_KNOWN_RED_SELECTORS=(
  'xabberTests/ChatMessageAnchorPolicyTests/testContextWaitingSearchRequestDoesNotCallPositioningStarted'
  'xabberTests/LastChatsSeparatorAppearanceTests/testLastChatsBottomSearchExpandsFullWidthAndHidesFloatingBottomBar'
  'xabberTests/LastChatsSeparatorAppearanceTests/testUpdateBottomTitleDoesNotMutateNavigationItemDuringOrAfterTransition'
)

chat_goal_known_red_owner() {
  case "$1" in
    'xabberTests/ChatMessageAnchorPolicyTests/testContextWaitingSearchRequestDoesNotCallPositioningStarted') echo G18 ;;
    'xabberTests/LastChatsSeparatorAppearanceTests/testLastChatsBottomSearchExpandsFullWidthAndHidesFloatingBottomBar') echo G17B ;;
    'xabberTests/LastChatsSeparatorAppearanceTests/testUpdateBottomTitleDoesNotMutateNavigationItemDuringOrAfterTransition') echo G17B ;;
    *) return 64 ;;
  esac
}

chat_goal_known_red_patterns() {
  case "$1" in
    'xabberTests/ChatMessageAnchorPolicyTests/testContextWaitingSearchRequestDoesNotCallPositioningStarted')
      printf '%s\n' 'XCTAssertEqual failed' started positioned
      ;;
    'xabberTests/LastChatsSeparatorAppearanceTests/testLastChatsBottomSearchExpandsFullWidthAndHidesFloatingBottomBar'|'xabberTests/LastChatsSeparatorAppearanceTests/testUpdateBottomTitleDoesNotMutateNavigationItemDuringOrAfterTransition')
      echo 'XCTAssertTrue failed'
      ;;
    *) return 64 ;;
  esac
}
