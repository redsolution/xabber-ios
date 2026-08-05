#!/usr/bin/env bash

set -eu

test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$test_dir/../.." && pwd)
runner="$repo_root/tools/run_chat_goal_tests.sh"
acceptance_manifest="$repo_root/tools/chat_open_acceptance_manifest.sh"

CHAT_GOAL_RUNNER_NO_MAIN=1 . "$runner"

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

if grep -Fq 'C302' "$runner"; then
  fail 'runner contains the retired hard-coded simulator UUID fragment'
fi

expected_udid='12345678-1234-4ABC-8DEF-1234567890AB'
parsed_udid=$(chat_goal_parse_simulator_udid \
  "platform=iOS Simulator,id=$expected_udid")
[ "$parsed_udid" = "$expected_udid" ] || fail 'explicit UUID destination was not preserved'

for invalid_destination in \
  'platform=iOS Simulator,id=booted' \
  'platform=iOS Simulator,name=iPhone 16 Pro' \
  'platform=iOS Simulator,id=1234' \
  "platform=iOS Simulator,id=$expected_udid,OS=26.0" \
  "platform=iOS Simulator,id=$expected_udid,arch=arm64"; do
  if chat_goal_parse_simulator_udid "$invalid_destination" >/dev/null 2>&1; then
    fail "accepted non-closed simulator destination: $invalid_destination"
  fi
done

sole_ios_inventory=$(printf '%s\n' \
  '== Devices ==' \
  '-- iOS 26.0 --' \
  "    Locked iPhone ($expected_udid) (Booted)" \
  '-- watchOS 26.0 --' \
  '    Watch (AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE) (Booted)')
chat_goal_validate_sole_booted_ios_simulator_inventory \
  "$expected_udid" "$sole_ios_inventory" \
  || fail 'rejected the sole requested Booted iOS simulator'

second_udid='87654321-4321-4CBA-8FED-BA0987654321'
two_ios_inventory=$(printf '%s\n' \
  '== Devices ==' \
  '-- iOS 26.0 --' \
  "    Locked iPhone ($expected_udid) (Booted)" \
  "    Other iPhone ($second_udid) (Booted)")
if chat_goal_validate_sole_booted_ios_simulator_inventory \
  "$expected_udid" "$two_ios_inventory" >/dev/null 2>&1; then
  fail 'accepted two Booted iOS simulators'
fi
if chat_goal_validate_sole_booted_ios_simulator_inventory \
  "$expected_udid" "$(printf '%s\n' '== Devices ==' '-- iOS 26.0 --' "    Other iPhone ($second_udid) (Booted)")" \
  >/dev/null 2>&1; then
  fail 'accepted a different sole Booted iOS simulator'
fi
if chat_goal_validate_sole_booted_ios_simulator_inventory \
  "$expected_udid" "$(printf '%s\n' '== Devices ==' '-- iOS 26.0 --')" \
  >/dev/null 2>&1; then
  fail 'accepted an inventory without a Booted iOS simulator'
fi

chat_goal_is_chat_open_acceptance_phase chat-open-acceptance-hosted \
  || fail 'hosted acceptance phase is not registered'
chat_goal_is_chat_open_acceptance_phase chat-open-acceptance-ui \
  || fail 'UI acceptance phase is not registered'
if chat_goal_is_chat_open_acceptance_phase focused; then
  fail 'legacy focused phase was misclassified as chat-open acceptance'
fi

expected_safety_arguments=$(printf '%s\n' \
  '-jobs' \
  '1' \
  '-parallel-testing-enabled' \
  'NO' \
  '-collect-test-diagnostics' \
  'never')
[ "$(chat_goal_test_safety_arguments)" = "$expected_safety_arguments" ] \
  || fail 'serialized safety arguments changed'

manifest_selectors=$(bash "$acceptance_manifest" selectors)
expected_hosted=$(printf '%s\n' "$manifest_selectors" | awk '/^xabberTests\//')
expected_ui=$(printf '%s\n' "$manifest_selectors" | awk '/^xabberChatPerformanceUITests\//')
actual_hosted=$(chat_goal_acceptance_hosted_selectors)
actual_ui=$(chat_goal_acceptance_ui_selectors)

[ "$actual_hosted" = "$expected_hosted" ] \
  || fail 'hosted acceptance selector plan differs from the 95-row manifest'
[ "$actual_ui" = "$expected_ui" ] \
  || fail 'UI acceptance selector plan differs from the 95-row manifest'
[ "$(printf '%s\n' "$actual_hosted" | awk 'NF { count += 1 } END { print count + 0 }')" -eq 179 ] \
  || fail 'hosted acceptance selector count is not 179'
[ "$(printf '%s\n' "$actual_ui" | awk 'NF { count += 1 } END { print count + 0 }')" -eq 26 ] \
  || fail 'UI acceptance selector count is not 26'

for selector in \
  'xabberTests/ChatPerformanceLabTests/testP14ReadReceiptStableRowStoreChangePreservesCommittedAnchoredFrameWithoutSecondDatasourceApply' \
  'xabberTests/ChatTimelineSessionTests/testStructuralPublishBetweenAuthoritativeCaptureAndObservationInstallRejectsOldInitialBatch' \
  'xabberTests/ChatTimelineSessionTests/testSupersededResidentDeliveryPreservesIndependentLatestAndUnreadMetadata' \
  'xabberTests/ChatTimelineSessionTests/testProductionEditPublishesEditedBodyThroughRealmTimelineAndDisplayMapping' \
  'xabberTests/RootBottomBarInsetPolicyTests/testDetachedApplyDoesNotForceLayoutOrMutateInsetsOrOffset' \
  'xabberTests/RootBottomBarInsetPolicyTests/testApplyAfterWindowAttachmentCatchesUpAndPreservesAwayFromBottomOffset' \
  'xabberTests/RootBottomBarIntegrationTests/testEveryTableOwnerKeepsBottomClearanceAndPreservesAwayFromBottomOffset'; do
  printf '%s\n' "$actual_hosted" | grep -Fqx "$selector" \
    || fail "hosted acceptance plan is missing $selector"
done
printf '%s\n' "$actual_ui" | grep -Fqx \
  'xabberChatPerformanceUITests/ChatNativeBackUITests/testChevronOnlyBackMeetsHitTargetAndSupportsTapAndSuccessfulEdgeSwipe' \
  || fail 'UI acceptance plan is missing native Back coverage'

printf 'chat goal runner offline contract tests passed\n'
