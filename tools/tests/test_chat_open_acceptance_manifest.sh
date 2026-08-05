#!/usr/bin/env bash

set -eu

test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$test_dir/../.." && pwd)
manifest="$repo_root/tools/chat_open_acceptance_manifest.sh"

bash -n "$manifest"
[ "$(bash "$manifest" version)" = "2026-08-03.4" ] || {
  printf 'unexpected acceptance manifest version\n' >&2
  exit 1
}
validation=$(bash "$manifest" validate)
case "$validation" in
  *"rows=95"*"unique_ids=95"*"selector_references=218"*"unique_selectors=205"*"source_lock_pending=0"*"validation=pass"*) ;;
  *)
    printf 'unexpected valid-manifest summary: %s\n' "$validation" >&2
    exit 1
    ;;
esac

CHAT_OPEN_ACCEPTANCE_MANIFEST_NO_MAIN=1 . "$manifest"
valid_rows=$(chat_open_acceptance_rows)

p14_owner_delta_selector='xabberTests/ChatPerformanceLabTests/testP14ReadReceiptStableRowStoreChangePreservesCommittedAnchoredFrameWithoutSecondDatasourceApply'
authority_activation_selector='xabberTests/ChatTimelineSessionTests/testStructuralPublishBetweenAuthoritativeCaptureAndObservationInstallRejectsOldInitialBatch'
resident_delivery_selector='xabberTests/ChatTimelineSessionTests/testSupersededResidentDeliveryPreservesIndependentLatestAndUnreadMetadata'
production_edit_selector='xabberTests/ChatTimelineSessionTests/testProductionEditPublishesEditedBodyThroughRealmTimelineAndDisplayMapping'
detached_layout_selector='xabberTests/RootBottomBarInsetPolicyTests/testDetachedApplyDoesNotForceLayoutOrMutateInsetsOrOffset'
attached_layout_selector='xabberTests/RootBottomBarInsetPolicyTests/testApplyAfterWindowAttachmentCatchesUpAndPreservesAwayFromBottomOffset'
bottom_bar_integration_selector='xabberTests/RootBottomBarIntegrationTests/testEveryTableOwnerKeepsBottomClearanceAndPreservesAwayFromBottomOffset'
calls_detached_snapshot_selector='xabberTests/CallsListCoordinatorTests/testDetachedDatasourceApplyCommitsOnlyLatestSnapshotBeforeFirstFrame'
calls_attached_diff_selector='xabberTests/CallsListCoordinatorTests/testAttachedDatasourceApplyPolicyKeepsIncrementalDiffs'
native_back_selector='xabberChatPerformanceUITests/ChatNativeBackUITests/testChevronOnlyBackMeetsHitTargetAndSupportsTapAndSuccessfulEdgeSwipe'

p14_row=$(printf '%s\n' "$valid_rows" | awk -F '|' '$1 == "P14" { print $3 }')
v06_row=$(printf '%s\n' "$valid_rows" | awk -F '|' '$1 == "V06" { print $3 }')
all_selectors=$(bash "$manifest" selectors)

case ";$p14_row;" in
  *";$p14_owner_delta_selector;"*) ;;
  *)
    printf 'P14 does not include the owner-delta regression selector\n' >&2
    exit 1
    ;;
esac
case ";$v06_row;" in
  *";$authority_activation_selector;"*) ;;
  *)
    printf 'V06 does not include the observation-activation authority race selector\n' >&2
    exit 1
    ;;
esac
case ";$v06_row;" in
  *";$resident_delivery_selector;"*) ;;
  *)
    printf 'V06 does not include stale resident-delivery provenance coverage\n' >&2
    exit 1
    ;;
esac
case ";$v06_row;" in
  *";$production_edit_selector;"*) ;;
  *)
    printf 'V06 does not include managed resident-baseline thread-safety coverage\n' >&2
    exit 1
    ;;
esac
for p14_layout_selector in \
  "$detached_layout_selector" \
  "$attached_layout_selector" \
  "$bottom_bar_integration_selector" \
  "$calls_detached_snapshot_selector" \
  "$calls_attached_diff_selector"; do
  case ";$p14_row;" in
    *";$p14_layout_selector;"*) ;;
    *)
      printf 'P14 does not include pre-window layout coverage: %s\n' "$p14_layout_selector" >&2
      exit 1
      ;;
  esac
done
for required_selector in \
  "$p14_owner_delta_selector" \
  "$authority_activation_selector" \
  "$resident_delivery_selector" \
  "$production_edit_selector" \
  "$detached_layout_selector" \
  "$attached_layout_selector" \
  "$bottom_bar_integration_selector" \
  "$calls_detached_snapshot_selector" \
  "$calls_attached_diff_selector" \
  "$native_back_selector"; do
  if ! printf '%s\n' "$all_selectors" | grep -Fqx "$required_selector"; then
    printf 'acceptance selector set is missing %s\n' "$required_selector" >&2
    exit 1
  fi
done

chat_open_acceptance_rows() {
  printf '%s\n' "$valid_rows"
  printf '%s\n' \
    'N01|source-candidate|xabberTests/ChatFirstFrameLocalHistoryRegressionTests/testDefaultOpenUsesLatestFirstFrame'
}
if chat_open_acceptance_validate >/dev/null 2>&1; then
  printf 'validator accepted a duplicate ID with a valid XCTest body\n' >&2
  exit 1
fi

chat_open_acceptance_rows() {
  printf '%s\n' "$valid_rows" | sed \
    's#xabberTests/ChatInitialPositionPolicyTests/testBlankSyncUnreadAfterIdOpensBottomWithoutLastReadFallback#xabberTests/DefinitelyMissingTests/testDefinitelyMissing#'
}
if chat_open_acceptance_validate >/dev/null 2>&1; then
  printf 'validator accepted a missing Class/testMethod\n' >&2
  exit 1
fi

chat_open_acceptance_rows() {
  printf '%s\n' "$valid_rows" | sed \
    's#N02|source-candidate|xabberTests/ChatFirstFrameLocalHistoryRegressionTests/testZeroServerUnreadWithUnreadAfterIdUsesLatestFirstFrame#N02|source-candidate|xabberTests/ChatFirstFrameLocalHistoryRegressionTests/testZeroServerUnreadWithUnreadAfterIdUsesLatestFirstFrame;xabberTests/ChatFirstFrameLocalHistoryRegressionTests/testZeroServerUnreadWithUnreadAfterIdUsesLatestFirstFrame#'
}
if chat_open_acceptance_validate >/dev/null 2>&1; then
  printf 'validator accepted a duplicated selector within one row\n' >&2
  exit 1
fi

printf 'chat-open acceptance manifest offline validation tests passed\n'
