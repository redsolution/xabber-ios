#!/usr/bin/env bash

set -euo pipefail

task_id="${1:-}"
if [[ "$task_id" != "G20" ]]; then
  echo "error: release performance gate belongs only to G20" >&2
  exit 64
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
destination="${XABBER_DESTINATION:-}"
cache_root="${XABBER_XCODE_CACHE_ROOT:-$HOME/Library/Caches/XabberCodex/xabber-chat-performance-goal}"

if [[ "$destination" != *id=* ]]; then
  echo "error: XABBER_DESTINATION must contain an explicit simulator id" >&2
  exit 64
fi
simulator_udid="${destination#*id=}"
simulator_udid="${simulator_udid%%,*}"

if [[ -n "${TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT:-}" ||
      -n "${TEST_RUNNER_XABBER_ISOLATED_STORAGE:-}" ||
      -n "${XABBER_CHAT_LIVE_QA_MODE:-}" ]]; then
  echo "error: release performance gate must not inherit hosted or live mode" >&2
  exit 64
fi

artifact_root="$cache_root/Performance/G20"
mkdir -p "$artifact_root"
rm -rf "$artifact_root/current"
mkdir -p "$artifact_root/current"

export XABBER_XCODE_CACHE_ROOT="$cache_root"
export XABBER_SCHEME="Chat Performance UI Tests"
export XABBER_DESTINATION="$destination"

echo "release chat performance gate"
echo "  simulator UDID: $simulator_udid"
echo "  artifact root: $artifact_root/current"

"$script_dir/xcodebuild_cached.sh" build \
  -configuration Release \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS=CHAT_PERFORMANCE_LAB \
  SWIFT_OPTIMIZATION_LEVEL=-O \
  ONLY_ACTIVE_ARCH=YES \
  ARCHS=arm64

app_path="$cache_root/DerivedData/Build/Products/Release-iphonesimulator/xabber.app"
if [[ ! -d "$app_path" ]]; then
  echo "error: missing Release lab app at $app_path" >&2
  exit 66
fi

xcrun simctl bootstatus "$simulator_udid" -b
xcrun simctl uninstall "$simulator_udid" xabber.ios.codex-hosted-tests >/dev/null 2>&1 || true
xcrun simctl uninstall "$simulator_udid" xabber.ios >/dev/null 2>&1 || true
xcrun simctl install "$simulator_udid" "$app_path"
data_container="$(xcrun simctl get_app_container "$simulator_udid" xabber.ios data)"
release_report_path="$data_container/tmp/chat-performance-release-report.txt"

record_trace() {
  local template="$1"
  local scale="$2"
  local slug="$3"
  local trace="$artifact_root/current/$slug.trace"
  local toc="$artifact_root/current/$slug-toc.xml"
  local recording_log="$artifact_root/current/$slug-recording.log"
  local target_stdout="$artifact_root/current/$slug-stdout.log"
  local status

  rm -rf "$trace"
  rm -f "$release_report_path"
  echo "  recording: $template scale=$scale"
  set +e
  xcrun xctrace record \
    --template "$template" \
    --device "$simulator_udid" \
    --time-limit 30s \
    --output "$trace" \
    --no-prompt \
    --env XABBER_CHAT_PERFORMANCE_UI_TEST=1 \
    --env XABBER_CHAT_PERFORMANCE_RELEASE_PROBE=1 \
    --launch -- "$app_path" --xabber-chat-performance-fixture "$scale" \
    2>&1 | tee "$recording_log"
  status=${PIPESTATUS[0]}
  set -e
  if [[ -s "$release_report_path" ]]; then
    cp "$release_report_path" "$target_stdout"
  fi

  if [[ "$status" -ne 0 ]]; then
    if [[ "$template" == "Animation Hitches" ]] &&
       grep -Fq "Hitches is not supported on this platform" "$recording_log"; then
      echo "simulator-unavailable" > "$artifact_root/current/animation-hitches-simulator-unavailable.txt"
      xcrun xctrace export --input "$trace" --toc --output "$toc"
      return
    fi
    if [[ "$template" == "Network" ]] &&
       grep -Fq "Recording of 'Network Connections' is not supported in the Simulator" "$recording_log"; then
      echo "simulator-unavailable" > "$artifact_root/current/network-simulator-unavailable.txt"
      xcrun xctrace export --input "$trace" --toc --output "$toc"
      return
    fi
    echo "error: $template trace failed with status $status" >&2
    exit "$status"
  fi

  xcrun xctrace export --input "$trace" --toc --output "$toc"
  if ! grep -Fq "xabber" "$toc"; then
    echo "error: $template/$scale trace does not contain the xabber process" >&2
    exit 1
  fi
}

for scale in small million; do
  record_trace "Time Profiler" "$scale" "time-profiler-$scale"
done
record_trace "Animation Hitches" million animation-hitches-million
record_trace "Allocations" million allocations-million
record_trace "Network" million network-million

"$script_dir/analyze_chat_release_performance.sh" "$artifact_root/current"
rm -rf "$artifact_root/current"/*.trace

echo "release chat performance gate result: success"
