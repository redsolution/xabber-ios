#!/usr/bin/env bash

set -eu

test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$test_dir/../.." && pwd)
runner="$repo_root/tools/run_chat_goal_tests.sh"
acceptance_manifest="$repo_root/tools/chat_open_acceptance_manifest.sh"
goal_manifest="$repo_root/tools/chat_goal_test_manifest.sh"

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
[ "$(printf '%s\n' "$actual_hosted" | awk 'NF { count += 1 } END { print count + 0 }')" -gt 0 ] \
  || fail 'hosted acceptance selector plan is empty'
[ "$(printf '%s\n' "$actual_ui" | awk 'NF { count += 1 } END { print count + 0 }')" -eq 3 ] \
  || fail 'UI acceptance selector plan must contain exactly three current smoke tests'
if printf '%s\n' "$actual_ui" | grep -Fq \
  'xabberChatPerformanceUITests/ChatPerformanceUITests/testChatOpen'; then
  fail 'UI acceptance selector plan still contains retired legacy video routes'
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
  'xabberTests/SensitiveMediaAnalysisServiceTests/' \
  'xabberTests/MessageManagerQueueSynchronizationTests/' \
  'xabberTests/ArchiveCoverageRepositoryTests/'; do
  printf '%s\n' "$actual_hosted" | grep -Fq "$required_suite" \
    || fail "hosted acceptance plan is missing $required_suite"
done

printf '%s\n' "$actual_ui" | grep -Fqx \
  'xabberChatPerformanceUITests/ChatNativeBackUITests/testChevronOnlyBackMeetsHitTargetAndSupportsTapAndSuccessfulEdgeSwipe' \
  || fail 'UI acceptance plan is missing native Back coverage'

deterministic_ui=$(chat_goal_deterministic_ui_selectors)
[ "$(printf '%s\n' "$deterministic_ui" | awk 'NF { count += 1 } END { print count + 0 }')" -eq 6 ] \
  || fail 'deterministic UI plan must contain six current smoke tests'
if printf '%s\n' "$deterministic_ui" | grep -Fq '/testChatOpen'; then
  fail 'deterministic UI plan still contains retired legacy video routes'
fi

# The legacy smoothness phases remain callable, so every emitted XCTest suite
# must still exist after archive/runtime hard cuts delete superseded coverage.
# A syntactically valid selector for a removed class otherwise reaches
# xcodebuild and fails only after the full test bundle has been built.
# shellcheck source=tools/chat_goal_test_manifest.sh
. "$goal_manifest"
all_goal_selectors=$(
  for task_id in "${CHAT_GOAL_TASK_IDS[@]}"; do
    chat_goal_preflight_selectors "$task_id"
    chat_goal_focused_selectors "$task_id"
  done
  chat_goal_smoke_selectors
)

for suite in $(printf '%s\n' "$all_goal_selectors" \
  | awk -F/ '/^xabberTests\// { print $2 }' \
  | sort -u); do
  if ! rg -q "class[[:space:]]+$suite([[:space:]]*:|[[:space:]]*\\{)" \
    "$repo_root/xabberTests" --glob '*.swift'; then
    fail "chat goal selector references missing XCTest suite $suite"
  fi
done

while IFS= read -r selector; do
  [ -z "$selector" ] && continue
  method=$(printf '%s\n' "$selector" | awk -F/ 'NF >= 3 { print $3 }')
  [ -z "$method" ] && continue
  if ! rg -q "func[[:space:]]+$method[[:space:]]*\\(" \
    "$repo_root/xabberTests" --glob '*.swift'; then
    fail "chat goal selector references missing XCTest method $selector"
  fi
done < <(printf '%s\n' "$all_goal_selectors" | sort -u)

printf 'chat goal runner offline contract tests passed\n'
