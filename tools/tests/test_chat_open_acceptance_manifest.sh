#!/usr/bin/env bash

set -eu

test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$test_dir/../.." && pwd)
manifest="$repo_root/tools/chat_open_acceptance_manifest.sh"

bash -n "$manifest"
[ "$(bash "$manifest" version)" = "2026-08-25.2" ] || {
  printf 'unexpected acceptance manifest version\n' >&2
  exit 1
}

validation=$(bash "$manifest" validate)
case "$validation" in
  *"rows=95"*"unique_ids=95"*"selector_references=129"*"unique_selectors=96"*"source_lock_pending=0"*"validation=pass"*) ;;
  *)
    printf 'unexpected valid-manifest summary: %s\n' "$validation" >&2
    exit 1
    ;;
esac

CHAT_OPEN_ACCEPTANCE_MANIFEST_NO_MAIN=1 . "$manifest"
valid_rows=$(chat_open_acceptance_rows)
all_selectors=$(bash "$manifest" selectors)
actual_ui_selectors=$(printf '%s\n' "$all_selectors" | awk '/^xabberChatPerformanceUITests\//')
expected_ui_selectors=$(cat <<'SELECTORS'
xabberChatPerformanceUITests/ChatNativeBackUITests/testChevronOnlyBackMeetsHitTargetAndSupportsTapAndSuccessfulEdgeSwipe
xabberChatPerformanceUITests/ChatPerformanceUITests/testMillionHistoryOpensWithSameBoundedFirstFrame
xabberChatPerformanceUITests/ChatPerformanceUITests/testSmallHistoryOpensWithBoundedFirstFrame
SELECTORS
)

[ "$actual_ui_selectors" = "$expected_ui_selectors" ] || {
  printf 'acceptance manifest contains an unexpected UI selector set\n' >&2
  exit 1
}
if printf '%s\n' "$all_selectors" | grep -Fq \
  'xabberChatPerformanceUITests/ChatPerformanceUITests/testChatOpen'; then
  printf 'acceptance manifest still contains retired legacy video routes\n' >&2
  exit 1
fi

for required_suite in \
  'xabberTests/ChatVirtualTimelineEngineTests/' \
  'xabberTests/ChatArchiveVirtualTimelineIntegrationTests/' \
  'xabberTests/AccountArchiveEngineTests/' \
  'xabberTests/ArchiveTransportReceiptTests/' \
  'xabberTests/ChatArchiveEngineUIContractTests/' \
  'xabberTests/ClientSynchronizationPaginationTests/' \
  'xabberTests/CanonicalGroupOpenAdmissionCoordinatorTests/' \
  'xabberTests/VCardRequestSingleFlightCoordinatorTests/' \
  'xabberTests/SensitiveMediaAnalysisStartupSchedulerTests/' \
  'xabberTests/SensitiveMediaAnalysisServiceTests/' \
  'xabberTests/MessageManagerQueueSynchronizationTests/' \
  'xabberTests/ArchiveCoverageRepositoryTests/'; do
  if ! printf '%s\n' "$all_selectors" | grep -Fq "$required_suite"; then
    printf 'acceptance selector set is missing focused suite %s\n' "$required_suite" >&2
    exit 1
  fi
done

for required_selector in \
  'xabberTests/MessageManagerQueueSynchronizationTests/testArchiveTerminalRequiresMessageReferenceAndAttachmentDurability' \
  'xabberTests/MessageManagerQueueSynchronizationTests/testArchiveVideoPreviewSchedulingStartsAfterTerminal' \
  'xabberTests/MessageManagerQueueSynchronizationTests/testBlockedEnabledSensitiveAnalysisStartsAfterTerminalAndDoesNotDelayMaterialization' \
  'xabberTests/ArchiveCoverageRepositoryTests/testCommitRequiresPersistedConversationMessagesBeforeCoverageProof' \
  'xabberTests/ChatArchiveEnginePresentationTests/testBenignLocalBoundaryDriftNeverEscalatesToEdgeRetry' \
  'xabberTests/ChatArchiveEnginePresentationTests/testBenignLocalBoundaryRecoveryCannotReenterPagingGatewayOrExposeRetry' \
  'xabberTests/ChatArchiveEnginePresentationTests/testAutomaticHistoryRetryBackoffAccumulatesAcrossActorCyclesAndCapsAtThirtySeconds' \
  'xabberTests/ChatArchiveEnginePresentationTests/testAutomaticHistoryRetryKeepsCumulativeAttemptUntilSemanticRequestTerminates' \
  'xabberTests/ChatArchiveEnginePresentationTests/testHistoryFailurePathsNeverPresentRetryAffordances' \
  'xabberTests/ChatArchiveEngineUIContractTests/testHistoryRecoveryAffordanceTypesAndControllerPlumbingAreAbsent' \
  'xabberTests/ChatArchiveEngineUIContractTests/testTerminalRetryableFailureSchedulesEngineOwnedAutomaticRetry' \
  'xabberChatPerformanceUITests/ChatNativeBackUITests/testChevronOnlyBackMeetsHitTargetAndSupportsTapAndSuccessfulEdgeSwipe'; do
  if ! printf '%s\n' "$all_selectors" | grep -Fqx "$required_selector"; then
    printf 'acceptance selector set is missing %s\n' "$required_selector" >&2
    exit 1
  fi
done

for retired_suite in \
  'ChatFirstLoginChatOpenRegressionTests' \
  'ChatFirstAccountBootstrapRegressionTests' \
  'ChatFirstLoginSkeletonAvatarReadinessRegressionTests' \
  'ChatRemoteMAMPersistenceCoordinatorTests' \
  'ChatAsyncLocalPagingTests' \
  'ChatGapRepairIntegrationTests' \
  'ChatInitialPresentationAtomicityRegressionTests' \
  'ChatLocalHistoryPageProviderWindowingTests' \
  'ChatSearchMAMPagingTests' \
  'ChatSingleFrameLocalOpenTests' \
  'ChatSkeletonLifecycleTests' \
  'ChatTimelineSessionTests'; do
  if printf '%s\n' "$all_selectors" | grep -Fq "/$retired_suite/"; then
    printf 'acceptance selector set still contains retired suite %s\n' "$retired_suite" >&2
    exit 1
  fi
done

chat_open_acceptance_rows() {
  printf '%s\n' "$valid_rows"
  printf '%s\n' \
    'N01|source-candidate|xabberTests/AccountArchiveEngineTests/testPreviousSessionCoverageDoesNotAdmitWithoutCurrentSessionMAMProof'
}
if chat_open_acceptance_validate >/dev/null 2>&1; then
  printf 'validator accepted a duplicate ID with a valid XCTest body\n' >&2
  exit 1
fi

chat_open_acceptance_rows() {
  printf '%s\n' "$valid_rows" | sed \
    's#xabberTests/AccountArchiveEngineTests/testRepeatedReadinessForVerifiedGenerationDoesNotReprobeWindow#xabberTests/DefinitelyMissingTests/testDefinitelyMissing#'
}
if chat_open_acceptance_validate >/dev/null 2>&1; then
  printf 'validator accepted a missing Class/testMethod\n' >&2
  exit 1
fi

chat_open_acceptance_rows() {
  printf '%s\n' "$valid_rows" | sed \
    's#N02|source-candidate|xabberTests/AccountArchiveEngineTests/testRepeatedReadinessForVerifiedGenerationDoesNotReprobeWindow#N02|source-candidate|xabberTests/AccountArchiveEngineTests/testRepeatedReadinessForVerifiedGenerationDoesNotReprobeWindow;xabberTests/AccountArchiveEngineTests/testRepeatedReadinessForVerifiedGenerationDoesNotReprobeWindow#'
}
if chat_open_acceptance_validate >/dev/null 2>&1; then
  printf 'validator accepted a duplicated selector within one row\n' >&2
  exit 1
fi

printf 'chat-open acceptance manifest offline validation tests passed\n'
