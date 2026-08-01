#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: tools/run_chat_goal_tests.sh <phase> <TASK_ID>

Phases:
  preflight | focused | smoke | build
  deterministic-ui | release-performance | live-read-only | live-mutation

Required for test phases:
  XABBER_DESTINATION='platform=iOS Simulator,id=<DEDICATED_SIMULATOR_UDID>'
  TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT=1
  TEST_RUNNER_XABBER_ISOLATED_STORAGE=1

Optional overrides:
  XABBER_XCODE_CACHE_ROOT  Dedicated chat-goal cache root
  XABBER_SCHEME            Default: Debug (xabber Workspace)
USAGE
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
manifest="$script_dir/chat_goal_test_manifest.sh"

if [[ ! -f "$manifest" ]]; then
  echo "error: missing manifest $manifest" >&2
  exit 66
fi

# shellcheck source=tools/chat_goal_test_manifest.sh
source "$manifest"

phase="${1:-}"
task_id="${2:-}"

case "$phase" in
  preflight|focused|smoke|build|deterministic-ui|release-performance|live-read-only|live-mutation) ;;
  *)
    echo "error: unsupported phase '$phase'" >&2
    usage >&2
    exit 64
    ;;
esac

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
  local selector_count=0
  local selector

  while IFS= read -r selector; do
    [[ -z "$selector" ]] && continue
    if [[ "$selector" != xabberTests/* ]]; then
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
scheme="${XABBER_SCHEME:-Debug (xabber Workspace)}"
destination="${XABBER_DESTINATION:-}"
fixture_bundle_identifier="xabber.ios.codex-chat-performance"
fixture_push_extension_bundle_identifier="xabber.ios.codex-chat-performance.xabber-push-extension"
head_commit="$(git -C "$repo_root" rev-parse HEAD)"

if [[ -z "$destination" ]]; then
  echo "error: XABBER_DESTINATION must name the dedicated simulator by id" >&2
  exit 64
fi

case "$destination" in
  *id=*)
    simulator_udid="${destination#*id=}"
    simulator_udid="${simulator_udid%%,*}"
    ;;
  *)
    echo "error: XABBER_DESTINATION must contain an explicit simulator id" >&2
    exit 64
    ;;
esac

case "$phase" in
  preflight|focused|smoke)
  if [[ "${TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT:-}" != "1" ||
        "${TEST_RUNNER_XABBER_ISOLATED_STORAGE:-}" != "1" ]]; then
    echo "error: hosted tests require both isolation flags set to 1" >&2
    exit 64
  fi
  ;;
  deterministic-ui|release-performance|live-read-only|live-mutation)
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
echo "  task: $task_id"
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
  local -a arguments=(-parallel-testing-enabled NO)
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
      -parallel-testing-enabled NO \
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
        -parallel-testing-enabled NO \
        -only-testing:xabberChatPerformanceUITests/ChatPerformanceUITests \
        "XABBER_APP_BUNDLE_IDENTIFIER=$fixture_bundle_identifier" \
        "XABBER_PUSH_EXTENSION_BUNDLE_IDENTIFIER=$fixture_push_extension_bundle_identifier"
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

echo "chat goal test runner result: success task=$task_id phase=$phase"
