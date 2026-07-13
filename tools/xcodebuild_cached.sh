#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  tools/xcodebuild_cached.sh [build|test|resolve|clean-cache] [xcodebuild args...]

Environment overrides:
  XABBER_XCODE_CACHE_ROOT  Default: $HOME/Library/Caches/XabberCodex/xabber-ios-core
  XABBER_WORKSPACE         Default: xabber.xcworkspace
  XABBER_SCHEME            Default: Debug
  XABBER_CONFIGURATION     Optional xcodebuild configuration
  XABBER_DESTINATION       Optional xcodebuild destination

Examples:
  tools/xcodebuild_cached.sh build
  XABBER_DESTINATION='platform=iOS Simulator,name=iPhone 17 Pro,OS=26.0' tools/xcodebuild_cached.sh test
  tools/xcodebuild_cached.sh resolve
  tools/xcodebuild_cached.sh clean-cache
USAGE
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

cache_root="${XABBER_XCODE_CACHE_ROOT:-$HOME/Library/Caches/XabberCodex/xabber-ios-core}"
derived_data="$cache_root/DerivedData"
source_packages="$cache_root/SourcePackages"
package_cache="$cache_root/PackageCache"

workspace="${XABBER_WORKSPACE:-xabber.xcworkspace}"
scheme="${XABBER_SCHEME:-Debug}"
configuration="${XABBER_CONFIGURATION:-}"
destination="${XABBER_DESTINATION:-}"

action="build"
if [[ $# -gt 0 ]]; then
  case "$1" in
    build|test|resolve|clean-cache)
      action="$1"
      shift
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
  esac
fi

if [[ "$action" != "clean-cache" ]]; then
  for arg in "$@"; do
    if [[ "$arg" == "clean" ]]; then
      echo "error: use 'tools/xcodebuild_cached.sh clean-cache' for an explicit cache reset; routine builds must not pass 'clean'." >&2
      exit 64
    fi
  done
fi

mkdir -p "$derived_data" "$source_packages" "$package_cache"

workspace_path="$repo_root/$workspace"
common_package_args=(
  -clonedSourcePackagesDirPath "$source_packages"
  -packageCachePath "$package_cache"
  -skipPackageUpdates
  -onlyUsePackageVersionsFromResolvedFile
)

echo "xabber cached xcodebuild"
echo "  cache: $cache_root"
echo "  workspace: $workspace"
echo "  scheme: $scheme"

case "$action" in
  clean-cache)
    echo "Removing cache: $cache_root"
    rm -rf "$cache_root"
    ;;
  resolve)
    xcodebuild \
      -resolvePackageDependencies \
      -workspace "$workspace_path" \
      -scheme "$scheme" \
      "${common_package_args[@]}" \
      "$@"
    ;;
  build|test)
    build_args=(
      -workspace "$workspace_path"
      -scheme "$scheme"
      -derivedDataPath "$derived_data"
      "${common_package_args[@]}"
    )
    if [[ -n "$configuration" ]]; then
      build_args+=(-configuration "$configuration")
    fi
    if [[ -n "$destination" ]]; then
      build_args+=(-destination "$destination")
    fi

    disable_account_autoconnect="${TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT:-}"
    isolated_storage="${TEST_RUNNER_XABBER_ISOLATED_STORAGE:-}"
    if [[ "$action" == "test" && ( -n "$disable_account_autoconnect" || -n "$isolated_storage" ) ]]; then
      if [[ "$disable_account_autoconnect" != "1" || "$isolated_storage" != "1" ]]; then
        echo "error: hosted isolated tests require both TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT=1 and TEST_RUNNER_XABBER_ISOLATED_STORAGE=1." >&2
        exit 64
      fi

      hosted_test_bundle_identifier="${XABBER_HOSTED_TEST_BUNDLE_IDENTIFIER:-xabber.ios.codex-hosted-tests}"
      build_args+=(
        "XABBER_APP_BUNDLE_IDENTIFIER=$hosted_test_bundle_identifier"
        "XABBER_PUSH_EXTENSION_BUNDLE_IDENTIFIER=$hosted_test_bundle_identifier.xabber-push-extension"
      )
      echo "  hosted test app: $hosted_test_bundle_identifier"
    fi

    xcodebuild "${build_args[@]}" "$action" "$@"
    ;;
  *)
    echo "error: unsupported action '$action'" >&2
    usage >&2
    exit 64
    ;;
esac
