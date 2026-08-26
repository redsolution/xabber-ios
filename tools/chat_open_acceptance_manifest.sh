#!/usr/bin/env bash

# Exact source-candidate selector manifest for the 95-row chat-open acceptance matrix.
#
# The hard-cut manifest intentionally points only at the current archive engine,
# virtual timeline, admission, synchronization, vCard, persistence/SCA and live UI
# contracts. It is compatible with the Bash 3.2 shipped by macOS.

set -u

CHAT_OPEN_ACCEPTANCE_MANIFEST_VERSION="2026-08-25.2"
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
# Reusing a selector across rows is intentional when one focused body proves
# material clauses for more than one scenario. Every locked matrix ID remains.
chat_open_acceptance_rows() {
  cat <<'ROWS'
N01|source-candidate|xabberTests/AccountArchiveEngineTests/testPreviousSessionCoverageDoesNotAdmitWithoutCurrentSessionMAMProof;xabberTests/ClientSynchronizationPaginationTests/testInitialSnapshotAppliesThreeHundredTwoConversationFixtureAcrossAllPages;xabberTests/VCardRequestSingleFlightCoordinatorTests/testOneHundredMissingVCardsNeverCreateMoreThanOneOutstandingIQ
N02|source-candidate|xabberTests/AccountArchiveEngineTests/testRepeatedReadinessForVerifiedGenerationDoesNotReprobeWindow
N03|source-candidate|xabberTests/AccountArchiveEngineTests/testRepeatedReadinessForSameGenerationKeepsActiveLatestAndAcceptsItsReceipt;xabberTests/VCardRequestSingleFlightCoordinatorTests/testDuplicateBareJIDJoinsOneGenerationScopedRequest
N04|source-candidate|xabberTests/ArchiveTransportReceiptTests/testSearchAndExactAnchorRowsNeverProduceTimelineCoverage
N05|source-candidate|xabberTests/ArchiveCoverageRepositoryTests/testExactTargetBecomesCoverageOnlyAfterOlderAndNewerProofs
N06|source-candidate|xabberTests/AccountArchiveEngineTests/testOfflineOpenAlwaysPublishesFullSkeletonEvenWithCachedSnapshot
N07|source-candidate|xabberTests/AccountArchiveEngineTests/testPreviousSessionCoverageDoesNotAdmitWithoutCurrentSessionMAMProof
N08|source-candidate|xabberTests/ChatArchiveVirtualTimelineIntegrationTests/testOlderThenNewerRematerializesEvictedRowsFromRealm
N09|source-candidate|xabberTests/ChatArchiveEngineUIContractTests/testOpeningAndTargetArchivePathsOwnTheVisibleCriticalSection
N10|source-candidate|xabberTests/AccountArchiveEngineTests/testDuplicateSemanticIntentsJoinOneTransportAndPromotePriority
N11|source-candidate|xabberTests/AccountArchiveEngineTests/testGapLargerThanOnePageAdvancesCursorUntilContinuousProofCompletes
N12|source-candidate|xabberTests/AccountArchiveEngineTests/testDisconnectImmediatelyReplacesVerifiedContentWithSkeletonAndReconnectResumesIntent
N13|source-candidate|xabberTests/ChatArchiveEngineUIContractTests/testSearchPresentationReplacesEvictedResidentPageInsteadOfAppendingForever
N14|source-candidate|xabberTests/AccountArchiveEngineTests/testDisconnectKeepsOfflineSkeletonWhenLateSessionReceiptArrives;xabberTests/ClientSynchronizationPaginationTests/testInitialSnapshotProjectsThreeHundredUnknownGroupsAsListOnlyRows
E01|source-candidate|xabberTests/ArchiveTransportReceiptTests/testNewestUnfilteredZeroPageIsAuthoritativeWithoutCounter
E02|source-candidate|xabberTests/ArchiveTransportReceiptTests/testCursorOrFilteredZeroPageIsNeverAuthoritativeEmpty;xabberTests/ChatVirtualTimelineEngineTests/testConsumedOnlyVerifiedWindowInstallsEmptyResidentWithoutLosingProof
E03|source-candidate|xabberTests/ArchiveCoverageRepositoryTests/testCommitRequiresPersistedConversationMessagesBeforeCoverageProof
E04|source-candidate|xabberTests/AccountArchiveEngineTests/testPreviousSessionCoverageDoesNotAdmitWithoutCurrentSessionMAMProof;xabberTests/SensitiveMediaAnalysisStartupSchedulerTests/testPrepareForLaunchDefersScanUntilAccountOnline
E05|source-candidate|xabberTests/AccountArchiveEngineTests/testRepeatedReadinessForVerifiedGenerationDoesNotReprobeWindow;xabberTests/SensitiveMediaAnalysisServiceTests/testDuplicateAnalysisIsNotStartedForSamePrimaryKey
E06|source-candidate|xabberTests/ArchiveTransportReceiptTests/testDuplicateFinalDeliveryWaitsForPersistenceAndCompletesExactlyOnce;xabberTests/MessageManagerQueueSynchronizationTests/testArchiveTerminalRequiresMessageReferenceAndAttachmentDurability
E07|source-candidate|xabberTests/ArchiveTransportReceiptTests/testRejectsResultBeforeFinalPartialPersistenceAndStaleIdentity;xabberTests/MessageManagerQueueSynchronizationTests/testArchiveVideoPreviewSchedulingStartsAfterTerminal
E08|source-candidate|xabberTests/ArchiveTransportReceiptTests/testCursorOrFilteredZeroPageIsNeverAuthoritativeEmpty;xabberTests/MessageManagerQueueSynchronizationTests/testBlockedEnabledSensitiveAnalysisStartsAfterTerminalAndDoesNotDelayMaterialization
E09|source-candidate|xabberTests/ArchiveTransportReceiptTests/testRejectsResultBeforeFinalPartialPersistenceAndStaleIdentity
E10|source-candidate|xabberTests/ArchiveTransportReceiptTests/testMissingFinalTimesOutAndReleasesMamSchedulerSlot
E11|source-candidate|xabberTests/AccountArchiveEngineTests/testTransientFailureUsesSevenActorBackoffRetriesBeforePresentationAutomaticRecovery
E12|source-candidate|xabberTests/AccountArchiveEngineTests/testProtocolFailurePublishesAutomaticRecoveryStateWithoutActorRetryLoop;xabberTests/ChatArchiveEngineUIContractTests/testTerminalRetryableFailureSchedulesEngineOwnedAutomaticRetry;xabberTests/ChatArchiveEnginePresentationTests/testAutomaticHistoryRetryBackoffAccumulatesAcrossActorCyclesAndCapsAtThirtySeconds;xabberTests/ChatArchiveEnginePresentationTests/testAutomaticHistoryRetryKeepsCumulativeAttemptUntilSemanticRequestTerminates
E13|source-candidate|xabberTests/ArchiveTransportReceiptTests/testDuplicateFinalDeliveryWaitsForPersistenceAndCompletesExactlyOnce;xabberTests/MessageManagerQueueSynchronizationTests/testDuplicateArchiveBatchSealJoinsOnePersistencePassAndReturnsImmutableSummary
E14|source-candidate|xabberTests/AccountArchiveEngineTests/testDuplicateSemanticIntentsJoinOneTransportAndPromotePriority
E15|source-candidate|xabberTests/AccountArchiveEngineSearchTests/testReplacementIgnoresLateReceiptFromStaleSearchGeneration
E16|source-candidate|xabberTests/CanonicalGroupOpenAdmissionCoordinatorTests/testDisconnectWhileRefreshingPreventsCommitAndLateCompletion
E17|source-candidate|xabberTests/ArchiveTransportReceiptTests/testReconnectGenerationQueuesSameWindowBehindRunningMAMAndCompletesBothContinuations;xabberTests/VCardRequestSingleFlightCoordinatorTests/testDisconnectReleasesLaneAndLateOldGenerationResponseIsIgnored
E18|source-candidate|xabberTests/AccountArchiveEngineTests/testDisconnectImmediatelyReplacesVerifiedContentWithSkeletonAndReconnectResumesIntent
X01|source-candidate|xabberTests/AccountArchiveEngineSearchTests/testFirstPageIsOneSearchPriorityRequestAndContinuationIsExplicit
X02|source-candidate|xabberTests/ChatArchiveVirtualTimelineIntegrationTests/testOlderThenNewerRematerializesEvictedRowsFromRealm
X03|source-candidate|xabberTests/AccountArchiveEngineSearchTests/testGroupAdmissionCompletesBeforeSearchMAMStarts
X04|source-candidate|xabberTests/ArchiveCoverageRepositoryTests/testExactTargetBecomesCoverageOnlyAfterOlderAndNewerProofs;xabberTests/ArchiveTransportReceiptTests/testSearchAndExactAnchorRowsNeverProduceTimelineCoverage
X05|source-candidate|xabberTests/AccountArchiveEngineSearchTests/testReplacementIgnoresLateReceiptFromStaleSearchGeneration
X06|source-candidate|xabberTests/AccountArchiveEngineSearchTests/testNonAdvancingCursorFailsClosedWithoutLosingCurrentPage
X07|source-candidate|xabberTests/AccountArchiveEngineSearchTests/testTransientFailureRetainsPagesAndContinuationCursor
X08|source-candidate|xabberTests/AccountArchiveEngineSearchTests/testResidentSearchWindowKeepsOnlyThreePages
X09|source-candidate|xabberTests/AccountArchiveEngineSearchTests/testReconnectResumesOnlyLatestSearchAcrossConversationsAndIgnoresLateReceipt
P01|source-candidate|xabberTests/PushNotificationRoutingTests/testForegroundNotificationTapStillOpensTheExactMessageRoute
P02|source-candidate|xabberTests/ChatArchiveEngineUIContractTests/testOpeningAndTargetArchivePathsOwnTheVisibleCriticalSection
P03|source-candidate|xabberTests/PushNotificationSceneRoutingTests/testSuspendedTapPreservesOwnerConversationTypeAndExactTargetUntilVisible
P04|source-candidate|xabberTests/AppRootColdPushRoutingTests/testColdPushNativeDidShowPreservesCommittedSkeletonUntilContentCommit
P05|source-candidate|xabberTests/PushNotificationRoutingTests/testLocalMessageNotificationBuildsExactMessageAnchorRequest;xabberTests/PushNotificationRoutingTests/testRichPushNotificationBuildsTheSameExactMessageAnchorRequest
P06|source-candidate|xabberTests/PushNotificationRoutingTests/testLegacyMessageWithoutStableIdentityProducesTypedFallbackAndNeverExactSuccess
P07|source-candidate|xabberTests/PushNotificationRoutingTests/testSentCarbonUsesInnerMessageForCanonicalExactOpenRequest
P08|source-candidate|xabberTests/PushNotificationRoutingTests/testSentCarbonUsesInnerMessageForCanonicalExactOpenRequest
P09|source-candidate|xabberTests/AccountArchiveEngineTests/testGapLargerThanOnePageAdvancesCursorUntilContinuousProofCompletes
P10|source-candidate|xabberTests/PushNotificationRoutingTests/testGroupChatMessageUsesGroupRouteAndSenderNickname;xabberTests/AccountArchiveEngineTests/testGroupAdmissionCompletesBeforeArchiveTransportStarts;xabberTests/CanonicalGroupOpenAdmissionCoordinatorTests/testAdmissionFetchesOnlyGroupAndMembersThenCommitsResolvedSelf
P11|source-candidate|xabberTests/NotificationsFeatureTests/testMentionOpenRequestUsesOriginalMessageAnchorMetadataInsteadOfOuterNotificationIdentity
P12|source-candidate|xabberTests/ChatUnreadMentionsTests/testMatchingMessagePrefersArchivedIdOverMessageIdFallback
P13|source-candidate|xabberTests/MentionOpenRoutingTests/testDeletedTappedMentionAdvancesOrFailsWithoutReportingLatestAsSuccess
P14|source-candidate|xabberTests/ChatListUnreadMentionBadgeTests/testLastChatsUnreadMentionOpenRequestUsesUnreadNotificationAnchorMetadata;xabberTests/ClientSynchronizationPaginationTests/testIncrementalSyncProjectsThreeHundredUnknownGroupsWithoutHydration
P15|source-candidate|xabberTests/ChatArchiveEngineUIContractTests/testOpeningAndTargetArchivePathsOwnTheVisibleCriticalSection
P16|source-candidate|xabberTests/PushNotificationRoutingTests/testDuplicateTapProducesOneNavigationAnchorAndReadVisibleEffect
P17|source-candidate|xabberTests/CrossAccountPushRoutingTests/testPushForOtherOwnerSwitchesAccountAndPublishesZeroOldConversationRows
P18|source-candidate|xabberTests/PushNotificationRoutingTests/testMissingNavigationDelegateDefersTheCompleteExactMessageRoute;xabberTests/PushNotificationRoutingTests/testDuplicateDeferredTapsCoalesceAndSuccessfulRetryConsumesTheRouteOnce
G01|source-candidate|xabberTests/ArchiveCoverageRepositoryTests/testOlderCommitReturnsOneMergedVerifiedWindowAroundBoundary
G02|source-candidate|xabberTests/ChatVirtualTimelineEngineTests/testThreeHundredSixtyThreeLoadedRowsStayResidentWithoutEviction
G03|source-candidate|xabberTests/ChatVirtualTimelineEngineTests/testLocalPagingFiltersRowsOutsideImmutableVerifiedScope
G04|source-candidate|xabberTests/ArchiveCoverageRepositoryTests/testExactTargetBecomesCoverageOnlyAfterOlderAndNewerProofs
G05|source-candidate|xabberTests/AccountArchiveEngineTests/testGapLargerThanOnePageAdvancesCursorUntilContinuousProofCompletes
G06|source-candidate|xabberTests/ArchiveTransportReceiptTests/testIncompleteGapPageJoinsTheKnownNewerSegmentForNextCursorAdvance
G07|source-candidate|xabberTests/ArchiveTransportReceiptTests/testIncompleteGapPageJoinsTheKnownNewerSegmentForNextCursorAdvance
G08|source-candidate|xabberTests/ChatVirtualTimelineEngineTests/testDirectionalEvictionStartsOnlyAboveSixPages
G09|source-candidate|xabberTests/ChatArchiveVirtualTimelineIntegrationTests/testPreparedBoundaryBecomesStaleWhenVerifiedProofChanges;xabberTests/ChatArchiveEnginePresentationTests/testBenignLocalBoundaryDriftNeverEscalatesToEdgeRetry;xabberTests/ChatArchiveEnginePresentationTests/testBenignLocalBoundaryRecoveryCannotReenterPagingGatewayOrExposeRetry;xabberTests/ChatArchiveEnginePresentationTests/testLocalBoundaryInvalidationCallSitesUseTypedRecoveryRouter
G10|source-candidate|xabberTests/ArchiveCoverageRepositoryTests/testOlderCommitReturnsOneMergedVerifiedWindowAroundBoundary
G11|source-candidate|xabberTests/ArchiveTransportReceiptTests/testNewestUnfilteredZeroPageIsAuthoritativeWithoutCounter
G12|source-candidate|xabberTests/AccountArchiveEngineTests/testTerminalBoundaryFailureClearsActivityWithoutDiscardingVerifiedWindow
G13|source-candidate|xabberTests/ArchiveTransportReceiptTests/testDuplicateFinalDeliveryWaitsForPersistenceAndCompletesExactlyOnce;xabberTests/MessageManagerQueueSynchronizationTests/testSealedArchiveBatchDoesNotPublishTerminalBeforePersistenceFinishes
G14|source-candidate|xabberTests/ArchiveTransportReceiptTests/testSearchAndExactAnchorRowsNeverProduceTimelineCoverage;xabberTests/AccountArchiveEngineSearchTests/testFirstPageIsOneSearchPriorityRequestAndContinuationIsExplicit
G15|source-candidate|xabberTests/ChatArchiveVirtualTimelineIntegrationTests/testOlderThenNewerRematerializesEvictedRowsFromRealm
G16|source-candidate|xabberTests/ChatArchiveEnginePresentationTests/testCurrentBoundaryAnchorSupersedesAnchorCapturedAtRequestStart
G17|source-candidate|xabberTests/ArchiveCoverageRepositoryTests/testPersistedLiveMessageExtendsProofButMaterializesOnlyRequestedLiveRow
G18|source-candidate|xabberTests/ChatVirtualTimelineEngineTests/testThreeHundredSixtyThreeLoadedRowsStayResidentWithoutEviction
G19|source-candidate|xabberTests/ChatArchiveVirtualTimelineIntegrationTests/testIdenticalPreparedBoundaryRequestsCoalesceIntoOneStoreQuery
G20|source-candidate|xabberTests/ChatArchiveEnginePresentationTests/testBoundaryLoadingIndicatorCoversIntentThroughUIKitApplyCompletion;xabberTests/ChatArchiveEngineUIContractTests/testVisibleArchiveCriticalSectionAcquiresAndReleasesAccountGate;xabberTests/ChatArchiveEnginePresentationTests/testSkeletonStateCommitFailureAndOfflineReleaseInteractiveGate
V01|source-candidate|xabberTests/ChatImmediateNavigationControlsTests/testLastChatsPreparesVisibleBackChevronBeforeChatPush
V02|source-candidate|xabberTests/AccountArchiveEngineTests/testOfflineOpenAlwaysPublishesFullSkeletonEvenWithCachedSnapshot
V03|source-candidate|xabberTests/ChatArchiveEngineUIContractTests/testVisibleArchiveCriticalSectionAcquiresAndReleasesAccountGate
V04|source-candidate|xabberTests/ChatArchiveEnginePresentationTests/testHistoryFailurePathsNeverPresentRetryAffordances;xabberTests/ChatArchiveEngineUIContractTests/testHistoryRecoveryAffordanceTypesAndControllerPlumbingAreAbsent
V05|source-candidate|xabberTests/ArchiveTransportReceiptTests/testNewestUnfilteredZeroPageIsAuthoritativeWithoutCounter
V06|source-candidate|xabberTests/ChatArchiveVirtualTimelineIntegrationTests/testPreparedBoundaryBecomesStaleWhenVerifiedProofChanges
V07|source-candidate|xabberTests/ChatVirtualTimelineEngineTests/testDirectionalEvictionStartsOnlyAboveSixPages
V08|source-candidate|xabberTests/ChatCollectionAnchorPreservationTests/testControllerLayoutRemapPreservesVisibleMessageAcrossPortraitLandscapePortrait
V09|source-candidate|xabberTests/ChatCollectionAnchorPreservationTests/testControllerLayoutRemapKeepsLiveTailAcrossPortraitLandscapePortrait
V10|source-candidate|xabberTests/AccountArchiveEngineTests/testDisconnectImmediatelyReplacesVerifiedContentWithSkeletonAndReconnectResumesIntent
V11|source-candidate|xabberTests/ChatImmediateNavigationControlsTests/testConfigureNavbarKeepsSystemBackIndicatorAvailableImmediately;xabberTests/ChatImmediateNavigationControlsTests/testAvatarItemHasVisibleRoundedFallbackBeforeAsyncImageArrives;xabberChatPerformanceUITests/ChatNativeBackUITests/testChevronOnlyBackMeetsHitTargetAndSupportsTapAndSuccessfulEdgeSwipe
V12|source-candidate|xabberTests/ChatNavigationCancellationTests/testScheduledDisappearanceReappearanceRemainsRollbackAfterInteractionEnds
V13|source-candidate|xabberTests/ChatViewportReadBoundaryTests/testPendingFlushWaitsForStructurallyVisiblePresentationReceipt
V14|source-candidate|xabberTests/ChatViewportReadBoundaryTests/testBottommostVisibleIncomingAdvancesBoundary;xabberTests/ChatViewportReadBoundaryTests/testBackwardScrollingDoesNotRegressBoundary
V15|source-candidate|xabberTests/ChatViewportReadBoundaryTests/testViewportReadBoundaryRejectsSliverUntilTargetIsMeaningfullyVisible
V16|source-candidate|xabberTests/ChatVirtualTimelineEngineTests/testThreeHundredSixtyThreeLoadedRowsStayResidentWithoutEviction;xabberChatPerformanceUITests/ChatPerformanceUITests/testSmallHistoryOpensWithBoundedFirstFrame;xabberChatPerformanceUITests/ChatPerformanceUITests/testMillionHistoryOpensWithSameBoundedFirstFrame
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
