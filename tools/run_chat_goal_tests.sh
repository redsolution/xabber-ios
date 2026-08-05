#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  tools/run_chat_goal_tests.sh <legacy-phase> <TASK_ID>
  tools/run_chat_goal_tests.sh chat-open-acceptance-hosted
  tools/run_chat_goal_tests.sh chat-open-acceptance-ui

Phases:
  preflight | focused | smoke | build
  deterministic-ui | release-performance | live-read-only | live-mutation
  chat-open-acceptance-hosted | chat-open-acceptance-ui

Required for all phases:
  XABBER_DESTINATION='platform=iOS Simulator,id=<DEDICATED_SIMULATOR_UDID>'

Required for hosted phases; must be unset for UI/live phases:
  TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT=1
  TEST_RUNNER_XABBER_ISOLATED_STORAGE=1

Optional overrides:
  XABBER_XCODE_CACHE_ROOT  Dedicated chat-goal cache root
  XABBER_SCHEME            Default: Debug
USAGE
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
manifest="$script_dir/chat_goal_test_manifest.sh"
acceptance_manifest="$script_dir/chat_open_acceptance_manifest.sh"

chat_goal_parse_simulator_udid() {
  local destination_value="${1:-}"
  local prefix='platform=iOS Simulator,id='
  local candidate
  local uuid_pattern='^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$'

  case "$destination_value" in
    "$prefix"*) candidate=${destination_value#"$prefix"} ;;
    *) return 1 ;;
  esac
  [[ "$destination_value" == "$prefix$candidate" ]] || return 1
  [[ "$candidate" =~ $uuid_pattern ]] || return 1
  printf '%s\n' "$candidate"
}

chat_goal_booted_ios_simulator_uuids_from_inventory() {
  local inventory="${1:-}"
  printf '%s\n' "$inventory" | awk '
    /^-- / {
      in_ios = ($0 ~ /^-- iOS[[:space:]]/)
      next
    }
    in_ios && /\(Booted\)[[:space:]]*$/ {
      for (field = 1; field <= NF; field += 1) {
        candidate = $field
        gsub(/^\(/, "", candidate)
        gsub(/\)$/, "", candidate)
        if (length(candidate) == 36 &&
            candidate ~ /^[[:xdigit:]-]+$/) {
          print toupper(candidate)
        }
      }
    }
  '
}

chat_goal_validate_sole_booted_ios_simulator_inventory() {
  local requested_udid="${1:-}"
  local inventory="${2:-}"
  local normalized_requested
  local booted_uuids
  local booted_count
  local sole_booted

  normalized_requested=$(printf '%s' "$requested_udid" | tr '[:lower:]' '[:upper:]')
  booted_uuids=$(chat_goal_booted_ios_simulator_uuids_from_inventory "$inventory")
  booted_count=$(printf '%s\n' "$booted_uuids" | awk 'NF { count += 1 } END { print count + 0 }')
  [[ "$booted_count" -eq 1 ]] || return 1
  sole_booted=$(printf '%s\n' "$booted_uuids" | awk 'NF { print; exit }')
  [[ "$sole_booted" == "$normalized_requested" ]]
}

chat_goal_require_sole_booted_ios_simulator() {
  local requested_udid="$1"
  local inventory
  if ! inventory=$(xcrun simctl list devices booted); then
    echo "error: unable to inspect Booted Simulator inventory" >&2
    return 1
  fi
  if ! chat_goal_validate_sole_booted_ios_simulator_inventory \
    "$requested_udid" "$inventory"; then
    echo "error: destination UUID must be the sole Booted iOS simulator" >&2
    return 1
  fi
}

chat_goal_is_chat_open_acceptance_phase() {
  case "${1:-}" in
    chat-open-acceptance-hosted|chat-open-acceptance-ui) return 0 ;;
    *) return 1 ;;
  esac
}

chat_test_safety_arguments=(
  -jobs 1
  -parallel-testing-enabled NO
  -collect-test-diagnostics never
)

chat_goal_test_safety_arguments() {
  local argument
  for argument in "${chat_test_safety_arguments[@]:0}"; do
    printf '%s\n' "$argument"
  done
}

chat_goal_acceptance_hosted_selectors() {
  bash "$acceptance_manifest" selectors | awk '/^xabberTests\//'
}

chat_goal_acceptance_ui_selectors() {
  bash "$acceptance_manifest" selectors \
    | awk '/^xabberChatPerformanceUITests\//'
}

if [[ "${CHAT_GOAL_RUNNER_NO_MAIN:-0}" == "1" ]]; then
  return 0 2>/dev/null || exit 0
fi

if [[ ! -f "$manifest" ]]; then
  echo "error: missing manifest $manifest" >&2
  exit 66
fi

# shellcheck source=tools/chat_goal_test_manifest.sh
source "$manifest"

phase="${1:-}"
task_id="${2:-}"

case "$phase" in
  preflight|focused|smoke|build|deterministic-ui|release-performance|live-read-only|live-mutation|chat-open-acceptance-hosted|chat-open-acceptance-ui) ;;
  *)
    echo "error: unsupported phase '$phase'" >&2
    usage >&2
    exit 64
    ;;
esac

if chat_goal_is_chat_open_acceptance_phase "$phase"; then
  if [[ -n "$task_id" ]]; then
    echo "error: chat-open acceptance phases do not accept a smoothness task ID" >&2
    usage >&2
    exit 64
  fi
  if [[ ! -f "$acceptance_manifest" ]]; then
    echo "error: missing acceptance manifest $acceptance_manifest" >&2
    exit 66
  fi
else
  task_is_known=false
  for candidate_task_id in "${CHAT_GOAL_TASK_IDS[@]}"; do
    if [[ "$candidate_task_id" == "$task_id" ]]; then
      task_is_known=true
      break
    fi
  done

  if [[ "$task_is_known" != true ]]; then
    echo "error: unknown task '$task_id'" >&2
    usage >&2
    exit 64
  fi
fi

case "$phase" in
  deterministic-ui|release-performance|live-read-only|live-mutation)
    if [[ "$task_id" != "G20" ]]; then
      echo "error: final integration phase '$phase' belongs only to G20" >&2
      exit 64
    fi
    ;;
esac

if [[ "$CHAT_GOAL_MANIFEST_VERSION" != "1" ]]; then
  echo "error: unsupported manifest version '$CHAT_GOAL_MANIFEST_VERSION'" >&2
  exit 65
fi

if [[ "${#CHAT_GOAL_TASK_IDS[@]}" -ne 24 ]]; then
  echo "error: manifest must contain exactly 24 task IDs" >&2
  exit 65
fi

validate_selector_list() {
  local label="$1"
  local selectors="$2"
  local required_prefix="${3:-xabberTests/}"
  local selector_count=0
  local selector

  while IFS= read -r selector; do
    [[ -z "$selector" ]] && continue
    if [[ "$selector" != "$required_prefix"* ]]; then
      echo "error: $label contains invalid selector '$selector'" >&2
      exit 65
    fi
    selector_count=$((selector_count + 1))
  done <<< "$selectors"

  if [[ "$selector_count" -eq 0 ]]; then
    echo "error: $label has no selectors" >&2
    exit 65
  fi
}

for candidate_task_id in "${CHAT_GOAL_TASK_IDS[@]}"; do
  validate_selector_list "$candidate_task_id preflight" "$(chat_goal_preflight_selectors "$candidate_task_id")"
  validate_selector_list "$candidate_task_id focused" "$(chat_goal_focused_selectors "$candidate_task_id")"
done
CHAT_GOAL_SMOKE="$(chat_goal_smoke_selectors)"
validate_selector_list "smoke" "$CHAT_GOAL_SMOKE"

for known_red_selector in "${CHAT_GOAL_KNOWN_RED_SELECTORS[@]-}"; do
  [[ -z "$known_red_selector" ]] && continue
  known_red_owner="$(chat_goal_known_red_owner "$known_red_selector")"
  known_red_patterns="$(chat_goal_known_red_patterns "$known_red_selector")"
  if [[ -z "$known_red_owner" || -z "$known_red_patterns" ]]; then
    echo "error: incomplete known-red ledger entry '$known_red_selector'" >&2
    exit 65
  fi
done

cache_root="${XABBER_XCODE_CACHE_ROOT:-$HOME/Library/Caches/XabberCodex/xabber-chat-performance-goal}"
scheme="${XABBER_SCHEME:-Debug}"
destination="${XABBER_DESTINATION:-}"
fixture_bundle_identifier="xabber.ios.codex-chat-performance"
fixture_push_extension_bundle_identifier="xabber.ios.codex-chat-performance.xabber-push-extension"
head_commit="$(git -C "$repo_root" rev-parse HEAD)"

if ! simulator_udid=$(chat_goal_parse_simulator_udid "$destination"); then
  echo "error: XABBER_DESTINATION must be exactly 'platform=iOS Simulator,id=<UUID>'" >&2
  exit 64
fi
if ! chat_goal_require_sole_booted_ios_simulator "$simulator_udid"; then
  exit 64
fi

case "$phase" in
  preflight|focused|smoke|chat-open-acceptance-hosted)
  if [[ "${TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT:-}" != "1" ||
        "${TEST_RUNNER_XABBER_ISOLATED_STORAGE:-}" != "1" ]]; then
    echo "error: hosted tests require both isolation flags set to 1" >&2
    exit 64
  fi
  ;;
  deterministic-ui|release-performance|live-read-only|live-mutation|chat-open-acceptance-ui)
    if [[ -n "${TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT:-}" ||
          -n "${TEST_RUNNER_XABBER_ISOLATED_STORAGE:-}" ]]; then
      echo "error: $phase must run with hosted-test isolation variables unset" >&2
      exit 64
    fi
    ;;
esac

export XABBER_XCODE_CACHE_ROOT="$cache_root"
export XABBER_SCHEME="$scheme"
export XABBER_DESTINATION="$destination"

echo "chat goal test runner"
echo "  manifest version: $CHAT_GOAL_MANIFEST_VERSION"
if chat_goal_is_chat_open_acceptance_phase "$phase"; then
  echo "  acceptance manifest version: $(bash "$acceptance_manifest" version)"
fi
echo "  task: ${task_id:-chat-open-acceptance}"
echo "  phase: $phase"
echo "  HEAD: $head_commit"
echo "  simulator UDID: $simulator_udid"
echo "  cache root: $cache_root"
echo "  scheme: $scheme"

print_selectors() {
  local title="$1"
  local selectors="$2"
  local selector
  echo "  $title:"
  while IFS= read -r selector; do
    [[ -z "$selector" ]] && continue
    echo "    $selector"
  done <<< "$selectors"
}

run_test_selectors() {
  local selectors="$1"
  local include_known_red_skips="$2"
  local -a arguments=("${chat_test_safety_arguments[@]}")
  local selector

  while IFS= read -r selector; do
    [[ -z "$selector" ]] && continue
    arguments+=("-only-testing:$selector")
  done <<< "$selectors"

  if [[ "$include_known_red_skips" == true ]]; then
    for selector in "${CHAT_GOAL_KNOWN_RED_SELECTORS[@]-}"; do
      [[ -z "$selector" ]] && continue
      arguments+=("-skip-testing:$selector")
    done
  fi

  "$script_dir/xcodebuild_cached.sh" test "${arguments[@]}"
}

run_ui_test_selectors() {
  local selectors="$1"
  local -a arguments=()
  local argument
  local selector

  while IFS= read -r argument; do
    [[ -z "$argument" ]] && continue
    arguments+=("$argument")
  done <<< "$(chat_goal_test_safety_arguments)"

  while IFS= read -r selector; do
    [[ -z "$selector" ]] && continue
    arguments+=("-only-testing:$selector")
  done <<< "$selectors"

  env \
    -u TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT \
    -u TEST_RUNNER_XABBER_ISOLATED_STORAGE \
    -u XABBER_CHAT_LIVE_QA_MODE \
    XABBER_SCHEME="Chat Performance UI Tests" \
    "$script_dir/xcodebuild_cached.sh" test \
      "${arguments[@]}" \
      "XABBER_APP_BUNDLE_IDENTIFIER=$fixture_bundle_identifier" \
      "XABBER_PUSH_EXTENSION_BUNDLE_IDENTIFIER=$fixture_push_extension_bundle_identifier"
}

run_known_red_ledger() {
  local temporary_directory
  temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/xabber-chat-known-red.XXXXXX")"
  local selector owner pattern log_file status

  for selector in "${CHAT_GOAL_KNOWN_RED_SELECTORS[@]-}"; do
    [[ -z "$selector" ]] && continue
    owner="$(chat_goal_known_red_owner "$selector")"
    log_file="$temporary_directory/known-red.log"
    echo "  known-red: $selector (owner/sunset $owner)"

    set +e
    "$script_dir/xcodebuild_cached.sh" test \
      "${chat_test_safety_arguments[@]}" \
      "-only-testing:$selector" >"$log_file" 2>&1
    status=$?
    set -e

    if [[ "$status" -eq 0 ]]; then
      echo "error: known-red unexpectedly passed; remove or update its ledger entry" >&2
      rm -rf "$temporary_directory"
      exit 1
    fi

    while IFS= read -r pattern; do
      [[ -z "$pattern" ]] && continue
      if ! grep -Fq "$pattern" "$log_file"; then
        echo "error: known-red signature changed; missing pattern '$pattern'" >&2
        tail -80 "$log_file" >&2
        rm -rf "$temporary_directory"
        exit 1
      fi
    done <<< "$(chat_goal_known_red_patterns "$selector")"

    echo "    confirmed expected failure signature"
  done

  rm -rf "$temporary_directory"
}

case "$phase" in
  preflight)
    print_selectors "known-red selectors" "$(printf '%s\n' "${CHAT_GOAL_KNOWN_RED_SELECTORS[@]-}")"
    run_known_red_ledger
    selectors="$(chat_goal_preflight_selectors "$task_id")"
    print_selectors "green selectors" "$selectors"
    run_test_selectors "$selectors" true
    ;;
  focused)
    selectors="$(chat_goal_focused_selectors "$task_id")"
    print_selectors "selectors" "$selectors"
    run_test_selectors "$selectors" false
    ;;
  smoke)
    print_selectors "selectors" "$CHAT_GOAL_SMOKE"
    print_selectors "exact skips" "$(printf '%s\n' "${CHAT_GOAL_KNOWN_RED_SELECTORS[@]-}")"
    run_test_selectors "$CHAT_GOAL_SMOKE" true
    ;;
  build)
    echo "  selectors: none (simulator build)"
    "$script_dir/xcodebuild_cached.sh" build
    ;;
  deterministic-ui)
    echo "  selectors: xabberChatPerformanceUITests/ChatPerformanceUITests"
    env \
      -u TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT \
      -u TEST_RUNNER_XABBER_ISOLATED_STORAGE \
      -u XABBER_CHAT_LIVE_QA_MODE \
      XABBER_SCHEME="Chat Performance UI Tests" \
      "$script_dir/xcodebuild_cached.sh" test \
        "${chat_test_safety_arguments[@]}" \
        -only-testing:xabberChatPerformanceUITests/ChatPerformanceUITests \
        "XABBER_APP_BUNDLE_IDENTIFIER=$fixture_bundle_identifier" \
        "XABBER_PUSH_EXTENSION_BUNDLE_IDENTIFIER=$fixture_push_extension_bundle_identifier"
    ;;
  chat-open-acceptance-hosted)
    bash "$acceptance_manifest" validate
    selectors="$(chat_goal_acceptance_hosted_selectors)"
    validate_selector_list "chat-open acceptance hosted" "$selectors"
    print_selectors "selectors" "$selectors"
    run_test_selectors "$selectors" false
    ;;
  chat-open-acceptance-ui)
    bash "$acceptance_manifest" validate
    selectors="$(chat_goal_acceptance_ui_selectors)"
    validate_selector_list \
      "chat-open acceptance UI" \
      "$selectors" \
      "xabberChatPerformanceUITests/"
    print_selectors "selectors" "$selectors"
    run_ui_test_selectors "$selectors"
    ;;
  release-performance)
    "$script_dir/run_chat_release_performance.sh" "$task_id"
    ;;
  live-read-only)
    XABBER_CHAT_LIVE_QA_MODE=read-only \
      "$script_dir/run_chat_live_qa.sh" read-only
    ;;
  live-mutation)
    XABBER_CHAT_LIVE_QA_MODE=mutation \
      "$script_dir/run_chat_live_qa.sh" mutation
    ;;
esac

echo "chat goal test runner result: success task=${task_id:-chat-open-acceptance} phase=$phase"
