#!/usr/bin/env bash

set -euo pipefail

mode="${1:-}"
case "$mode" in
  read-only|mutation) ;;
  *)
    echo "error: expected read-only or mutation" >&2
    exit 64
    ;;
esac

if [[ "${XABBER_CHAT_LIVE_QA_MODE:-}" != "$mode" ]]; then
  echo "error: live mode acknowledgement mismatch" >&2
  exit 64
fi
if [[ -n "${TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT:-}" ||
      -n "${TEST_RUNNER_XABBER_ISOLATED_STORAGE:-}" ||
      -n "${XABBER_CHAT_PERFORMANCE_UI_TEST:-}" ]]; then
  echo "error: live QA must not inherit hosted or deterministic fixture flags" >&2
  exit 64
fi

while IFS='=' read -r key _; do
  normalized="$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')"
  case "$normalized" in
    *password*|*passwd*|*credential*|*secret*|*private_key*|*access_token*|*refresh_token*)
      echo "error: forbidden secret transport in environment key '$key'" >&2
      exit 64
      ;;
  esac
done < <(env)

report="${XABBER_LIVE_QA_REPORT:-}"
if [[ -z "$report" || ! -f "$report" ]]; then
  echo "error: XABBER_LIVE_QA_REPORT must point to a completed, manually captured report" >&2
  echo "error: authenticate by manual UI entry or an approved out-of-process provider; never pass credentials to this command" >&2
  exit 69
fi

if ! grep -Fq "mode: $mode" "$report" ||
   ! grep -Fq "hosted_flags_unset: true" "$report" ||
   ! grep -Fq "credentials_transport: manual-or-protected-provider" "$report" ||
   ! grep -Fq "authorized_dialog_only: true" "$report" ||
   ! grep -Fq "foreign_mutations: 0" "$report" ||
   ! grep -Fq "logout_reset_delete_account: false" "$report" ||
   ! grep -Fq "result: pass" "$report"; then
  echo "error: live QA report is incomplete or does not match mode $mode" >&2
  exit 1
fi

if [[ "$mode" == read-only ]]; then
  if ! grep -Fq "search_query: test" "$report" ||
     ! grep -Fq "exact_search_target_first_frame: pass" "$report" ||
     ! grep -Fq "bidirectional_paging: pass" "$report" ||
     ! grep -Fq "media_rendering: pass" "$report" ||
     ! grep -Fq "rotation: pass" "$report" ||
     ! grep -Fq "dynamic_type_largest: pass" "$report" ||
     ! grep -Fq "background_foreground: pass" "$report" ||
     ! grep -Fq "network_throttling_recovery: simulator-unsupported" "$report" ||
     ! grep -Fq "deterministic_network_recovery: pass" "$report" ||
     ! grep -Fq "network_recovery_tier: deterministic-simulator" "$report" ||
     ! grep -Fq "read_or_mam_side_effects:" "$report"; then
    echo "error: read-only report does not prove the required live matrix" >&2
    exit 1
  fi
else
  if ! grep -Eq '^run_prefix: chat-perf-qa-[A-Za-z0-9._-]+-$' "$report" ||
     ! grep -Fq "created_run_owned_ids: [" "$report" ||
     ! grep -Fq "optimistic_send_edit_delete: pass" "$report" ||
     ! grep -Fq "media_rendering: pass" "$report" ||
     ! grep -Fq "deleted_only_run_owned_ids: true" "$report" ||
     ! grep -Fq "remaining_run_owned_ids: []" "$report" ||
     ! grep -Fq "server_delete_effects:" "$report" ||
     ! grep -Fq "mam_tombstone_effects:" "$report" ||
     ! grep -Fq "read_marker_effects:" "$report" ||
     ! grep -Fq "read_or_mam_side_effects_recorded: true" "$report"; then
    echo "error: mutation report does not prove run ownership and cleanup" >&2
    exit 1
  fi
fi

echo "live chat QA report accepted mode=$mode report=$report"
