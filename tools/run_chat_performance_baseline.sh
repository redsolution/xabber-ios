#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  tools/run_chat_performance_baseline.sh prepare <output-directory>
  tools/run_chat_performance_baseline.sh build <output-directory>
  tools/run_chat_performance_baseline.sh capture <output-directory> <scenario> <template>

Supported capture templates:
  Time Profiler
  Animation Hitches
  Allocations

Build overrides:
  XABBER_XCODE_CACHE_ROOT     Dedicated performance cache
  XABBER_SCHEME               Default: Debug (xabber Workspace)
  XABBER_PERF_DESTINATION     Default: generic/platform=iOS

Capture requirements:
  XABBER_PERF_DEVICE          Device name or UDID, used only by xctrace
  XABBER_PERF_PROCESS_NAME    Running app process name
  XABBER_PERF_DURATION        Default: 60s

Report metadata overrides never include a device UDID:
  XABBER_PERF_DEVICE_NAME
  XABBER_PERF_DEVICE_MODEL
  XABBER_PERF_DEVICE_OS
  XABBER_PERF_REFRESH_RATE
USAGE
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
mode="${1:-}"
requested_output_directory="${2:-}"

case "$mode" in
  prepare|build|capture) ;;
  *)
    echo "error: unsupported mode '$mode'" >&2
    usage >&2
    exit 64
    ;;
esac

if [[ -z "$requested_output_directory" ]]; then
  echo "error: output directory is required" >&2
  usage >&2
  exit 64
fi

mkdir -p "$requested_output_directory"
output_directory="$(cd "$requested_output_directory" && pwd)"

head_commit="$(git -C "$repo_root" rev-parse HEAD)"
working_tree_change_count="$(git -C "$repo_root" status --porcelain | wc -l | tr -d ' ')"
xcode_version="$(xcodebuild -version | tr '\n' ' ')"
host_os="$(sw_vers -productVersion) ($(sw_vers -buildVersion))"
device_name="${XABBER_PERF_DEVICE_NAME:-iPhone 16 Pro}"
device_model="${XABBER_PERF_DEVICE_MODEL:-iPhone17,1}"
device_os="${XABBER_PERF_DEVICE_OS:-26.5 (23F77)}"
refresh_rate="${XABBER_PERF_REFRESH_RATE:-120 Hz ProMotion}"

write_metadata() {
  cat >"$output_directory/run-metadata.md" <<METADATA
# Chat performance run metadata

- Commit: \`$head_commit\`
- Working-tree change count: $working_tree_change_count
- Captured at: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
- Xcode: $xcode_version
- Host: macOS $host_os
- App configuration: Release
- Reference device: $device_name
- Model identifier: $device_model
- Device OS: $device_os
- Refresh class: $refresh_rate

The device UDID, account, JID, message body, URL, path, and message identifiers are intentionally excluded.
METADATA

  if [[ ! -f "$output_directory/baseline-report.md" ]]; then
    cat >"$output_directory/baseline-report.md" <<'REPORT'
# Chat performance baseline report

## Run validity

- [ ] Release build and matching dSYM
- [ ] Fixed reference device, OS, thermal state, orientation, text size, and network profile
- [ ] Five warm-up runs discarded
- [ ] Twenty recorded runs per dataset/scenario
- [ ] Operation-count tests green at the same commit
- [ ] Trace artifacts contain no private signpost payloads

## Scenario results

| Scenario | Rows | Local/remote | p50 ms | p95 ms | max stall ms | frame p95 ms | frames >33 ms | hitch ratio | peak resident MB | end resident MB |
|---|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|
| open -> first stable frame | 100 | local | | | | | | | | |
| open -> first stable frame | 10000 | local | | | | | | | | |
| open -> first stable frame | 100000 | local | | | | | | | | |
| open -> first stable frame | 1000000 | local | | | | | | | | |
| search -> centered target | | local | | | | | | | | |
| search -> centered target | | one-page remote | | | | | | | | |
| send -> local row | | local | | | | | | | | |

## Deterministic operation counts

| Scenario | rows | candidates | rich snapshots | glyph measurements | layout hit/miss | reloads | layout flushes | app offset mutations | binds | media req/download/decode | active tasks/timers after teardown |
|---|---:|---:|---:|---:|---|---:|---:|---:|---|---|---|
| open | | | | | | | | | | | |
| page older | | | | | | | | | | | |
| page newer | | | | | | | | | | | |
| new message | | | | | | | | | | | |
| search jump | | | | | | | | | | | |

## Anchor and lifecycle

| Check | Result |
|---|---|
| Maximum prepend/trim/media anchor drift | |
| Resident growth after cycles 5...20 | |
| Tasks/timers return to baseline | |
| Stale callbacks mutate UI | |

## Verdict and regressions

- Budget verdict:
- First meaningful regression:
- Trace links:
- Follow-up task:
REPORT
  fi
}

write_metadata

case "$mode" in
  prepare)
    echo "Prepared baseline report directory: $output_directory"
    ;;
  build)
    export XABBER_XCODE_CACHE_ROOT="${XABBER_XCODE_CACHE_ROOT:-$HOME/Library/Caches/XabberCodex/xabber-chat-performance-release}"
    export XABBER_SCHEME="${XABBER_SCHEME:-Debug (xabber Workspace)}"
    export XABBER_CONFIGURATION=Release
    export XABBER_DESTINATION="${XABBER_PERF_DESTINATION:-generic/platform=iOS}"
    build_arguments=()
    case "$XABBER_DESTINATION" in
      *'iOS Simulator'*)
        build_arguments+=(ONLY_ACTIVE_ARCH=YES)
        ;;
    esac

    echo "Building Release app with the dedicated cache"
    "$script_dir/xcodebuild_cached.sh" build "${build_arguments[@]}" | tee "$output_directory/release-build.log"
    ;;
  capture)
    scenario="${3:-}"
    template="${4:-}"
    device="${XABBER_PERF_DEVICE:-}"
    process_name="${XABBER_PERF_PROCESS_NAME:-}"
    duration="${XABBER_PERF_DURATION:-60s}"

    if [[ -z "$scenario" || -z "$template" || -z "$device" || -z "$process_name" ]]; then
      echo "error: capture requires scenario, template, XABBER_PERF_DEVICE, and XABBER_PERF_PROCESS_NAME" >&2
      exit 64
    fi

    case "$template" in
      'Time Profiler'|'Animation Hitches'|'Allocations') ;;
      *)
        echo "error: unsupported capture template '$template'" >&2
        exit 64
        ;;
    esac

    safe_scenario="$(printf '%s' "$scenario" | tr -cs '[:alnum:]_-' '_')"
    safe_template="$(printf '%s' "$template" | tr '[:upper:] ' '[:lower:]_')"
    trace_path="$output_directory/${safe_scenario}-${safe_template}.trace"

    if [[ -e "$trace_path" ]]; then
      echo "error: refusing to overwrite existing trace $trace_path" >&2
      exit 73
    fi

    echo "Attach to the already-running Release app and perform only scenario '$scenario' for $duration."
    xcrun xctrace record \
      --template "$template" \
      --device "$device" \
      --time-limit "$duration" \
      --output "$trace_path" \
      --attach "$process_name"

    printf '%s\t%s\t%s\n' "$scenario" "$template" "$(basename "$trace_path")" >>"$output_directory/artifacts.tsv"
    echo "Captured trace: $trace_path"
    ;;
esac
