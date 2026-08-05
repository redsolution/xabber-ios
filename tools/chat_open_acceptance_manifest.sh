#!/usr/bin/env bash

# Exact source-candidate selector manifest for the 95-row chat-open acceptance matrix.
#
# This file is intentionally compatible with the Bash 3.2 shipped by macOS. It does not
# claim runtime acceptance: every selector still has to pass sequentially on the locked
# simulator, and the visual rows also require their independent fixed-rate video gate.

set -u

CHAT_OPEN_ACCEPTANCE_MANIFEST_VERSION="2026-08-03.4"
CHAT_OPEN_ACCEPTANCE_SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

chat_open_acceptance_expected_ids() {
  cat <<'IDS'
N01
N02
N03
N04
N05
N06
N07
N08
N09
N10
N11
N12
N13
N14
E01
E02
E03
E04
E05
E06
E07
E08
E09
E10
E11
E12
E13
E14
E15
E16
E17
E18
X01
X02
X03
X04
X05
X06
X07
X08
X09
P01
P02
P03
P04
P05
P06
P07
P08
P09
P10
P11
P12
P13
P14
P15
P16
P17
P18
G01
G02
G03
G04
G05
G06
G07
G08
G09
G10
G11
G12
G13
G14
G15
G16
G17
G18
G19
G20
V01
V02
V03
V04
V05
V06
V07
V08
V09
V10
V11
V12
V13
V14
V15
V16
IDS
}

# Format: matrix-id|source state|semicolon-delimited xcodebuild selectors.
# Reusing a selector across rows is intentional when one body proves material clauses for
# more than one row. There is still exactly one manifest record for every matrix ID.
chat_open_acceptance_rows() {
  cat <<'ROWS'
N01|source-candidate|xabberTests/ChatFirstLoginChatOpenRegressionTests/testDurablySyncedLocalRowsRenderContentWithoutStartingBootstrapArchive;xabberTests/ChatFirstFrameLocalHistoryRegressionTests/testDefaultOpenUsesLatestFirstFrame;xabberChatPerformanceUITests/ChatPerformanceUITests/testChatOpenN01PreloadedLatestVideoRoute
N02|source-candidate|xabberTests/ChatFirstFrameLocalHistoryRegressionTests/testZeroServerUnreadWithUnreadAfterIdUsesLatestFirstFrame
N03|source-candidate|xabberTests/ChatFirstFrameLocalHistoryRegressionTests/testZeroServerUnreadWithUnreadAfterIdUsesLatestFirstFrame;xabberTests/ChatInitialPositionPolicyTests/testRuntimeOnlyUnreadWithSyncUnreadAfterIdOpensBottom
N04|source-candidate|xabberTests/ChatFirstFrameLocalHistoryRegressionTests/testUnreadBoundaryLocalTargetAppliesAnchorWindowBeforeFirstRealFrame;xabberTests/ChatMessageAnchorPolicyTests/testUnreadBoundaryTargetPrefersFirstIncomingMessageAfterBoundary;xabberChatPerformanceUITests/ChatPerformanceUITests/testChatOpenN04UnreadBoundaryLocalVideoRoute
N05|source-candidate|xabberTests/ChatSingleFrameLocalOpenTests/testUnreadBoundaryPreparationOpensAroundFirstIncomingMessage;xabberTests/ChatMessageAnchorPolicyTests/testUnreadBoundaryTargetChoosesEarliestIncomingArchiveAfterBoundary
N06|source-candidate|xabberTests/ChatFirstFrameLocalHistoryRegressionTests/testUnreadBoundaryWithoutLocalIncomingTargetKeepsBootstrapSkeletonInsteadOfOpeningLatest
N07|source-candidate|xabberTests/ChatInitialPositionPolicyTests/testAutomaticUnreadBoundaryUsesSyncUnreadAfterWithoutLastReadFallback;xabberTests/ChatInitialPositionPolicyTests/testInvalidSyncUnreadAfterIdWithPositiveSyncUnreadCountOpensBottom;xabberTests/ChatInitialPositionPolicyTests/testUnreadBoundaryWithoutAnchorOpensBottom;xabberTests/ChatInitialPositionPolicyTests/testBlankSyncUnreadAfterIdOpensBottomWithoutLastReadFallback
N08|source-candidate|xabberTests/ChatInitialPositionPolicyTests/testAutomaticSavedPositionIsRestoredWhenChatEdgesMatch;xabberTests/ChatFirstFrameLocalHistoryRegressionTests/testSavedVisiblePositionPresentUsesAnchoredFirstFrame;xabberChatPerformanceUITests/ChatPerformanceUITests/testChatOpenN08SavedPositionLocalVideoRoute
N09|source-candidate|xabberTests/ChatInteractiveOpenGateRegressionTests/testSavedPositionBootstrapUsesMessageIdBeforeDateAndDateOnlyAsFallback
N10|source-candidate|xabberTests/ChatInteractiveOpenGateRegressionTests/testSavedPositionBootstrapUsesMessageIdBeforeDateAndDateOnlyAsFallback
N11|source-candidate|xabberTests/ChatFirstFrameLocalHistoryRegressionTests/testSavedAnchorCrossingKnownGapKeepsSkeletonAndRepairsWithoutLatest
N12|source-candidate|xabberTests/ChatInitialPositionPolicyTests/testSavedPositionIsIgnoredWhenLastMessageEdgeChanged;xabberTests/ChatInitialPositionPolicyTests/testSavedPositionIsIgnoredWhenSnapshotEdgeChanged
N13|source-candidate|xabberTests/ChatSkeletonLifecycleTests/testRepeatedConfigureDatasetPreservesResidentWindowAnchorAndPerformsZeroReloads
N14|source-candidate|xabberTests/ChatSkeletonLifecycleTests/testConversationARealDatasourceReplacementByBPublishesNoFrameContainingARows;xabberTests/ChatSkeletonLifecycleTests/testConversationReplacementDetachesCommittedPendingABootstrapWithoutDestroyingSharedReceipt;xabberTests/ChatSkeletonLifecycleTests/testConversationReplacementCancelsActiveAPagingAndRejectsLateATerminalsBeforeFreshBPaging;xabberTests/ChatSkeletonLifecycleTests/testConversationOwnerReplacementPublishesOnlyFreshOwnerSkeleton;xabberTests/ChatSkeletonLifecycleTests/testConversationTypeReplacementPublishesOnlyFreshTypeSkeleton
E01|source-candidate|xabberTests/ChatFirstLoginChatOpenRegressionTests/testConfirmedEmptyWithoutKnownRemoteBoundaryDoesNotEnterRepairLoop;xabberChatPerformanceUITests/ChatPerformanceUITests/testChatOpenE01ConfirmedEmptyVideoRoute
E02|source-candidate|xabberTests/ChatFirstLoginChatOpenRegressionTests/testUnsyncedKnownSnapshotCommitsThirtySkeletonRowsAndReservesOneArchiveTransaction;xabberChatPerformanceUITests/ChatPerformanceUITests/testChatOpenE02ContentVideoRoute;xabberChatPerformanceUITests/ChatPerformanceUITests/testChatOpenE02EmptyVideoRoute
E03|source-candidate|xabberTests/ChatFirstAccountBootstrapRegressionTests/testKnownRemoteSnapshotWithReadinessFlagsButNoLocalRowsRequiresRepair;xabberTests/ChatFirstAccountBootstrapRegressionTests/testSyncChatStartsConsistencyRepairForReadinessFlagsWithKnownBoundaryAndNoLocalRows
E04|source-candidate|xabberTests/ChatFirstFrameLocalHistoryRegressionTests/testUnsyncedChatWithLocalMessagesKeepsSkeletonUntilArchiveBootstrapCompletes;xabberTests/ChatPerformanceLabTests/testE04UnsyncedStaleLocalPlanSeedsRowsButRequiresBlockingSkeleton;xabberTests/ChatPerformanceLabTests/testE04TailCardinalityProvesNewestEdgeWithoutClaimingOlderArchiveEnd;xabberTests/ChatPerformanceLabTests/testE04UnsyncedStaleLocalRowsNeverPublishBeforeTrustedPersistence;xabberChatPerformanceUITests/ChatPerformanceUITests/testChatOpenE04UnsyncedStaleLocalRowsVideoRoute
E05|source-candidate|xabberTests/ChatFirstLoginChatOpenRegressionTests/testDurablySyncedLocalRowsRenderContentWithoutStartingBootstrapArchive;xabberChatPerformanceUITests/ChatPerformanceUITests/testChatOpenN01PreloadedLatestVideoRoute
E06|source-candidate|xabberTests/MessageManagerQueueSynchronizationTests/testSealedArchiveBatchWaitsForExpectedTransportIngressAndLateRowsWakePumpExactlyOnce
E07|source-candidate|xabberTests/MessageArchiveQueryCallbackTests/testDeferredBootstrapCommitsOnlyAfterPersistenceAndAcceptsEightyRowsForRsmCountEightyOne
E08|source-candidate|xabberTests/ChatInteractiveOpenGateRegressionTests/testContinuesRequestTerminatesEmptyDeliveredPageDespiteNonzeroServerCount
E09|source-candidate|xabberTests/MessageArchiveQueryCallbackTests/testSnapshotBoundaryChangedAfterRequestStartRequiresFollowUpEvenWhenNewBoundaryIsCovered;xabberTests/MessageArchiveQueryCallbackTests/testSnapshotBoundaryChangedAfterRawFinalRequiresFollowUpAndCannotConfirmEmpty;xabberTests/ChatFirstLoginSkeletonAvatarReadinessRegressionTests/testNewSnapshotInvalidatesOnlyCommittedReceipt
E10|source-candidate|xabberTests/ChatInteractiveOpenGateRegressionTests/testFiveSecondPresentationWatchdogKeepsQueuedSkeletonAndActiveLease;xabberTests/ChatInteractiveOpenGateRegressionTests/testFiveSecondPresentationWatchdogKeepsTransportSkeletonAndActiveLease;xabberTests/ChatInteractiveOpenGateRegressionTests/testRawFinDuringBlockedPersistenceDoesNotDisarmPresentationWatchdog;xabberTests/ChatFirstLoginChatOpenRegressionTests/testLegacyReadyFlagsWithOldLocalRowAndMissingCurrentCoverageShowSkeletonAndStartRepair;xabberChatPerformanceUITests/ChatPerformanceUITests/testChatOpenE10HeldBootstrapWatchdogVideoRoute
E11|source-candidate|xabberTests/ChatSkeletonLifecycleTests/testExternalTransportFailureCancelsLeaseAndPersistsTerminalState;xabberTests/ChatFirstAccountBootstrapRegressionTests/testInitialBootstrapPersistenceTimeoutTransitionsToRetryWithoutCommittingReadiness;xabberTests/ChatSkeletonLifecycleTests/testFailurePresentationExposesRetryWithoutTimelineLock;xabberChatPerformanceUITests/ChatPerformanceUITests/testChatOpenE11TypedFailureRetryVideoRoute
E12|source-candidate|xabberTests/ChatFirstLoginChatOpenRegressionTests/testLateContentSuccessAfterRetryCommitsOnceAndRemovesRetry;xabberTests/ChatInitialPresentationAtomicityRegressionTests/testEmptyDatasourceAtomicApplyDoesNotPublishAnIntermediateRealFrame
E13|source-candidate|xabberTests/ChatSkeletonLifecycleTests/testControllerTeardownLeavesBootstrapLeaseForReopenedController;xabberTests/ChatFirstAccountBootstrapRegressionTests/testReopenDoesNotDiscardRawFinalPersistenceLeaseWhenRealmFlagsAreAlreadyTrue;xabberTests/ChatFirstAccountBootstrapRegressionTests/testReopenReceivesPostPersistenceCommittedPage
E14|source-candidate|xabberTests/LastChatsNavigationSingleFlightTests/testTenRapidRequestsForSameTargetPerformOneNavigationPush
E15|source-candidate|xabberTests/LastChatsNavigationSingleFlightTests/testDifferentTargetSupersedesOnlyPendingPreparation;xabberTests/LastChatsNavigationSingleFlightTests/testStaleFirstCompletionAfterDifferentTargetSupersessionIsInert;xabberTests/ChatAnchorTransactionTests/testSupersededTransactionRejectsEveryLateAsyncBoundary
E16|source-candidate|xabberTests/LastChatsNavigationSingleFlightTests/testBackDuringPushReleasesSingleFlightOnlyAfterTransitionCancellationCompletes
E17|source-candidate|xabberTests/ChatBootstrapConnectivityLifecycleTests/testOfflineQueuedBootstrapUsesProductionReconnectDispatcherAndSendsSameLeaseExactlyOnce;xabberTests/ChatBootstrapConnectivityLifecycleTests/testAuthenticatedReconnectTestSeamUsesSameProductionPendingDispatcherAsRealAuthCallback
E18|source-candidate|xabberTests/ChatBootstrapConnectivityLifecycleTests/testBackgroundForegroundPreservesLeaseSkeletonIdentityAndRequestCount
X01|source-candidate|xabberTests/ChatLoadedTargetIntegrationTests/testVisibleExactTargetCentersAndHighlightsWithoutDatasourceApplyOrMAM;xabberChatPerformanceUITests/ChatPerformanceUITests/testChatOpenX01SearchExactLocalVideoRoute
X02|source-candidate|xabberTests/ChatLocalTargetWindowIntegrationTests/testLocalTargetOutsideResidentWindowUsesBoundedLocalFirstFrameWithoutLatestOrMAM;xabberChatPerformanceUITests/ChatPerformanceUITests/testChatOpenX02SearchExactLocalOutsideWindowVideoRoute
X03|source-candidate|xabberTests/ChatPerformanceLabTests/testRemoteExactBootstrapCannotEmitLatestFirstDescriptor;xabberTests/ChatPerformanceLabTests/testRemoteExactOpenOwnsOneBoundedTargetWindowBeforeFirstContent;xabberTests/ChatPerformanceLabTests/testRemoteExactPersistenceWaitsForNewerMaterializedObserverAndIgnoresDuplicate;xabberChatPerformanceUITests/ChatPerformanceUITests/testChatOpenX03SearchExactRemoteVideoRoute
X04|source-candidate|xabberTests/ChatMessageAnchorPolicyTests/testAnchorFetchPolicyUsesDateWindowWhenArchivedIdIsMissing;xabberTests/ChatInteractiveOpenGateRegressionTests/testSavedPositionBootstrapUsesMessageIdBeforeDateAndDateOnlyAsFallback
X05|source-candidate|xabberTests/LastChatsSearchProvenanceRouteTests/testNilSourceDateNeverCreatesDateWindowPlan;xabberTests/LastChatsSearchProvenanceRouteTests/testStaleGenerationAndMissingMessageIdentityAreTypedUnavailable;xabberTests/LastChatsSearchProvenanceRouteTests/testLegacyTableRouteAndSearchDateNowFallbackAreAbsent
X06|source-candidate|xabberTests/LastChatsSearchProvenanceRouteTests/testMessageIDResolutionHonorsAuthorAndRejectsAmbiguity;xabberTests/LastChatsSearchProvenanceRouteTests/testFingerprintDateResolutionIsBoundedAndRequiresUniqueMatch;xabberTests/ChatAnchorTransactionTests/testTypedFailuresDistinguishMissingDeletedAmbiguousAndBoundedResolution
X07|source-candidate|xabberTests/ChatCollectionAnchorPreservationTests/testControllerTargetDeletionReportsFailureWithoutLegacySuccessCompletion;xabberTests/ChatInitialPresentationAtomicityRegressionTests/testUnresolvedAtomicTargetRestoresCommittedSkeletonAndDoesNotPublishContent
X08|source-candidate|xabberTests/ChatAnchorTransactionTests/testPositionVerificationRequiresExactIdentityAndCenterTolerance;xabberTests/ChatAnchorTransactionTests/testRetainedMediaAnchorUpdatesRevisionButRejectsIdentityReuseAndUserDrag;xabberTests/ChatCollectionAnchorPreservationTests/testControllerHeightEditsAboveInsideAndBelowViewportPreserveAnchor
X09|source-candidate|xabberTests/ChatCollectionAnchorPreservationTests/testUserInteractionSuppressesAutomaticOffsetMutation;xabberTests/ChatAnchorTransactionTests/testRetainedMediaAnchorUpdatesRevisionButRejectsIdentityReuseAndUserDrag
P01|source-candidate|xabberTests/PushNotificationRoutingTests/testForegroundNotificationTapStillOpensTheExactMessageRoute;xabberChatPerformanceUITests/ChatPerformanceUITests/testChatOpenP01NotificationExactLocalVideoRoute
P02|source-candidate|xabberTests/ChatFirstFrameLocalHistoryRegressionTests/testMissingLocalAnchorOpenRequestKeepsBlockingSkeletonWithoutLatest;xabberTests/ChatPerformanceLabTests/testRemoteExactPersistenceWaitsForNewerMaterializedObserverAndIgnoresDuplicate;xabberChatPerformanceUITests/ChatPerformanceUITests/testChatOpenP02NotificationExactRemoteVideoRoute
P03|source-candidate|xabberTests/PushNotificationSceneRoutingTests/testSuspendedTapPreservesOwnerConversationTypeAndExactTargetUntilVisible
P04|source-candidate|xabberTests/AppRootColdPushRoutingTests/testColdPushSurvivesRootAndAccountStartupAndOpensExactTargetOnce;xabberChatPerformanceUITests/ChatPerformanceUITests/testChatOpenP04ColdPushExactVideoRoute
P05|source-candidate|xabberTests/PushNotificationRoutingTests/testLocalMessageNotificationBuildsExactMessageAnchorRequest;xabberTests/PushNotificationRoutingTests/testRichPushNotificationBuildsTheSameExactMessageAnchorRequest;xabberChatPerformanceUITests/ChatPerformanceUITests/testChatOpenP01NotificationExactLocalVideoRoute
P06|source-candidate|xabberTests/PushNotificationRoutingTests/testLegacyMessageWithoutStableIdentityProducesTypedFallbackAndNeverExactSuccess
P07|source-candidate|xabberTests/PushNotificationRoutingTests/testSentCarbonUsesInnerMessageForCanonicalExactOpenRequest
P08|source-candidate|xabberTests/PushNotificationRoutingTests/testSentCarbonUsesInnerMessageForCanonicalExactOpenRequest
P09|source-candidate|xabberTests/ChatMessageAnchorPolicyTests/testAnchorContextCoverageRepairsKnownGapsOnBothSidesOfNotificationTarget;xabberChatPerformanceUITests/ChatPerformanceUITests/testChatOpenP09NotificationKnownGapTargetVideoRoute
P10|source-candidate|xabberTests/PushNotificationRoutingTests/testGroupChatMessageUsesGroupRouteAndSenderNickname;xabberTests/PushNotificationRoutingTests/testSemanticConversationTypeAliasesBuildTheMatchingExactMessageRequest
P11|source-candidate|xabberTests/NotificationsFeatureTests/testMentionOpenRequestUsesOriginalMessageAnchorMetadataInsteadOfOuterNotificationIdentity
P12|source-candidate|xabberTests/ChatUnreadMentionsTests/testMatchingMessagePrefersArchivedIdOverMessageIdFallback;xabberTests/ChatUnreadMentionsTests/testMatchingMessageFallsBackToMessageIdWhenArchivedIdIsMissing;xabberTests/ChatUnreadMentionsTests/testMatchingMessageFallsBackToTimestampSenderAndBodyFingerprint
P13|source-candidate|xabberTests/MentionOpenRoutingTests/testDeletedTappedMentionAdvancesOrFailsWithoutReportingLatestAsSuccess;xabberTests/MentionOpenRoutingTests/testP13DeletedMentionWithoutFollowingTargetDoesNotNavigateOrReportLatestSuccess;xabberTests/ChatPerformanceLabTests/testP13DeletedMentionFixtureClearsTappedNotificationAndRoutesOnlyToNextExactMention;xabberChatPerformanceUITests/ChatPerformanceUITests/testChatOpenP13DeletedMentionAdvancesVideoRoute
P14|source-candidate|xabberTests/ChatListUnreadMentionBadgeTests/testSelectingGroupChatSeedsMentionBeforeInitialFirstFramePreparation;xabberTests/ChatListUnreadMentionBadgeTests/testLastChatsUnreadMentionOpenRequestUsesUnreadNotificationAnchorMetadata;xabberTests/ChatPerformanceLabTests/testP14LastChatsSeededMentionResolvesBeforeInitialFramePreparation;xabberTests/ChatPerformanceLabTests/testP14SeededMentionWinsOnlyForExplicitMentionIntentAfterProductPolicyResolution;xabberTests/ChatPerformanceLabTests/testP14DidShowBeforeInitialCommitWaitsForFreshUnreadProofBeforeReadVisibleReceipt;xabberTests/ChatPerformanceLabTests/testP14ReadReceiptStableRowStoreChangePreservesCommittedAnchoredFrameWithoutSecondDatasourceApply;xabberTests/RootBottomBarInsetPolicyTests/testDetachedApplyDoesNotForceLayoutOrMutateInsetsOrOffset;xabberTests/RootBottomBarInsetPolicyTests/testApplyAfterWindowAttachmentCatchesUpAndPreservesAwayFromBottomOffset;xabberTests/RootBottomBarIntegrationTests/testEveryTableOwnerKeepsBottomClearanceAndPreservesAwayFromBottomOffset;xabberTests/CallsListCoordinatorTests/testDetachedDatasourceApplyCommitsOnlyLatestSnapshotBeforeFirstFrame;xabberTests/CallsListCoordinatorTests/testAttachedDatasourceApplyPolicyKeepsIncrementalDiffs;xabberChatPerformanceUITests/ChatPerformanceUITests/testChatOpenP14LastChatsSeededMentionVideoRoute
P15|source-candidate|xabberTests/LastChatsNavigationSingleFlightTests/testPresentedSameConversationAcceptsExactNotificationIntentWithoutSecondPush;xabberTests/ChatMessageAnchorPolicyTests/testLoadedSearchRequestCallsPositioningStartedBeforePositioned;xabberTests/ChatMessageAnchorPolicyTests/testAnchorContextPrefetchSkipsRemoteLoadsWhenLocalContextIsSufficient
P16|source-candidate|xabberTests/PushNotificationRoutingTests/testDuplicateTapProducesOneNavigationAnchorAndReadVisibleEffect
P17|source-candidate|xabberTests/CrossAccountPushRoutingTests/testPushForOtherOwnerSwitchesAccountAndPublishesZeroOldConversationRows
P18|source-candidate|xabberTests/PushNotificationRoutingTests/testMissingNavigationDelegateDefersTheCompleteExactMessageRoute;xabberTests/PushNotificationRoutingTests/testDuplicateDeferredTapsCoalesceAndSuccessfulRetryConsumesTheRouteOnce
G01|source-candidate|xabberTests/RegularChatArchiveSyncStateTests/testDisjointRegularArchiveRangesRecordKnownGap
G02|source-candidate|xabberTests/ChatVirtualTimelineEngineTests/testOpenLatestBuildsBoundedLiveTailSnapshot;xabberTests/RegularChatArchiveSyncStateTests/testDisjointRegularArchiveRangesRecordKnownGap;xabberTests/ChatPerformanceLabTests/testLatestWithUnrelatedOlderGapFixtureKeepsGapOutsideLiveTailAndSelectsNoAnchor;xabberChatPerformanceUITests/ChatPerformanceUITests/testChatOpenG02LatestWithUnrelatedOlderGapVideoRoute
G03|source-candidate|xabberTests/ChatGapLocalTargetTests/testTargetOnNewerGapSidePublishesDirectlyAndBackgroundRepairCannotMoveIt
G04|source-candidate|xabberTests/ChatGapLocalTargetTests/testTargetOnOlderGapSidePublishesDirectlyAndBackgroundRepairCannotMoveIt
G05|source-candidate|xabberTests/ChatVirtualTimelineEngineTests/testKnownGapBlocksLocalCrossingAndChoosesRepairCursor;xabberChatPerformanceUITests/ChatPerformanceUITests/testChatOpenG05KnownGapMissingTargetVideoRoute
G06|source-candidate|xabberTests/MessageArchivePagingRequestTests/testRegularGapRepairOlderPlanUsesNewerGapBoundaryAsBeforeCursor;xabberChatPerformanceUITests/ChatPerformanceUITests/testChatOpenG06OlderCrossingGapVideoRoute
G07|source-candidate|xabberTests/MessageArchivePagingRequestTests/testRegularGapRepairNewerPlanUsesOlderGapBoundaryAsAfterCursor;xabberChatPerformanceUITests/ChatPerformanceUITests/testChatOpenG07NewerCrossingGapVideoRoute
G08|source-candidate|xabberTests/ChatArchiveBoundaryGapPagingPolicyTests/testBoundaryGapPolicyDoesNotRepairWhenRequestedPageStaysOnSameSide;xabberTests/ChatVirtualTimelineEngineTests/testExactPageLocalOlderRemainderStillAppliesLocally
G09|source-candidate|xabberTests/ChatArchiveBoundaryGapPagingPolicyTests/testOlderBoundaryGapRepairUsesOnlyCurrentAndRequestedBoundaries;xabberTests/ChatArchiveBoundaryGapPagingPolicyTests/testNewerBoundaryGapRepairUsesOnlyCurrentAndRequestedBoundaries;xabberTests/ChatVirtualTimelineEngineTests/testShortLocalOlderRemainderCrossingKnownGapUsesGapRepair
G10|source-candidate|xabberTests/ChatGapRepairIntegrationTests/testPartialRepairCommitPerformsExactlyOneOffMainRefetchMapAndApply
G11|source-candidate|xabberTests/ChatGapRepairIntegrationTests/testZeroRowGapTerminalClosesOnlyProvenEdgeAndDoesNotLoop
G12|source-candidate|xabberTests/ChatGapRepairIntegrationTests/testGapFailureKeepsExistingRowsInteractiveAndGeometryUnchangedWithOneRetryPolicy
G13|source-candidate|xabberTests/ChatRemoteMAMPersistenceCoordinatorTests/testDuplicateFinalAndStaleGenerationCannotRunBarrierOrResolveTwice;xabberTests/ChatAnchorTransactionTests/testDuplicateFinalAndPositionHooksAreAcceptedOnlyOnceAndInOrder
G14|source-candidate|xabberTests/ChatSearchMAMPagingTests/testSearchPurposeNeverProducesRegularArchiveCoverageOrHistoryCursor;xabberTests/ChatSearchTimestampMAMResolverTests/testTimestampPurposeNeverProducesHistoryCoverageOrCursor;xabberTests/MessageArchiveRequestClassificationTests/testArchiveProducingPurposesAreClassifiedExplicitly;xabberTests/MessageArchivePagingRequestTests/testRegularExactAnchorPlanUsesIdsWithArchivedIdOnly
G15|source-candidate|xabberTests/ChatCollectionAnchorPreservationTests/testControllerPrependCommitsAnchorWithOneLayoutAndOneOffsetMutation;xabberTests/ChatFirstFrameLocalHistoryRegressionTests/testLocalOlderPageKeepsCapturedAnchorViewportPositionAfterApply
G16|source-candidate|xabberTests/ChatFirstFrameLocalHistoryRegressionTests/testPreparedNewerPageAppliesAfterScrollRestWithoutBottomJump;xabberTests/ChatFirstFrameLocalHistoryRegressionTests/testNewerApplyFromBottomOverlayAppendsRowsWithoutMovingVisibleAnchor
G17|source-candidate|xabberTests/ChatIncrementalMessageApplyTests/testIncomingViewportDecisionPinsNearTailAndPreservesAwayWithBadge;xabberTests/ChatFirstFrameLocalHistoryRegressionTests/testObserverRefreshWithNewNewestUpdatesLatestWindowWithoutLeavingBottom
G18|source-candidate|xabberTests/ChatIncrementalMessageApplyTests/testUnknownIncomingAwayFromLiveTailDoesNotReplaceResidentWindow;xabberTests/ChatIncrementalMessageApplyTests/testIncomingViewportDecisionPinsNearTailAndPreservesAwayWithBadge
G19|source-candidate|xabberTests/ChatCollectionPrefetchTests/testPageWarmupUsesOnlyCachedLocalBoundaryAvailability;xabberTests/ChatFirstFrameLocalHistoryRegressionTests/testRemoteOlderAtRestArmsWithoutVisibleLoaderUntilTransportStarts
G20|source-candidate|xabberTests/ChatSkeletonLifecycleTests/testBoundaryOverlayDoesNotChangeTimelineIdentityOrGeometry;xabberTests/ChatRemoteMAMPersistenceCoordinatorTests/testBoundaryLoadingPresentationHasZeroTimelineGeometryDelta;xabberTests/ChatFirstFrameLocalHistoryRegressionTests/testNewerBoundaryLoadingOverlayDoesNotAddRowOrMoveVisibleAnchor
V01|source-candidate|xabberTests/ChatOpenBackdropTests/testAnimatedPushHasOpaqueDestinationBackdropBeforeFirstRowAndNeverUsesDirectChatRoot;xabberChatPerformanceUITests/ChatPerformanceUITests/testChatOpenV01LastChatsAnimatedPushVideoRoute
V02|source-candidate|xabberTests/ChatSkeletonLifecycleTests/testRepeatedBlockingEventsPreserveRowsGenerationOrderSizeAndOffset
V03|source-candidate|xabberTests/ChatInitialPresentationAtomicityRegressionTests/testSkeletonToNewestCommitsReloadAndTargetOffsetInsideOneVisualTransaction;xabberTests/ChatInitialPresentationAtomicityRegressionTests/testAtomicInitialFrameReceiptPublishesAfterResolvedAnchorAlignment
V04|source-candidate|xabberTests/ChatInitialPresentationAtomicityRegressionTests/testUnresolvedAtomicTargetRestoresCommittedSkeletonAndDoesNotPublishContent;xabberTests/ChatInitialPresentationAtomicityRegressionTests/testAtomicPresentationFailureUsesOneFreshMappingGenerationThenTerminalRetry
V05|source-candidate|xabberTests/ChatSkeletonLifecycleTests/testConfirmedEmptyCannotReenterSkeletonAfterLateBootstrapMetadata
V06|source-candidate|xabberTests/ChatInitialPresentationAtomicityRegressionTests/testSameNewestObserverRefreshIsDiscardedAfterInitialFrameReceipt;xabberTests/ChatFirstFrameLocalHistoryRegressionTests/testObserverRefreshWithSameNewestDoesNotMoveBottomAlignedLatestFirstFrame;xabberTests/ChatTimelineSessionTests/testStructuralPublishBetweenAuthoritativeCaptureAndObservationInstallRejectsOldInitialBatch;xabberTests/ChatTimelineSessionTests/testSupersededResidentDeliveryPreservesIndependentLatestAndUnreadMetadata;xabberTests/ChatTimelineSessionTests/testProductionEditPublishesEditedBodyThroughRealmTimelineAndDisplayMapping
V07|source-candidate|xabberTests/ChatIncrementalMessageApplyTests/testAppendAtLiveTailTrimsOppositeEdgeInSameApply;xabberTests/ChatFirstFrameLocalHistoryRegressionTests/testObserverRefreshWithNewNewestUpdatesLatestWindowWithoutLeavingBottom
V08|source-candidate|xabberTests/ChatCollectionAnchorPreservationTests/testControllerLayoutRemapKeepsLiveTailAcrossPortraitLandscapePortrait;xabberTests/ChatCollectionAnchorPreservationTests/testControllerLayoutRemapPreservesVisibleMessageAcrossPortraitLandscapePortrait;xabberChatPerformanceUITests/ChatPerformanceUITests/testChatOpenV08RotationRealPipelineVideoRoute
V09|source-candidate|xabberTests/ChatLayoutLifecycleTests/testLargestDynamicTypePreservesBottomAndExplicitAnchorAcrossFirstFrameRemap
V10|source-candidate|xabberTests/ChatLayoutLifecycleTests/testBackgroundForegroundAfterContentPreservesDatasourceAnchorAndNeverShowsSkeletonOrLatest;xabberChatPerformanceUITests/ChatPerformanceUITests/testChatOpenV10BackgroundForegroundVideoRoute
V11|source-candidate|xabberChatPerformanceUITests/ChatNativeBackUITests/testChevronOnlyBackMeetsHitTargetAndSupportsTapAndSuccessfulEdgeSwipe
V12|source-candidate|xabberTests/ChatNavigationCancellationTests/testCancelledEdgePopPreservesDatasourceGenerationAndSemanticOffset
V13|source-candidate|xabberTests/ChatInitialPositionPolicyTests/testDeterministicOpeningMatrixKeepsTargetSelectionAndReadSideEffectsSeparated;xabberTests/ChatMessageAnchorPolicyTests/testOpenReadMarkingPolicyDoesNotReadLastMessageJustBecauseUnreadChatOpened;xabberTests/ChatFirstFrameLocalHistoryRegressionTests/testSkeletonRevealDoesNotClearUnreadCountersBeforeVisibleReadBoundary;xabberTests/ChatViewportReadBoundaryTests/testOrdinaryViewportReadWaitsForCommittedInitialFrameAndStructuralTransactionCompletion;xabberTests/ChatViewportReadBoundaryTests/testPendingFlushWaitsForStructurallyVisiblePresentationReceipt
V14|source-candidate|xabberTests/ChatViewportReadBoundaryTests/testBottommostVisibleIncomingAdvancesBoundary;xabberTests/ChatViewportReadBoundaryTests/testVisibleOutgoingDoesNotAdvanceIncomingBoundary;xabberTests/ChatViewportReadBoundaryTests/testBackwardScrollingDoesNotRegressBoundary;xabberTests/ChatViewportReadBoundaryTests/testPendingFlushUsesLoadedOrderInsteadOfSentDate;xabberTests/ChatViewportReadBoundaryTests/testViewportReadBoundaryRejectsSliverUntilTargetIsMeaningfullyVisible;xabberTests/ChatViewportReadBoundaryTests/testViewportReadBoundaryRevalidatesTargetThatLeavesMeaningfulViewportBeforeMutation
V15|source-candidate|xabberTests/ChatUnreadMentionsTests/testJumpToBottomAndSendDoNotReadOffscreenMentionTargets;xabberTests/ChatUnreadMentionsTests/testMentionReadRequiresMeaningfulTargetIntersection
V16|source-candidate|xabberTests/ChatSingleFrameLocalOpenTests/testOneHundredAndOneMillionHistoriesHaveIdenticalPreparationBudgets;xabberTests/ChatFinalIntegrationGateTests/testSmallAndMillionOpenHaveTheSameBoundedFirstFrameAndOperationEnvelope
ROWS
}

chat_open_acceptance_source_index() {
  repo_root=$1
  for source in "$repo_root"/xabberTests/*.swift "$repo_root"/xabberChatPerformanceUITests/*.swift; do
    [ -f "$source" ] || continue
    module=xabberTests
    case "$source" in
      "$repo_root"/xabberChatPerformanceUITests/*) module=xabberChatPerformanceUITests ;;
    esac
    relative_source=${source#"$repo_root"/}
    awk -v module="$module" -v source="$relative_source" '
      BEGIN {
        depth = 0
        class_count = 0
      }
      {
        while (class_count > 0 && depth < class_depth[class_count]) {
          delete class_name[class_count]
          delete class_depth[class_count]
          class_count -= 1
        }
      }
      /class[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*:/ {
        line = $0
        sub(/^.*class[[:space:]]+/, "", line)
        sub(/[^A-Za-z0-9_].*$/, "", line)
        class_count += 1
        class_name[class_count] = line
        class_depth[class_count] = depth + 1
      }
      /extension[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*[:{]/ {
        line = $0
        sub(/^.*extension[[:space:]]+/, "", line)
        sub(/[^A-Za-z0-9_].*$/, "", line)
        class_count += 1
        class_name[class_count] = line
        class_depth[class_count] = depth + 1
      }
      /func[[:space:]]+test[A-Za-z0-9_]*[[:space:]]*\(/ {
        line = $0
        sub(/^.*func[[:space:]]+/, "", line)
        sub(/[[:space:]]*\(.*/, "", line)
        if (class_count > 0) {
          print module "/" class_name[class_count] "/" line "|" source
        }
      }
      {
        braces = $0
        opens = gsub(/\{/, "", braces)
        braces = $0
        closes = gsub(/\}/, "", braces)
        depth += opens - closes
      }
    ' "$source"
  done
}

chat_open_acceptance_validate() (
  repo_root=$(CDPATH= cd -- "$CHAT_OPEN_ACCEPTANCE_SCRIPT_DIR/.." && pwd)
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/chat-open-acceptance-manifest.XXXXXX") || return 1
  trap 'rm -rf "$work_dir"' EXIT HUP INT TERM

  rows_file="$work_dir/rows.txt"
  expected_file="$work_dir/expected.txt"
  actual_file="$work_dir/actual.txt"
  source_index="$work_dir/source-index.txt"
  selectors_file="$work_dir/selectors.txt"
  errors_file="$work_dir/errors.txt"

  chat_open_acceptance_rows > "$rows_file"
  chat_open_acceptance_expected_ids | LC_ALL=C sort > "$expected_file"
  cut -d '|' -f 1 "$rows_file" | LC_ALL=C sort > "$actual_file"
  chat_open_acceptance_source_index "$repo_root" | LC_ALL=C sort > "$source_index"
  : > "$selectors_file"
  : > "$errors_file"

  row_count=$(wc -l < "$rows_file" | tr -d ' ')
  unique_id_count=$(cut -d '|' -f 1 "$rows_file" | LC_ALL=C sort -u | wc -l | tr -d ' ')
  if [ "$row_count" -ne 95 ]; then
    printf 'expected 95 rows, found %s\n' "$row_count" >> "$errors_file"
  fi
  if [ "$unique_id_count" -ne "$row_count" ]; then
    printf 'matrix IDs are not unique: rows=%s unique=%s\n' "$row_count" "$unique_id_count" >> "$errors_file"
  fi
  if ! cmp -s "$expected_file" "$actual_file"; then
    printf 'manifest ID set differs from the locked 95-row matrix:\n' >> "$errors_file"
    diff -u "$expected_file" "$actual_file" >> "$errors_file" || true
  fi

  while IFS='|' read -r matrix_id source_state selectors extra; do
    if [ -z "$matrix_id" ] || [ -z "$source_state" ] || [ -z "$selectors" ] || [ -n "${extra:-}" ]; then
      printf '%s has an invalid three-field manifest record\n' "${matrix_id:-<blank>}" >> "$errors_file"
      continue
    fi
    case "$source_state" in
      source-candidate|source-lock-pending) ;;
      *) printf '%s has unsupported source state %s\n' "$matrix_id" "$source_state" >> "$errors_file" ;;
    esac

    old_ifs=$IFS
    IFS=';'
    set -- $selectors
    IFS=$old_ifs
    if [ "$#" -eq 0 ]; then
      printf '%s has no selectors\n' "$matrix_id" >> "$errors_file"
      continue
    fi
    row_selector_file="$work_dir/row-$matrix_id.txt"
    : > "$row_selector_file"
    for selector in "$@"; do
      printf '%s\n' "$selector" >> "$selectors_file"
      printf '%s\n' "$selector" >> "$row_selector_file"
      case "$selector" in
        xabberTests/*/test*|xabberChatPerformanceUITests/*/test*) ;;
        *)
          printf '%s has malformed selector %s\n' "$matrix_id" "$selector" >> "$errors_file"
          continue
          ;;
      esac
      match_count=$(grep -F -c "$selector|" "$source_index" || true)
      if [ "$match_count" -ne 1 ]; then
        printf '%s selector %s resolves to %s current XCTest bodies\n' "$matrix_id" "$selector" "$match_count" >> "$errors_file"
      fi
    done
    row_selector_count=$(wc -l < "$row_selector_file" | tr -d ' ')
    row_unique_selector_count=$(LC_ALL=C sort -u "$row_selector_file" | wc -l | tr -d ' ')
    if [ "$row_selector_count" -ne "$row_unique_selector_count" ]; then
      printf '%s repeats a selector within the row\n' "$matrix_id" >> "$errors_file"
    fi
  done < "$rows_file"

  selector_count=$(wc -l < "$selectors_file" | tr -d ' ')
  unique_selector_count=$(LC_ALL=C sort -u "$selectors_file" | wc -l | tr -d ' ')
  pending_count=$(awk -F '|' '$2 == "source-lock-pending" { count += 1 } END { print count + 0 }' "$rows_file")

  if [ -s "$errors_file" ]; then
    cat "$errors_file" >&2
    return 1
  fi

  printf 'manifest_version=%s rows=%s unique_ids=%s selector_references=%s unique_selectors=%s source_lock_pending=%s validation=pass\n' \
    "$CHAT_OPEN_ACCEPTANCE_MANIFEST_VERSION" \
    "$row_count" \
    "$unique_id_count" \
    "$selector_count" \
    "$unique_selector_count" \
    "$pending_count"
)

chat_open_acceptance_usage() {
  cat <<'USAGE'
Usage: tools/chat_open_acceptance_manifest.sh [validate|rows|selectors|version]

  validate   Validate the exact 95-row ID set and every current Class/testMethod (default).
  rows       Print ID, source state, and semicolon-delimited selectors.
  selectors  Print unique current xcodebuild selectors, one per line.
  version    Print the manifest version.
USAGE
}

chat_open_acceptance_main() {
  command=${1:-validate}
  case "$command" in
    validate)
      chat_open_acceptance_validate
      ;;
    rows)
      chat_open_acceptance_rows
      ;;
    selectors)
      chat_open_acceptance_rows \
        | cut -d '|' -f 3 \
        | tr ';' '\n' \
        | LC_ALL=C sort -u
      ;;
    version)
      printf '%s\n' "$CHAT_OPEN_ACCEPTANCE_MANIFEST_VERSION"
      ;;
    -h|--help|help)
      chat_open_acceptance_usage
      ;;
    *)
      chat_open_acceptance_usage >&2
      return 64
      ;;
  esac
}

if [ "${CHAT_OPEN_ACCEPTANCE_MANIFEST_NO_MAIN:-0}" != "1" ]; then
  chat_open_acceptance_main "$@"
fi
