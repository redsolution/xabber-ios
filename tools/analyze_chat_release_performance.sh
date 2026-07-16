#!/usr/bin/env bash

set -euo pipefail

artifact_root="${1:-}"
if [[ -z "$artifact_root" || ! -d "$artifact_root" ]]; then
  echo "error: trace artifact directory is required" >&2
  exit 64
fi

supported=(time-profiler-small time-profiler-million allocations-million)
for slug in "${supported[@]}"; do
  toc="$artifact_root/$slug-toc.xml"
  if [[ ! -s "$toc" ]]; then
    echo "error: missing trace table-of-contents $toc" >&2
    exit 66
  fi
  if ! grep -Fq "xabber" "$toc"; then
    echo "error: $slug trace does not contain the app process" >&2
    exit 1
  fi
  if grep -Eqi "crash|hang detected|recording failed" "$toc"; then
    echo "error: $slug trace contains a terminal failure marker" >&2
    exit 1
  fi
done

animation_status="captured"
if [[ -f "$artifact_root/animation-hitches-simulator-unavailable.txt" ]]; then
  animation_status="simulator-unsupported"
elif [[ ! -s "$artifact_root/animation-hitches-million-toc.xml" ]] ||
     ! grep -Fq "xabber" "$artifact_root/animation-hitches-million-toc.xml"; then
  echo "error: Animation Hitches has neither a valid trace nor an explicit simulator limitation" >&2
  exit 1
fi

network_status="captured"
if [[ -f "$artifact_root/network-simulator-unavailable.txt" ]]; then
  network_status="simulator-unsupported"
elif [[ ! -s "$artifact_root/network-million-toc.xml" ]] ||
     ! grep -Fq "xabber" "$artifact_root/network-million-toc.xml"; then
  echo "error: Network has neither a valid trace nor an explicit simulator limitation" >&2
  exit 1
elif grep -Eqi "crash|hang detected|recording failed" "$artifact_root/network-million-toc.xml"; then
  echo "error: Network trace contains a terminal failure marker" >&2
  exit 1
fi

extract_report() {
  local scale="$1"
  local source="$artifact_root/time-profiler-$scale-stdout.log"
  local destination="$artifact_root/release-probe-$scale.json"
  local line
  if [[ ! -s "$source" ]]; then
    echo "error: missing Release probe stdout for $scale" >&2
    exit 66
  fi
  line="$(grep '^CHAT_PERF_RELEASE_REPORT ' "$source" | tail -1 || true)"
  if [[ -z "$line" ]]; then
    echo "error: missing machine-readable Release report for $scale" >&2
    exit 1
  fi
  printf '%s\n' "${line#CHAT_PERF_RELEASE_REPORT }" > "$destination"
  jq -e . "$destination" >/dev/null
}

extract_report small
extract_report million

for scale in small million; do
  report="$artifact_root/release-probe-$scale.json"
  if [[ "$(jq -r '.cycleCount' "$report")" != "20" ]] ||
     [[ "$(jq -r '.deterministicBudgetsPass' "$report")" != "true" ]]; then
    echo "error: deterministic Release probe failed for $scale" >&2
    exit 1
  fi
  if [[ "$(jq -r '.actualOperationBudgetsPass' "$report")" != "true" ]] ||
     [[ "$(jq -r '[.actualDatasourceApplies,.actualStructuralInserts,.actualStructuralDeletes,.actualStructuralMoves,.actualReloads] | join("/")' "$report")" != "42/42/42/0/0" ]]; then
    echo "error: actual Release datasource operation budget failed for $scale" >&2
    exit 1
  fi
  if [[ "$(jq -r '.residentMessageCount' "$report")" -gt 360 ]]; then
    echo "error: resident message bound failed for $scale" >&2
    exit 1
  fi
  if [[ "$(jq -r '[.mediaDownloads,.mediaDecodes,.mediaVisibleCacheHits] | join("/")' "$report")" != "1/1/1" ]]; then
    echo "error: media prefetch-to-visible reuse failed for $scale" >&2
    exit 1
  fi
  if grep -Eqi 'password|credential|secret|access.?token|refresh.?token|message.?id|archive.?id|jid|body|https?://' "$report"; then
    echo "error: private payload key leaked into $scale report" >&2
    exit 1
  fi
done

for scale in small million; do
  trace="$artifact_root/time-profiler-$scale.trace"
  hangs="$artifact_root/time-profiler-$scale-potential-hangs.xml"
  xcrun xctrace export \
    --input "$trace" \
    --xpath '/trace-toc/run[@number="1"]/data/table[@schema="potential-hangs"]' \
    --output "$hangs" >/dev/null
done

small_ms="$(jq -r '.firstStableMilliseconds' "$artifact_root/release-probe-small.json")"
million_ms="$(jq -r '.firstStableMilliseconds' "$artifact_root/release-probe-million.json")"
open_delta_ms="$(jq -n --argjson small "$small_ms" --argjson million "$million_ms" '($million - $small) | if . < 0 then -. else . end')"
open_delta_percent="$(jq -n --argjson delta "$open_delta_ms" --argjson small "$small_ms" 'if $small > 0 then ($delta / $small * 100) else 999 end')"
open_trend_pass="$(jq -n --argjson ms "$open_delta_ms" --argjson percent "$open_delta_percent" '$ms <= 50 and $percent <= 10')"
small_memory_pass="$(jq -r '.memoryPlateauPass' "$artifact_root/release-probe-small.json")"
million_memory_pass="$(jq -r '.memoryPlateauPass' "$artifact_root/release-probe-million.json")"
small_optimistic_pass="$(jq -r '.optimisticTrendPass' "$artifact_root/release-probe-small.json")"
million_optimistic_pass="$(jq -r '.optimisticTrendPass' "$artifact_root/release-probe-million.json")"

{
  printf '%s\n' '# G20 Release chat performance report'
  printf '%s\n' ''
  printf '%s\n' '- evidence-tier: simulator-trend-non-gating'
  printf '%s\n' '- hardware-frame-gate: not-measured'
  printf '%s\n' '- deterministic-operation-gate: pass'
  printf '%s\n' '- actual-datasource-operations: 42 applies / 42 inserts / 42 deletes / 0 moves / 0 reloads'
  printf '%s\n' "- animation-hitches: $animation_status"
  printf '%s\n' '- time-profiler: captured-small-and-million'
  printf '%s\n' '- allocations: captured-million'
  printf '%s\n' "- network: $network_status"
  printf '%s\n' '- hardware-network-gate: not-measured'
  printf '%s\n' '- potential-hangs-threshold: 250ms (Time Profiler template minimum)'
  printf '%s\n' "- open-small-ms: $small_ms"
  printf '%s\n' "- open-million-ms: $million_ms"
  printf '%s\n' "- open-absolute-delta-ms: $open_delta_ms"
  printf '%s\n' "- open-relative-delta-percent: $open_delta_percent"
  printf '%s\n' "- open-10-percent-and-50ms-trend: $open_trend_pass"
  printf '%s\n' "- memory-plateau-small-trend: $small_memory_pass"
  printf '%s\n' "- memory-plateau-million-trend: $million_memory_pass"
  printf '%s\n' "- optimistic-local-row-small-trend: $small_optimistic_pass"
  printf '%s\n' "- optimistic-local-row-million-trend: $million_optimistic_pass"
  printf '%s\n' '- reference-device-required: iPhone 16 Pro Release, five warmups plus twenty recorded runs'
} > "$artifact_root/report.md"

echo "release trace inventory"
echo "  Time Profiler: captured (small, million)"
echo "  Animation Hitches: $animation_status"
echo "  Allocations: captured (million)"
echo "  Network: $network_status"
echo "  deterministic operation budgets: pass"
echo "  simulator open trend: delta=${open_delta_ms}ms percent=${open_delta_percent}% pass=$open_trend_pass (non-gating)"
echo "  hardware-frame-gate: not-measured"
