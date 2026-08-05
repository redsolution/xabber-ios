#!/usr/bin/env python3
"""Fail-closed chat-open video evidence analysis and normalization.

The raw variable-rate recording is the authority. A 60 Hz derivative is an
analysis convenience whose source samples, duplicates, and intra-grid
collisions are recorded explicitly. Recorder-requested FPS is metadata only.

This module intentionally uses only the Python standard library, system
``plutil``, and installed ``ffmpeg``/``ffprobe`` executables. It never invokes
a simulator on its own.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import selectors
import shutil
import signal
import stat
import struct
import subprocess
import sys
import threading
import time
import uuid
import zlib
from collections import defaultdict
from decimal import Decimal, InvalidOperation, ROUND_CEILING
from fractions import Fraction
from pathlib import Path
from typing import Any, Callable, Iterable, Mapping, NamedTuple, Sequence


SCHEMA_VERSION = 1
LOCKED_SIMULATOR_ID = "C3023207-3B9C-417F-8C17-F1A671277C08"
LOCKED_SIMULATOR_NAME = "Xabber Chat Fixed Live QA iPhone 16 Pro"
NATIVE_WINDOW_MIN_WIDTH_POINTS = 400
NATIVE_WINDOW_MIN_HEIGHT_POINTS = 850
NATIVE_WINDOW_MIN_ASPECT_MILLI = 440
NATIVE_WINDOW_MAX_ASPECT_MILLI = 480
NATIVE_WINDOW_OUTPUT_SCALE_MILLI = 1000
NATIVE_WINDOW_H264_DIMENSION_ALIGNMENT_PIXELS = 2
BUNDLED_AXE_PATH = "/opt/homebrew/Cellar/xcodebuildmcp/2.3.0/libexec/bundled/axe"
CAPTURE_LOCK_PATH = Path("/tmp/xabber-chat-open-video-capture-C3023207.lock")
PREBUILD_LOCK_PATH = Path("/tmp/xabber-chat-open-video-prebuild-C3023207.lock")
TOOLS_DIRECTORY = Path(__file__).resolve().parent
REPOSITORY_ROOT = TOOLS_DIRECTORY.parent
APPROVED_XCODEBUILD_WRAPPER = TOOLS_DIRECTORY / "xcodebuild_cached.sh"
BUNDLED_WINDOW_RECORDER_SOURCE = TOOLS_DIRECTORY / "chat_open_window_recorder.swift"
DEFAULT_XCODE_BUILD_PRODUCTS_ROOT = (
    Path.home()
    / "Library/Caches/XabberCodex/xabber-ios-core/DerivedData/Build/Products"
)
MAX_PREBUILT_XCTESTRUN_FILES = 1
MAX_PREBUILT_XCTESTRUN_BYTES = 16 * 1024 * 1024
MAX_PREBUILT_PLIST_JSON_BYTES = 64 * 1024 * 1024
MAX_PREBUILT_REFERENCED_PRODUCTS = 16
MAX_PREBUILT_REFERENCED_REGULAR_FILES = 8192
MAX_PREBUILT_REFERENCED_BYTES = 4 * 1024 * 1024 * 1024
MAX_PREBUILT_REGULAR_FILE_BYTES = 2 * 1024 * 1024 * 1024
SYSTEM_PLUTIL_PATH = Path("/usr/bin/plutil")
PERFORMANCE_UI_TEST_TARGET_NAME = "xabberChatPerformanceUITests"
PERFORMANCE_UI_TEST_BUNDLE_IDENTIFIER = (
    "xabber.ios.xabberChatPerformanceUITests"
)
PERFORMANCE_UI_TEST_RUNNER_BUNDLE_IDENTIFIER = (
    "xabber.ios.xabberChatPerformanceUITests.xctrunner"
)
PERFORMANCE_PUSH_EXTENSION_BUNDLE_IDENTIFIER = (
    "xabber.ios.codex-chat-performance.xabber-push-extension"
)
PERFORMANCE_UI_TARGET_APP_REFERENCE = (
    "__TESTROOT__/Debug-iphonesimulator/xabber.app"
)
PERFORMANCE_UI_TEST_HOST_REFERENCE = (
    "__TESTROOT__/Debug-iphonesimulator/"
    "xabberChatPerformanceUITests-Runner.app"
)
PERFORMANCE_UI_TEST_BUNDLE_REFERENCE = (
    "__TESTROOT__/Debug-iphonesimulator/"
    "xabberChatPerformanceUITests-Runner.app/PlugIns/"
    "xabberChatPerformanceUITests.xctest"
)
PERFORMANCE_PUSH_EXTENSION_REFERENCE = (
    "__TESTROOT__/Debug-iphonesimulator/xabber-push-extension.appex"
)
PERFORMANCE_UI_TEST_BUNDLE_HOST_REFERENCE = (
    "__TESTHOST__/PlugIns/xabberChatPerformanceUITests.xctest"
)
PERFORMANCE_XCTESTRUN_FILENAME_PATTERN = re.compile(
    r"\AChat Performance UI Tests_iphonesimulator[0-9]+(?:\.[0-9]+)*-arm64\.xctestrun\Z"
)
PERFORMANCE_DEPENDENT_PRODUCT_REFERENCES = (
    PERFORMANCE_PUSH_EXTENSION_REFERENCE,
    PERFORMANCE_UI_TARGET_APP_REFERENCE,
    PERFORMANCE_UI_TEST_HOST_REFERENCE,
    PERFORMANCE_UI_TEST_BUNDLE_REFERENCE,
)
WINDOW_RECORDER_READY_RECORD = b"READY\n"
MAX_WINDOW_RECORDER_STARTUP_DIAGNOSTIC_BYTES = 4096
WINDOW_RECORDER_STARTUP_ERROR_PREFIX = b"RECORDER_ERROR:"
WINDOW_RECORDER_STARTUP_ERROR_CODES = frozenset(
    {
        "capture-start",
        "capture-stop",
        "capture-stop-timeout",
        "invalid-arguments",
        "invalid-output",
        "recording-output-attachment",
        "recording-output-failure",
        "shareable-content-unavailable",
        "stop-before-start",
        "stream-stop",
        "unknown",
        "window-identity-mismatch",
        "window-not-found",
    }
)
PERFORMANCE_APP_BUNDLE_IDENTIFIER = "xabber.ios.codex-chat-performance"
ARTIFACT_DATA_CONTAINER_ENVIRONMENT_KEY = (
    "XABBER_CHAT_ARTIFACT_DATA_CONTAINER_PATH"
)
DEFAULT_SIGNPOST_SWIFT_PATH = (
    REPOSITORY_ROOT
    / "xabber/controllers/chats/chat/ChatPerformanceSignposts.swift"
)
GRID_RATE = Decimal(60)
GRID_INTERVAL = Decimal(1) / GRID_RATE
NANOSECOND = Decimal("0.000000001")
GRID_EPSILON = Decimal("0.000000001")
RATE_TOLERANCE_SECONDS = Decimal("0.000100")
MAX_CLOCK_CALIBRATION_RESIDUAL = GRID_INTERVAL + GRID_EPSILON
MAX_CLOCK_DRIFT_PPM = Decimal("10000")
MIN_CLOCK_CALIBRATION_PROVABLE_SPAN = (
    Decimal(2)
    * MAX_CLOCK_CALIBRATION_RESIDUAL
    * Decimal(1_000_000)
    / MAX_CLOCK_DRIFT_PPM
)
MAX_CAPTURE_LOG_BYTES = 1024 * 1024
MAX_CAPTURE_EXPORT_BYTES = 16 * 1024 * 1024
MAX_CAPTURE_LOG_FIELD_KEY_CHARS = 128
MAX_CAPTURE_LOG_PRIVACY_DEPTH = 8
MAX_CAPTURE_LOG_PRIVACY_DECODED_CHARACTERS = MAX_CAPTURE_LOG_BYTES * 16
CAPTURE_LOG_REDACTED_VALUE = "<redacted>"
CAPTURE_LOG_FORBIDDEN_KEY_FRAGMENTS = frozenset(
    {
        "account",
        "archive",
        "archived",
        "auth",
        "authorization",
        "body",
        "credential",
        "jid",
        "apikey",
        "message",
        "owner",
        "passwd",
        "password",
        "path",
        "primary",
        "query",
        "secret",
        "stable",
        "token",
        "uri",
        "url",
    }
)
CAPTURE_LOG_SAFE_NUMERIC_SUFFIXES = (
    "code",
    "count",
    "counter",
    "index",
    "ordinal",
)
CAPTURE_LOG_NEVER_NUMERIC_KEY_FRAGMENTS = frozenset(
    {
        "apikey",
        "auth",
        "authorization",
        "body",
        "credential",
        "jid",
        "owner",
        "passwd",
        "password",
        "path",
        "primary",
        "secret",
        "stable",
        "token",
        "uri",
        "url",
    }
)
CAPTURE_LOG_KEY_PATTERN = re.compile(
    r"[A-Za-z_][A-Za-z0-9_.-]*(?:[ \t]+[A-Za-z_][A-Za-z0-9_.-]*)*"
    r"(?:/[A-Za-z0-9_.-]{1,64})*"
    r"(?:[ \t]*\[[ \t]*[A-Za-z0-9_.-]{0,64}[ \t]*\])*"
)
CAPTURE_LOG_JID_PATTERN = re.compile(
    r"(?<![\w@])[\w.!#$%&'*+/=?^`{|}~-]+@[\w-]+(?:\.[\w-]+)*(?:/[^\s\"']+)?"
)
CAPTURE_LOG_PATH_PATTERN = re.compile(
    r"(?<![A-Za-z0-9_])(?:/(?!/)[^\s\"']+|(?:\./|\.\./)[^\s\"']+)"
)
CAPTURE_LOG_URL_PATTERN = re.compile(
    r"(?i)\b(?:[A-Z][A-Z0-9+.-]{1,31}://|(?:file|xmpp):)[^\s\"']+"
)
DEFAULT_DISK_RESERVE_BYTES = 2 * 1024 * 1024 * 1024
DEFAULT_MAX_BITRATE_MBPS = Decimal(20)
MAX_DECODE_GROUP_BYTES = 512 * 1024 * 1024
MAX_FFMPEG_RATIONAL_COMPONENT = 2_147_483_647
MARKER_DECODE_WIDTH = 360
MIN_MARKER_RUN_FRAMES = 2
MIN_MARKER_COMPONENT_PIXELS = 20
MIN_MARKER_BORDER_SCORE_MILLI = 720
MIN_MARKER_PATTERN_SCORE_MILLI = 740
MIN_MARKER_PATTERN_MARGIN_MILLI = 140
MARKER_CONTRACT = (
    ("M1", "vertical_bars"),
    ("M2", "checkerboard"),
    ("M3", "concentric_rings"),
)
MARKER_MANIFEST_BYTES = "\n".join(
    f"{marker_id}:{visual_code}"
    for marker_id, visual_code in MARKER_CONTRACT
).encode("ascii")
MARKER_MANIFEST_SHA256 = hashlib.sha256(MARKER_MANIFEST_BYTES).hexdigest()
SIGNPOST_RECORD_KIND_CODES = frozenset({1, 2, 3})
SIGNPOST_OPERATION_KIND_CODES = frozenset({1, 2})
SIGNPOST_PURPOSE_CODES = frozenset({1, 2, 3, 4})
SIGNPOST_TERMINAL_CODES = frozenset({0, 1, 2, 3})
SIGNPOST_THREAD_CODES = frozenset({1, 2})
SIGNPOST_COUNTER_CODES = frozenset(range(1, 29))

# One raw recording is evidence for exactly one matrix route. These public,
# identifier-free codes are the complete route-to-fixture contract; accepting
# a syntactically plausible XCTest name is intentionally insufficient.
CHAT_OPEN_VIDEO_ROUTE_MANIFEST: dict[str, dict[str, str]] = {
    "testChatOpenN01PreloadedLatestVideoRoute": {
        "matrix_route_code": "N01",
        "fixture_scenario": "preloaded-latest",
    },
    "testChatOpenN04UnreadBoundaryLocalVideoRoute": {
        "matrix_route_code": "N04",
        "fixture_scenario": "unread-boundary-local",
    },
    "testChatOpenN08SavedPositionLocalVideoRoute": {
        "matrix_route_code": "N08",
        "fixture_scenario": "saved-position-local",
    },
    "testChatOpenE01ConfirmedEmptyVideoRoute": {
        "matrix_route_code": "E01",
        "fixture_scenario": "confirmed-empty",
    },
    "testChatOpenE02ContentVideoRoute": {
        "matrix_route_code": "E02-content",
        "fixture_scenario": "bootstrap-empty-to-content",
    },
    "testChatOpenE04UnsyncedStaleLocalRowsVideoRoute": {
        "matrix_route_code": "E04",
        "fixture_scenario": "bootstrap-stale-local-to-content",
    },
    "testChatOpenE02EmptyVideoRoute": {
        "matrix_route_code": "E02-empty",
        "fixture_scenario": "bootstrap-empty-to-trusted-empty",
    },
    "testChatOpenE10HeldBootstrapWatchdogVideoRoute": {
        "matrix_route_code": "E10",
        "fixture_scenario": "bootstrap-held-over-watchdog",
    },
    "testChatOpenE11TypedFailureRetryVideoRoute": {
        "matrix_route_code": "E11",
        "fixture_scenario": "bootstrap-terminal-failure-retry",
    },
    "testChatOpenX01SearchExactLocalVideoRoute": {
        "matrix_route_code": "X01",
        "fixture_scenario": "search-exact-local",
    },
    "testChatOpenX02SearchExactLocalOutsideWindowVideoRoute": {
        "matrix_route_code": "X02",
        "fixture_scenario": "search-exact-local-outside-window",
    },
    "testChatOpenX03SearchExactRemoteVideoRoute": {
        "matrix_route_code": "X03",
        "fixture_scenario": "search-exact-remote",
    },
    "testChatOpenP01NotificationExactLocalVideoRoute": {
        "matrix_route_code": "P01",
        "fixture_scenario": "notification-exact-local",
    },
    "testChatOpenP02NotificationExactRemoteVideoRoute": {
        "matrix_route_code": "P02",
        "fixture_scenario": "notification-exact-remote",
    },
    "testChatOpenP04ColdPushExactVideoRoute": {
        "matrix_route_code": "P04",
        "fixture_scenario": "cold-push-exact",
    },
    "testChatOpenP09NotificationKnownGapTargetVideoRoute": {
        "matrix_route_code": "P09",
        "fixture_scenario": "notification-known-gap-target",
    },
    "testChatOpenP13DeletedMentionAdvancesVideoRoute": {
        "matrix_route_code": "P13",
        "fixture_scenario": "mention-deleted-advance",
    },
    "testChatOpenP14LastChatsSeededMentionVideoRoute": {
        "matrix_route_code": "P14",
        "fixture_scenario": "last-chats-seeded-mention-exact",
    },
    "testChatOpenG02LatestWithUnrelatedOlderGapVideoRoute": {
        "matrix_route_code": "G02",
        "fixture_scenario": "latest-with-unrelated-older-gap",
    },
    "testChatOpenG05KnownGapMissingTargetVideoRoute": {
        "matrix_route_code": "G05",
        "fixture_scenario": "known-gap-missing-target",
    },
    "testChatOpenG06OlderCrossingGapVideoRoute": {
        "matrix_route_code": "G06",
        "fixture_scenario": "older-crossing-gap",
    },
    "testChatOpenG07NewerCrossingGapVideoRoute": {
        "matrix_route_code": "G07",
        "fixture_scenario": "newer-crossing-gap",
    },
    "testChatOpenV01LastChatsAnimatedPushVideoRoute": {
        "matrix_route_code": "V01",
        "fixture_scenario": "last-chats-animated-push",
    },
    "testChatOpenV08RotationRealPipelineVideoRoute": {
        "matrix_route_code": "V08",
        "fixture_scenario": "rotation-real-pipeline",
    },
    "testChatOpenV10BackgroundForegroundVideoRoute": {
        "matrix_route_code": "V10",
        "fixture_scenario": "committed-content-background-foreground",
    },
}
if (
    len(CHAT_OPEN_VIDEO_ROUTE_MANIFEST) != 25
    or len(
        {
            route["matrix_route_code"]
            for route in CHAT_OPEN_VIDEO_ROUTE_MANIFEST.values()
        }
    )
    != 25
    or len(
        {
            route["fixture_scenario"]
            for route in CHAT_OPEN_VIDEO_ROUTE_MANIFEST.values()
        }
    )
    != 25
):
    raise RuntimeError("chat-open video route manifest must be one-to-one and complete")

VISUAL_STATES = frozenset(
    {
        "skeleton",
        "content",
        "empty",
        "retry",
        "stable",
        "transition",
        "forbidden",
        "other_safe",
    }
)
UUID_PATTERN = re.compile(
    r"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"
)


class EvidenceError(RuntimeError):
    """Raised when an evidence invariant cannot be proven."""


class _CaptureCancelled(Exception):
    pass


def _decimal(value: Any, field: str) -> Decimal:
    try:
        result = Decimal(str(value))
    except (InvalidOperation, ValueError, TypeError) as error:
        raise EvidenceError(f"{field} is not a decimal") from error
    if not result.is_finite():
        raise EvidenceError(f"{field} must be finite")
    return result


def _monotonic_seconds(value: Any, field: str) -> Decimal:
    if (
        isinstance(value, bool)
        or not isinstance(value, int)
        or value < 0
        or value > 0xFFFFFFFFFFFFFFFF
    ):
        raise EvidenceError(f"{field} must be an unsigned 64-bit nanosecond integer")
    return Decimal(value) / Decimal(1_000_000_000)


def _seconds(value: Decimal) -> str:
    return f"{value.quantize(NANOSECOND):.9f}"


def _fraction(value: Any, field: str) -> Fraction:
    try:
        result = Fraction(str(value))
    except (ValueError, ZeroDivisionError) as error:
        raise EvidenceError(f"{field} is not a valid rational rate") from error
    if result <= 0:
        raise EvidenceError(f"{field} must be positive")
    return result


def _canonical_json(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_signpost_phase_manifest(
    swift_path: Path = DEFAULT_SIGNPOST_SWIFT_PATH,
) -> dict[str, Any]:
    """Derive the accepted phase manifest from the production Swift enum.

    No Python phase alias list exists: when Swift adds or removes a phase the
    validator follows that exact checked-in contract automatically.
    """

    swift_path = Path(swift_path)
    _require_regular_file(swift_path, "Swift signpost phase source")
    try:
        source = swift_path.read_text(encoding="utf-8")
    except UnicodeDecodeError as error:
        raise EvidenceError("Swift signpost phase source must be UTF-8") from error
    declaration = re.search(
        r"\benum\s+ChatPerformanceSignpostPhase\s*:\s*String\s*,\s*CaseIterable\s*\{",
        source,
    )
    if declaration is None:
        raise EvidenceError("production Swift signpost phase enum is missing")
    opening = source.find("{", declaration.start())
    depth = 0
    closing: int | None = None
    for index in range(opening, len(source)):
        character = source[index]
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                closing = index
                break
    if closing is None:
        raise EvidenceError("production Swift signpost phase enum is unterminated")
    body = source[opening + 1 : closing]
    cases = re.findall(
        r"(?m)^\s*case\s+([A-Za-z][A-Za-z0-9]*)\s*=\s*\"(chat\.[a-z0-9_]+)\"\s*$",
        body,
    )
    if not cases:
        raise EvidenceError("production Swift signpost phase enum has no closed cases")
    swift_names = [name for name, _raw_value in cases]
    phases = [raw_value for _name, raw_value in cases]
    if len(set(swift_names)) != len(swift_names) or len(set(phases)) != len(phases):
        raise EvidenceError("production Swift signpost phase enum contains duplicates")
    canonical = {"schema_version": SCHEMA_VERSION, "phases": phases}
    manifest_hash = hashlib.sha256(
        _canonical_json(canonical).encode("ascii")
    ).hexdigest()
    return {
        **canonical,
        "sha256": manifest_hash,
        "source_sha256": hashlib.sha256(source.encode("utf-8")).hexdigest(),
        "mechanically_derived_from_swift": True,
    }


def validate_marker_events(marker_events: dict[str, Any]) -> list[dict[str, Any]]:
    if not isinstance(marker_events, dict) or set(marker_events) != {
        "schema_version",
        "marker_manifest_sha256",
        "events",
    }:
        raise EvidenceError("marker-event export uses an unsupported closed schema")
    if marker_events.get("schema_version") != SCHEMA_VERSION:
        raise EvidenceError("marker-event schema version is unsupported")
    if marker_events.get("marker_manifest_sha256") != MARKER_MANIFEST_SHA256:
        raise EvidenceError("marker-event manifest does not match the offline contract")
    events = marker_events.get("events")
    if not isinstance(events, list) or len(events) != len(MARKER_CONTRACT):
        raise EvidenceError("marker-event export must contain M1, M2, and M3 exactly once")
    validated: list[dict[str, Any]] = []
    previous_uptime: int | None = None
    for index, ((expected_id, expected_visual), event) in enumerate(
        zip(MARKER_CONTRACT, events)
    ):
        if not isinstance(event, dict) or set(event) != {
            "marker_id",
            "visual_code",
            "uptime_ns",
        }:
            raise EvidenceError("marker events use a closed three-field schema")
        if event.get("marker_id") != expected_id or event.get("visual_code") != expected_visual:
            raise EvidenceError("marker events must follow the exact M1 < M2 < M3 contract")
        uptime = event.get("uptime_ns")
        _monotonic_seconds(uptime, f"marker event {index} uptime")
        if previous_uptime is not None and uptime <= previous_uptime:
            raise EvidenceError("marker-event uptime must be strictly monotonic")
        previous_uptime = uptime
        validated.append(dict(event))
    return validated


def _is_magenta(rgb: bytes, pixel_index: int) -> bool:
    offset = pixel_index * 3
    red, green, blue = rgb[offset : offset + 3]
    return (
        red >= 175
        and blue >= 145
        and green <= 115
        and min(red, blue) - green >= 80
    )


def _marker_components(rgb: bytes, width: int, height: int) -> list[dict[str, int]]:
    if len(rgb) != width * height * 3:
        raise EvidenceError("decoded marker frame byte count is inconsistent")
    x_min = width // 2
    y_max = max(1, (height * 2) // 5)
    remaining = {
        y * width + x
        for y in range(y_max)
        for x in range(x_min, width)
        if _is_magenta(rgb, y * width + x)
    }
    components: list[dict[str, int]] = []
    while remaining:
        seed = remaining.pop()
        stack = [seed]
        count = 0
        minimum_x = width
        maximum_x = 0
        minimum_y = height
        maximum_y = 0
        while stack:
            pixel = stack.pop()
            y, x = divmod(pixel, width)
            count += 1
            minimum_x = min(minimum_x, x)
            maximum_x = max(maximum_x, x)
            minimum_y = min(minimum_y, y)
            maximum_y = max(maximum_y, y)
            for delta_y in (-1, 0, 1):
                neighbor_y = y + delta_y
                if neighbor_y < 0 or neighbor_y >= y_max:
                    continue
                for delta_x in (-1, 0, 1):
                    if delta_x == 0 and delta_y == 0:
                        continue
                    neighbor_x = x + delta_x
                    if neighbor_x < x_min or neighbor_x >= width:
                        continue
                    neighbor = neighbor_y * width + neighbor_x
                    if neighbor in remaining:
                        remaining.remove(neighbor)
                        stack.append(neighbor)
        if count >= MIN_MARKER_COMPONENT_PIXELS:
            components.append(
                {
                    "count": count,
                    "min_x": minimum_x,
                    "max_x": maximum_x,
                    "min_y": minimum_y,
                    "max_y": maximum_y,
                }
            )
    return components


def _marker_border_score_milli(
    rgb: bytes, width: int, component: Mapping[str, int]
) -> int:
    min_x = component["min_x"]
    max_x = component["max_x"]
    min_y = component["min_y"]
    max_y = component["max_y"]
    box_width = max_x - min_x + 1
    box_height = max_y - min_y + 1
    thickness = max(1, min(box_width, box_height) // 8)
    edge_count = 0
    edge_magenta = 0
    inner_count = 0
    inner_magenta = 0
    for y in range(min_y, max_y + 1):
        for x in range(min_x, max_x + 1):
            on_edge = (
                x < min_x + thickness
                or x > max_x - thickness
                or y < min_y + thickness
                or y > max_y - thickness
            )
            magenta = _is_magenta(rgb, y * width + x)
            if on_edge:
                edge_count += 1
                edge_magenta += int(magenta)
            else:
                inner_count += 1
                inner_magenta += int(magenta)
    if edge_count == 0 or inner_count == 0:
        return 0
    edge_ratio = edge_magenta / edge_count
    inner_ratio = inner_magenta / inner_count
    return max(0, min(1000, int(round((edge_ratio - inner_ratio) * 1000))))


def _marker_pattern_is_bright(visual_code: str, x: float, y: float) -> bool:
    if visual_code == "vertical_bars":
        return int(min(x, 0.999999) * 6) % 2 == 0
    if visual_code == "checkerboard":
        return (
            int(min(x, 0.999999) * 6)
            + int(min(y, 0.999999) * 6)
        ) % 2 == 0
    if visual_code == "concentric_rings":
        radius = (((x - 0.5) * 2) ** 2 + ((y - 0.5) * 2) ** 2) ** 0.5
        return radius < 1 and int(min(radius, 0.999999) * 6) % 2 == 0
    raise EvidenceError("unknown marker visual code")


def _marker_pattern_scores(
    rgb: bytes, width: int, component: Mapping[str, int]
) -> dict[str, int]:
    min_x = component["min_x"]
    max_x = component["max_x"]
    min_y = component["min_y"]
    max_y = component["max_y"]
    inset = max(2, min(max_x - min_x + 1, max_y - min_y + 1) // 7)
    inner_min_x = min_x + inset
    inner_max_x = max_x - inset
    inner_min_y = min_y + inset
    inner_max_y = max_y - inset
    inner_width = inner_max_x - inner_min_x + 1
    inner_height = inner_max_y - inner_min_y + 1
    if inner_width < 8 or inner_height < 8:
        return {visual_code: 0 for _marker_id, visual_code in MARKER_CONTRACT}
    scores: dict[str, int] = {}
    for _marker_id, visual_code in MARKER_CONTRACT:
        error_sum = 0.0
        sample_count = 0
        for y in range(inner_min_y, inner_max_y + 1):
            normalized_y = (y - inner_min_y + 0.5) / inner_height
            for x in range(inner_min_x, inner_max_x + 1):
                normalized_x = (x - inner_min_x + 0.5) / inner_width
                offset = (y * width + x) * 3
                red, green, blue = rgb[offset : offset + 3]
                luminance = (red * 54 + green * 183 + blue * 19) / (256 * 255)
                expected = 1.0 if _marker_pattern_is_bright(
                    visual_code, normalized_x, normalized_y
                ) else 0.0
                error_sum += abs(luminance - expected)
                sample_count += 1
        score = 1 - error_sum / max(1, sample_count)
        scores[visual_code] = max(0, min(1000, int(round(score * 1000))))
    return scores


def classify_video_marker_frame(rgb: bytes, width: int, height: int) -> dict[str, Any]:
    candidates: list[tuple[int, dict[str, int]]] = []
    for component in _marker_components(rgb, width, height):
        box_width = component["max_x"] - component["min_x"] + 1
        box_height = component["max_y"] - component["min_y"] + 1
        aspect = box_width / box_height
        if (
            box_width < 14
            or box_height < 14
            or not Decimal("0.72") <= Decimal(str(aspect)) <= Decimal("1.38")
            or component["max_x"] < (width * 3) // 4
            or component["min_y"] > height // 3
        ):
            continue
        border_score = _marker_border_score_milli(rgb, width, component)
        if border_score >= MIN_MARKER_BORDER_SCORE_MILLI:
            candidates.append((border_score, component))
    if not candidates:
        return {"status": "absent"}
    candidates.sort(key=lambda value: value[0], reverse=True)
    if len(candidates) > 1 and candidates[0][0] - candidates[1][0] < 100:
        return {"status": "ambiguous_fiducial"}
    border_score, component = candidates[0]
    scores = _marker_pattern_scores(rgb, width, component)
    ranked = sorted(scores.items(), key=lambda value: (-value[1], value[0]))
    best_visual, best_score = ranked[0]
    second_score = ranked[1][1]
    confident = [
        visual_code
        for visual_code, score in ranked
        if score >= MIN_MARKER_PATTERN_SCORE_MILLI
    ]
    # The closed classes are intentionally disjoint. A frame with no pattern
    # crossing the acceptance floor is always a near miss, regardless of the
    # margin between several equally poor scores. Ambiguity only exists among
    # frames that otherwise have at least one acceptance-grade candidate.
    if best_score < MIN_MARKER_PATTERN_SCORE_MILLI:
        return {
            "status": "near_pattern",
            "border_score_milli": border_score,
            "pattern_scores_milli": scores,
        }
    if len(confident) > 1 or best_score - second_score < MIN_MARKER_PATTERN_MARGIN_MILLI:
        return {
            "status": "ambiguous_pattern",
            "border_score_milli": border_score,
            "pattern_scores_milli": scores,
        }
    marker_id = next(
        marker_id
        for marker_id, visual_code in MARKER_CONTRACT
        if visual_code == best_visual
    )
    return {
        "status": "exact",
        "marker_id": marker_id,
        "visual_code": best_visual,
        "score_milli": best_score,
        "border_score_milli": border_score,
    }


def _derive_marker_runs(
    frames: Sequence[bytes], width: int, height: int
) -> list[dict[str, Any]]:
    detections = [
        classify_video_marker_frame(frame, width, height)
        for frame in frames
    ]
    return _derive_marker_runs_from_detections(detections)


def _derive_marker_runs_from_detections(
    detections: Sequence[dict[str, Any]],
) -> list[dict[str, Any]]:
    for source_index, detection in enumerate(detections):
        if detection["status"] in {
            "near_pattern",
            "ambiguous_pattern",
            "ambiguous_fiducial",
        }:
            raise EvidenceError(
                f"marker frame {source_index} contains a rejected {detection['status']}"
            )
    runs: list[dict[str, Any]] = []
    current: dict[str, Any] | None = None
    for source_index, detection in enumerate(detections):
        marker_id = detection.get("marker_id") if detection["status"] == "exact" else None
        if current is not None and marker_id == current["marker_id"]:
            current["end_index"] = source_index
            current["scores"].append(detection["score_milli"])
            continue
        if current is not None:
            runs.append(current)
            current = None
        if marker_id is not None:
            current = {
                "marker_id": marker_id,
                "visual_code": detection["visual_code"],
                "start_index": source_index,
                "end_index": source_index,
                "scores": [detection["score_milli"]],
            }
    if current is not None:
        runs.append(current)

    accepted: list[dict[str, Any]] = []
    for expected_id, expected_visual in MARKER_CONTRACT:
        matching = [run for run in runs if run["marker_id"] == expected_id]
        if not matching:
            raise EvidenceError(f"video is missing marker {expected_id}")
        if len(matching) != 1:
            raise EvidenceError(f"video contains disjoint duplicate runs for {expected_id}")
        run = matching[0]
        run_frame_count = run["end_index"] - run["start_index"] + 1
        if run_frame_count < MIN_MARKER_RUN_FRAMES:
            raise EvidenceError(f"video marker {expected_id} is not stable across frames")
        if run["visual_code"] != expected_visual:
            raise EvidenceError("video marker visual code is inconsistent")
        accepted.append({**run, "run_frame_count": run_frame_count})
    onsets = [run["start_index"] for run in accepted]
    if onsets != sorted(onsets) or len(set(onsets)) != len(onsets):
        raise EvidenceError("video marker onset order must be M1 < M2 < M3")
    return accepted


def derive_video_calibration_from_frames(
    *,
    frames: Sequence[bytes],
    width: int,
    height: int,
    source_pts: Sequence[Decimal],
    raw_video_sha256: str,
    marker_events: dict[str, Any],
    marker_event_sha256: str,
    phase_manifest_sha256: str,
) -> dict[str, Any]:
    if len(frames) != len(source_pts) or not frames:
        raise EvidenceError("decoded marker frames must match raw source PTS exactly")
    if not re.fullmatch(r"[0-9a-f]{64}", raw_video_sha256):
        raise EvidenceError("raw video hash is invalid")
    if not re.fullmatch(r"[0-9a-f]{64}", marker_event_sha256):
        raise EvidenceError("marker-event hash is invalid")
    if not re.fullmatch(r"[0-9a-f]{64}", phase_manifest_sha256):
        raise EvidenceError("phase-manifest hash is invalid")
    events = validate_marker_events(marker_events)
    runs = _derive_marker_runs(frames, width, height)
    return _calibration_from_marker_runs(
        runs=runs,
        events=events,
        source_pts=source_pts,
        raw_video_sha256=raw_video_sha256,
        marker_event_sha256=marker_event_sha256,
        phase_manifest_sha256=phase_manifest_sha256,
    )


def _calibration_from_marker_runs(
    *,
    runs: Sequence[dict[str, Any]],
    events: Sequence[dict[str, Any]],
    source_pts: Sequence[Decimal],
    raw_video_sha256: str,
    marker_event_sha256: str,
    phase_manifest_sha256: str,
) -> dict[str, Any]:
    m3_onset_index = runs[-1]["start_index"]
    post_m3_duration = source_pts[-1] - source_pts[m3_onset_index]
    if post_m3_duration < Decimal("0.500"):
        raise EvidenceError("raw video does not preserve the required 500 ms post-M3 tail")
    markers: list[dict[str, Any]] = []
    for event, run in zip(events, runs):
        source_index = run["start_index"]
        markers.append(
            {
                "marker_id": event["marker_id"],
                "visual_code": event["visual_code"],
                "source_index": source_index,
                "source_pts_seconds": _seconds(source_pts[source_index]),
                "uptime_ns": event["uptime_ns"],
                "detection_score_milli": min(run["scores"]),
                "run_frame_count": run["run_frame_count"],
            }
        )
    calibration = {
        "schema_version": SCHEMA_VERSION,
        "raw_video_sha256": raw_video_sha256,
        "marker_event_sha256": marker_event_sha256,
        "marker_manifest_sha256": MARKER_MANIFEST_SHA256,
        "phase_manifest_sha256": phase_manifest_sha256,
        "markers": markers,
    }
    # A calibration artifact is publishable only if the exact same affine fit
    # used by final package validation already passes. Marker detection alone
    # cannot certify a clock mapping.
    _clock_fit(calibration, source_pts)
    return calibration


def _detect_marker_runs_in_video(
    raw_path: Path,
    probe_data: dict[str, Any],
    *,
    ffmpeg_path: str | None = None,
) -> list[dict[str, Any]]:
    stream = _video_stream(probe_data)
    source_width = stream.get("width")
    source_height = stream.get("height")
    if (
        isinstance(source_width, bool)
        or not isinstance(source_width, int)
        or source_width <= 0
        or isinstance(source_height, bool)
        or not isinstance(source_height, int)
        or source_height <= 0
    ):
        raise EvidenceError("raw marker video dimensions are invalid")
    width = min(MARKER_DECODE_WIDTH, source_width)
    height = max(1, int(round(source_height * width / source_width)))
    executable = ffmpeg_path or shutil.which("ffmpeg")
    if not executable:
        raise EvidenceError("ffmpeg is required for offline marker detection")
    command = _raw_rgb_decoder_command(
        executable,
        raw_path,
        probe_data,
        video_filter=f"scale={width}:{height}:flags=area",
    )
    process = subprocess.Popen(
        command,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        shell=False,
    )
    if process.stdout is None or process.stderr is None:
        raise EvidenceError("ffmpeg marker decoder did not expose pipes")
    frame_size = width * height * 3
    expected_count = len(extract_frame_pts(probe_data))
    detections: list[dict[str, Any]] = []
    try:
        for _ in range(expected_count):
            frame = _read_exact(process.stdout, frame_size)
            if len(frame) != frame_size:
                raise EvidenceError(
                    "ffmpeg decoded fewer marker frames than ffprobe reported"
                )
            detections.append(classify_video_marker_frame(frame, width, height))
        if process.stdout.read(1):
            raise EvidenceError("ffmpeg decoded more marker frames than ffprobe reported")
        process.stdout.close()
        stderr = process.stderr.read()
        process.stderr.close()
        returncode = process.wait()
        if returncode != 0 or stderr:
            raise EvidenceError("ffmpeg failed during offline marker detection")
    except Exception:
        if process.poll() is None:
            process.kill()
            process.wait()
        try:
            process.stdout.close()
        except OSError:
            pass
        try:
            process.stderr.close()
        except OSError:
            pass
        raise
    return _derive_marker_runs_from_detections(detections)


def derive_video_calibration(
    *,
    raw_path: Path,
    probe_data: dict[str, Any],
    marker_events_path: Path,
    signpost_swift_path: Path = DEFAULT_SIGNPOST_SWIFT_PATH,
    ffmpeg_path: str | None = None,
) -> dict[str, Any]:
    raw_path = Path(raw_path)
    marker_events_path = Path(marker_events_path)
    _require_regular_file(raw_path, "raw marker video")
    marker_events = _load_json(marker_events_path, "marker-event export")
    source_pts = extract_frame_pts(probe_data)
    runs = _detect_marker_runs_in_video(
        raw_path, probe_data, ffmpeg_path=ffmpeg_path
    )
    phase_manifest = load_signpost_phase_manifest(signpost_swift_path)
    events = validate_marker_events(marker_events)
    return _calibration_from_marker_runs(
        runs=runs,
        events=events,
        source_pts=source_pts,
        raw_video_sha256=sha256_file(raw_path),
        marker_event_sha256=sha256_file(marker_events_path),
        phase_manifest_sha256=phase_manifest["sha256"],
    )


def _least_squares_affine_fit(
    xs: Sequence[Decimal], ys: Sequence[Decimal]
) -> dict[str, Any]:
    if len(xs) != len(ys) or len(xs) < 2:
        raise EvidenceError("clock calibration fit requires paired samples")
    count = Decimal(len(xs))
    mean_x = sum(xs, Decimal(0)) / count
    mean_y = sum(ys, Decimal(0)) / count
    denominator = sum((value - mean_x) ** 2 for value in xs)
    if denominator <= 0:
        raise EvidenceError("clock calibration markers do not span video time")
    slope = sum(
        (x_value - mean_x) * (y_value - mean_y)
        for x_value, y_value in zip(xs, ys)
    ) / denominator
    intercept = mean_y - slope * mean_x
    residuals = [
        y_value - (intercept + slope * x_value)
        for x_value, y_value in zip(xs, ys)
    ]
    maximum_residual = max(abs(value) for value in residuals)
    rms_residual = (
        sum((value ** 2 for value in residuals), Decimal(0)) / count
    ).sqrt()
    return {
        "intercept": intercept,
        "slope": slope,
        "residuals": residuals,
        "maximum_residual": maximum_residual,
        "rms_residual": rms_residual,
        "drift_ppm": abs(slope - Decimal(1)) * Decimal(1_000_000),
    }


def _clock_fit(
    calibration: dict[str, Any], source_pts: Sequence[Decimal]
) -> tuple[dict[str, Any], Decimal, Decimal]:
    if not isinstance(calibration, dict) or set(calibration) != {
        "schema_version",
        "raw_video_sha256",
        "marker_event_sha256",
        "marker_manifest_sha256",
        "phase_manifest_sha256",
        "markers",
    }:
        raise EvidenceError("derived clock calibration uses an unsupported closed schema")
    if calibration.get("schema_version") != SCHEMA_VERSION:
        raise EvidenceError("clock calibration schema version is unsupported")
    for field in (
        "raw_video_sha256",
        "marker_event_sha256",
        "phase_manifest_sha256",
    ):
        if not re.fullmatch(r"[0-9a-f]{64}", str(calibration.get(field))):
            raise EvidenceError(f"clock calibration {field} is invalid")
    if calibration.get("marker_manifest_sha256") != MARKER_MANIFEST_SHA256:
        raise EvidenceError("clock calibration marker manifest is invalid")
    if len(source_pts) < 2:
        raise EvidenceError("clock calibration requires at least two source samples")
    normalized_pts = [
        _decimal(value, "source PTS") - _decimal(source_pts[0], "first source PTS")
        for value in source_pts
    ]
    for previous, current in zip(normalized_pts, normalized_pts[1:]):
        if current <= previous:
            raise EvidenceError("clock calibration source PTS must be strictly monotonic")
    markers = calibration.get("markers")
    if not isinstance(markers, list) or len(markers) != len(MARKER_CONTRACT):
        raise EvidenceError("clock calibration requires exactly three measured markers")

    xs: list[Decimal] = []
    ys: list[Decimal] = []
    marker_indices: list[int] = []
    previous_index: int | None = None
    previous_monotonic: Decimal | None = None
    for marker_ordinal, (marker, expected_contract) in enumerate(
        zip(markers, MARKER_CONTRACT)
    ):
        if not isinstance(marker, dict) or set(marker) != {
            "marker_id",
            "visual_code",
            "source_index",
            "source_pts_seconds",
            "uptime_ns",
            "detection_score_milli",
            "run_frame_count",
        }:
            raise EvidenceError("clock markers use a closed seven-field schema")
        expected_id, expected_visual = expected_contract
        if (
            marker.get("marker_id") != expected_id
            or marker.get("visual_code") != expected_visual
        ):
            raise EvidenceError("clock markers must follow M1 < M2 < M3")
        source_index = marker.get("source_index")
        if isinstance(source_index, bool) or not isinstance(source_index, int):
            raise EvidenceError("clock marker source_index must be an integer")
        if source_index < 0 or source_index >= len(normalized_pts):
            raise EvidenceError("clock marker source_index is outside the raw video")
        if marker.get("source_pts_seconds") != _seconds(source_pts[source_index]):
            raise EvidenceError("clock marker PTS was not authored from raw ffprobe PTS")
        detection_score = marker.get("detection_score_milli")
        run_frame_count = marker.get("run_frame_count")
        if (
            isinstance(detection_score, bool)
            or not isinstance(detection_score, int)
            or detection_score < MIN_MARKER_PATTERN_SCORE_MILLI
            or detection_score > 1000
            or isinstance(run_frame_count, bool)
            or not isinstance(run_frame_count, int)
            or run_frame_count < MIN_MARKER_RUN_FRAMES
        ):
            raise EvidenceError("clock marker detection proof is insufficient")
        monotonic = _monotonic_seconds(
            marker.get("uptime_ns"),
            f"clock marker {marker_ordinal} uptime",
        )
        if previous_index is not None and source_index <= previous_index:
            raise EvidenceError("clock marker source indices must be strictly ordered")
        if previous_monotonic is not None and monotonic <= previous_monotonic:
            raise EvidenceError("clock marker timestamps must be strictly ordered")
        previous_index = source_index
        previous_monotonic = monotonic
        marker_indices.append(source_index)
        xs.append(normalized_pts[source_index])
        ys.append(monotonic)

    source_marker_span = xs[-1] - xs[0]
    uptime_marker_span = ys[-1] - ys[0]
    if (
        source_marker_span < MIN_CLOCK_CALIBRATION_PROVABLE_SPAN
        or uptime_marker_span < MIN_CLOCK_CALIBRATION_PROVABLE_SPAN
    ):
        raise EvidenceError(
            "clock calibration marker span cannot prove the closed drift bound"
        )
    fit = _least_squares_affine_fit(xs, ys)
    slope = fit["slope"]
    if slope <= 0:
        raise EvidenceError("clock calibration derived a non-positive clock rate")
    intercept = fit["intercept"]
    maximum_residual = fit["maximum_residual"]
    rms_residual = fit["rms_residual"]
    drift_ppm = fit["drift_ppm"]
    if maximum_residual > MAX_CLOCK_CALIBRATION_RESIDUAL:
        raise EvidenceError("clock calibration residual exceeds the closed bound")
    if drift_ppm > MAX_CLOCK_DRIFT_PPM:
        raise EvidenceError("clock calibration drift exceeds the closed bound")
    uncertainty = maximum_residual + GRID_INTERVAL
    report = {
        "method": "least_squares_affine_offline_video_markers",
        "marker_count": len(markers),
        "marker_ids": [marker_id for marker_id, _visual in MARKER_CONTRACT],
        "marker_source_indices": marker_indices,
        "source_marker_span_seconds": _seconds(source_marker_span),
        "uptime_marker_span_seconds": _seconds(uptime_marker_span),
        "minimum_provable_marker_span_seconds": _seconds(
            MIN_CLOCK_CALIBRATION_PROVABLE_SPAN
        ),
        "offset_monotonic_seconds": _seconds(intercept),
        "monotonic_seconds_per_video_second": _seconds(slope),
        "clock_drift_ppm": _seconds(drift_ppm),
        "maximum_allowed_clock_drift_ppm": _seconds(MAX_CLOCK_DRIFT_PPM),
        "maximum_residual_seconds": _seconds(maximum_residual),
        "rms_residual_seconds": _seconds(rms_residual),
        "maximum_allowed_residual_seconds": _seconds(
            MAX_CLOCK_CALIBRATION_RESIDUAL
        ),
        "video_quantization_seconds": _seconds(GRID_INTERVAL),
        "maximum_compositor_frame_bound_seconds": _seconds(GRID_INTERVAL),
        "bounded_uncertainty_seconds": _seconds(uncertainty),
        "source_indices_authored_offline_from_raw_video": True,
        "free_clock_origin_forbidden": True,
    }
    return report, intercept, slope


def derive_clock_mapping(
    calibration: dict[str, Any], source_pts: Sequence[Decimal]
) -> dict[str, Any]:
    report, _intercept, _slope = _clock_fit(calibration, source_pts)
    return report


def validate_calibration_bindings(
    calibration: dict[str, Any],
    *,
    raw_video_sha256: str,
    marker_event_sha256: str,
    phase_manifest_sha256: str,
) -> None:
    if (
        calibration.get("raw_video_sha256") != raw_video_sha256
        or calibration.get("marker_event_sha256") != marker_event_sha256
        or calibration.get("marker_manifest_sha256") != MARKER_MANIFEST_SHA256
        or calibration.get("phase_manifest_sha256") != phase_manifest_sha256
    ):
        raise EvidenceError("clock calibration hash binding is incomplete")


def _require_regular_file(path: Path, label: str) -> None:
    if not path.is_file():
        raise EvidenceError(f"{label} must be an existing regular file")


def _video_stream(probe_data: dict[str, Any]) -> dict[str, Any]:
    streams = probe_data.get("streams")
    if not isinstance(streams, list):
        raise EvidenceError("ffprobe JSON has no streams array")
    video_streams = [
        stream
        for stream in streams
        if isinstance(stream, dict) and stream.get("codec_type") == "video"
    ]
    if len(video_streams) != 1:
        raise EvidenceError("ffprobe JSON must describe exactly one video stream")
    return video_streams[0]


def extract_frame_pts(probe_data: dict[str, Any]) -> list[Decimal]:
    frames = probe_data.get("frames")
    if not isinstance(frames, list) or not frames:
        raise EvidenceError("ffprobe JSON must include decoded video frames")
    result: list[Decimal] = []
    for frame_index, frame in enumerate(frames):
        if not isinstance(frame, dict):
            raise EvidenceError("ffprobe frame entry must be an object")
        if frame.get("media_type", "video") != "video":
            continue
        raw_pts = None
        for key in (
            "best_effort_timestamp_time",
            "pts_time",
            "pkt_pts_time",
            "pkt_dts_time",
        ):
            if frame.get(key) not in (None, "N/A"):
                raw_pts = frame[key]
                break
        if raw_pts is None:
            raise EvidenceError(f"ffprobe video frame {frame_index} has no presentation timestamp")
        result.append(_decimal(raw_pts, f"frame {frame_index} PTS"))
    if not result:
        raise EvidenceError("ffprobe JSON contains no video presentation timestamps")
    for previous, current in zip(result, result[1:]):
        if current <= previous:
            raise EvidenceError("source PTS must be strictly monotonic")
    return result


def _probe_duration(probe_data: dict[str, Any], frame_pts: Sequence[Decimal]) -> Decimal:
    stream = _video_stream(probe_data)
    candidates: list[Decimal] = []
    for container, key in (
        (stream, "duration"),
        (probe_data.get("format", {}), "duration"),
    ):
        if isinstance(container, dict) and container.get(key) not in (None, "N/A"):
            candidate = _decimal(container[key], f"ffprobe {key}")
            if candidate > 0:
                candidates.append(candidate)

    video_frames = [
        frame
        for frame in probe_data.get("frames", [])
        if isinstance(frame, dict) and frame.get("media_type", "video") == "video"
    ]
    final_duration = Decimal(0)
    if video_frames:
        raw_final_duration = video_frames[-1].get("duration_time")
        if raw_final_duration not in (None, "N/A"):
            final_duration = max(
                Decimal(0), _decimal(raw_final_duration, "final frame duration")
            )
    measured_span = frame_pts[-1] - frame_pts[0] + final_duration
    if measured_span > 0:
        candidates.append(measured_span)
    if not candidates:
        raise EvidenceError("ffprobe did not prove a positive video duration")
    duration = max(candidates)
    if duration < frame_pts[-1] - frame_pts[0]:
        raise EvidenceError("ffprobe duration is shorter than the source PTS span")
    return duration


def _rate_mode(
    frame_pts: Sequence[Decimal], *, timestamp_tolerance: Decimal
) -> tuple[str, Decimal | None]:
    if len(frame_pts) < 2:
        return "single_sample", None
    deltas = [current - previous for previous, current in zip(frame_pts, frame_pts[1:])]
    reference = sum(deltas, Decimal(0)) / Decimal(len(deltas))
    constant = all(abs(delta - reference) <= timestamp_tolerance for delta in deltas)
    if not constant:
        return "variable", None
    measured = Decimal(1) / reference
    rounded = measured.quantize(Decimal(1))
    if abs(measured - rounded) <= Decimal("0.05"):
        return f"constant_{int(rounded)}", measured
    return "constant_non_integer", measured


def analyze_probe(
    raw_path: Path,
    probe_data: dict[str, Any],
    *,
    requested_fps: int | None = None,
) -> dict[str, Any]:
    """Validate ffprobe JSON and return a path-free source report."""

    raw_path = Path(raw_path)
    _require_regular_file(raw_path, "raw source")
    stream = _video_stream(probe_data)
    frame_pts = extract_frame_pts(probe_data)
    duration = _probe_duration(probe_data, frame_pts)

    width = stream.get("width")
    height = stream.get("height")
    if not isinstance(width, int) or width <= 0 or not isinstance(height, int) or height <= 0:
        raise EvidenceError("ffprobe must prove positive integer video dimensions")

    for field in ("nb_read_frames", "nb_frames"):
        reported = stream.get(field)
        if reported not in (None, "N/A"):
            try:
                reported_count = int(reported)
            except (TypeError, ValueError) as error:
                raise EvidenceError(f"ffprobe {field} is not an integer") from error
            if reported_count != len(frame_pts):
                raise EvidenceError(
                    f"ffprobe {field} disagrees with decoded frame count"
                )

    r_frame_rate = _fraction(stream.get("r_frame_rate"), "r_frame_rate")
    avg_frame_rate = _fraction(stream.get("avg_frame_rate"), "avg_frame_rate")
    time_base = _fraction(stream.get("time_base"), "time_base")
    timestamp_resolution = Decimal(time_base.numerator) / Decimal(time_base.denominator)
    timestamp_tolerance = max(
        RATE_TOLERANCE_SECONDS,
        timestamp_resolution + Decimal("0.000050"),
    )
    mode, measured_rate = _rate_mode(
        frame_pts,
        timestamp_tolerance=timestamp_tolerance,
    )
    deltas = [current - previous for previous, current in zip(frame_pts, frame_pts[1:])]
    count_duration_error = abs(Decimal(len(frame_pts)) - duration * GRID_RATE)
    rate_fields_prove_60 = (
        abs(Decimal(r_frame_rate.numerator) / Decimal(r_frame_rate.denominator) - GRID_RATE)
        <= Decimal("0.001")
        and abs(
            Decimal(avg_frame_rate.numerator) / Decimal(avg_frame_rate.denominator)
            - GRID_RATE
        )
        <= Decimal("0.001")
    )
    pts_prove_60 = (
        timestamp_resolution <= GRID_INTERVAL
        and bool(deltas)
        and all(
            abs(delta - GRID_INTERVAL) <= timestamp_tolerance
            and GRID_INTERVAL / Decimal(2) <= delta <= GRID_INTERVAL * Decimal("1.5")
            for delta in deltas
        )
    )
    native_60_proven = (
        rate_fields_prove_60
        and pts_prove_60
        and count_duration_error <= Decimal("0.10")
    )

    source_hash = sha256_file(raw_path)
    source = {
        "artifact_id": f"sha256:{source_hash[:16]}",
        "sha256": source_hash,
        "byte_count": raw_path.stat().st_size,
        "width": width,
        "height": height,
        "duration_seconds": _seconds(duration),
        "frame_count": len(frame_pts),
        "r_frame_rate": str(r_frame_rate),
        "avg_frame_rate": str(avg_frame_rate),
        "measured_rate_mode": mode,
        "measured_rate_fps": (
            _seconds(measured_rate) if measured_rate is not None else None
        ),
        "first_pts_seconds": _seconds(frame_pts[0]),
        "last_pts_seconds": _seconds(frame_pts[-1]),
        "strictly_monotonic_pts": True,
        "timestamp_resolution_seconds": _seconds(timestamp_resolution),
        "pts_rate_tolerance_seconds": _seconds(timestamp_tolerance),
        "minimum_delta_seconds": _seconds(min(deltas)) if deltas else None,
        "maximum_delta_seconds": _seconds(max(deltas)) if deltas else None,
        "native_60_proven": native_60_proven,
    }
    result: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "privacy": {
            "contains_paths": False,
            "contains_account_or_message_fields": False,
        },
        "source": source,
    }
    if requested_fps is not None:
        if requested_fps <= 0:
            raise EvidenceError("requested FPS must be positive")
        result["recorder_request"] = {
            "fps": requested_fps,
            "accepted_as_rate_proof": False,
        }
    return result


def build_grid_plan(
    frame_pts: Sequence[Decimal], source_duration: Decimal
) -> dict[str, Any]:
    """Map source samples onto a 60 Hz hold-latest grid without hiding samples."""

    if not frame_pts:
        raise EvidenceError("at least one source sample is required")
    normalized_pts = [_decimal(value, "source PTS") - frame_pts[0] for value in frame_pts]
    for previous, current in zip(normalized_pts, normalized_pts[1:]):
        if current <= previous:
            raise EvidenceError("source PTS must be strictly monotonic")
    source_duration = _decimal(source_duration, "source duration")
    if source_duration <= 0:
        raise EvidenceError("source duration must be positive")
    if source_duration < normalized_pts[-1]:
        raise EvidenceError("source duration is shorter than normalized PTS span")

    target_indices = [
        int(
            (relative_pts * GRID_RATE - GRID_EPSILON).to_integral_value(
                rounding=ROUND_CEILING
            )
        )
        for relative_pts in normalized_pts
    ]
    if target_indices[0] != 0:
        raise EvidenceError("first normalized source sample must map to grid zero")
    if any(index < 0 for index in target_indices):
        raise EvidenceError("normalized grid indices cannot be negative")

    groups: dict[int, list[int]] = defaultdict(list)
    for source_index, target_index in enumerate(target_indices):
        groups[target_index].append(source_index)

    duration_frame_count = int(
        (source_duration * GRID_RATE - GRID_EPSILON).to_integral_value(
            rounding=ROUND_CEILING
        )
    )
    frame_count = max(1, duration_frame_count, max(target_indices) + 1)
    collision_groups = [
        {"grid_index": grid_index, "source_indices": source_indices}
        for grid_index, source_indices in sorted(groups.items())
        if len(source_indices) > 1
    ]

    samples: list[dict[str, Any]] = []
    for source_index, (pts, relative_pts, target_index) in enumerate(
        zip(frame_pts, normalized_pts, target_indices)
    ):
        group = groups[target_index]
        delta = None if source_index == 0 else relative_pts - normalized_pts[source_index - 1]
        role = (
            "intra_grid_collision"
            if len(group) > 1 and source_index != group[-1]
            else "source_sample"
        )
        samples.append(
            {
                "source_index": source_index,
                "pts_seconds": _seconds(_decimal(pts, "source PTS")),
                "relative_pts_seconds": _seconds(relative_pts),
                "delta_from_previous_seconds": _seconds(delta) if delta is not None else None,
                "shorter_than_grid_interval": (
                    delta is not None and delta < GRID_INTERVAL
                ),
                "target_grid_index": target_index,
                "mapping_role": role,
            }
        )

    grid_frames: list[dict[str, Any]] = []
    selected_source_index: int | None = None
    for grid_index in range(frame_count):
        source_indices = groups.get(grid_index)
        if source_indices:
            selected_source_index = source_indices[-1]
            provenance = "source_sample"
        else:
            if selected_source_index is None:
                raise EvidenceError("60 Hz grid precedes the first source sample")
            provenance = "duplicate_of_source_sample"
        grid_frames.append(
            {
                "grid_index": grid_index,
                "pts_seconds": _seconds(Decimal(grid_index) / GRID_RATE),
                "source_index": selected_source_index,
                "provenance": provenance,
            }
        )

    return {
        "policy": "first-grid-at-or-after-source-pts; hold-latest-between-source-samples",
        "grid_rate": "60/1",
        "grid_interval_seconds": _seconds(GRID_INTERVAL),
        "source_sample_count": len(samples),
        "mapped_source_sample_count": len(samples),
        "normalized_frame_count": frame_count,
        "collision_group_count": len(collision_groups),
        "collision_sample_count": sum(
            len(group["source_indices"]) for group in collision_groups
        ),
        "intra_grid_hidden_sample_count": sum(
            len(group["source_indices"]) - 1 for group in collision_groups
        ),
        "samples": samples,
        "collision_groups": collision_groups,
        "grid_frames": grid_frames,
    }


def run_ffprobe(path: Path, *, ffprobe_path: str | None = None) -> dict[str, Any]:
    path = Path(path)
    _require_regular_file(path, "video artifact")
    executable = ffprobe_path or shutil.which("ffprobe")
    if not executable:
        raise EvidenceError("ffprobe executable is unavailable")
    command = [
        executable,
        "-v",
        "error",
        "-select_streams",
        "v:0",
        "-count_frames",
        "-show_streams",
        "-show_format",
        "-show_frames",
        "-show_entries",
        "stream=index,codec_type,width,height,r_frame_rate,avg_frame_rate,time_base,duration,nb_frames,nb_read_frames:format=duration,start_time:frame=media_type,best_effort_timestamp_time,pts_time,pkt_pts_time,pkt_dts_time,duration_time",
        "-of",
        "json",
        str(path),
    ]
    completed = subprocess.run(command, capture_output=True, check=False)
    if completed.returncode != 0:
        raise EvidenceError("ffprobe failed to read the video artifact")
    try:
        parsed = json.loads(completed.stdout.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise EvidenceError("ffprobe did not emit valid JSON") from error
    if not isinstance(parsed, dict):
        raise EvidenceError("ffprobe JSON root must be an object")
    return parsed


def _resolved_nonexistent(path: Path) -> Path:
    return path.parent.resolve(strict=True) / path.name


def validate_new_output_paths(raw_path: Path, output_paths: Sequence[Path]) -> None:
    raw_path = Path(raw_path)
    _require_regular_file(raw_path, "raw source")
    raw_resolved = raw_path.resolve(strict=True)
    resolved_outputs: list[Path] = []
    for output in output_paths:
        output = Path(output)
        if not output.is_absolute():
            output = output.absolute()
        if not output.parent.is_dir():
            raise EvidenceError("every output parent must already exist")
        resolved = _resolved_nonexistent(output)
        if resolved == raw_resolved:
            raise EvidenceError("an evidence output must not alias the raw source")
        if os.path.lexists(output):
            try:
                if os.path.samefile(raw_path, output):
                    raise EvidenceError("an evidence output must not alias the raw source")
            except OSError:
                pass
            raise EvidenceError("an evidence output already exists; overwrite is forbidden")
        resolved_outputs.append(resolved)

    if len(set(resolved_outputs)) != len(resolved_outputs):
        raise EvidenceError("evidence outputs must be distinct")
    for left in resolved_outputs:
        for right in resolved_outputs:
            if left == right:
                continue
            if left in right.parents or right in left.parents:
                raise EvidenceError("evidence outputs must not contain one another")

    output_devices = {path.parent.stat().st_dev for path in resolved_outputs}
    if len(output_devices) != 1:
        raise EvidenceError("evidence outputs must share one destination filesystem")


def choose_derivative_codec(codec: str, *, allow_ffv1: bool) -> dict[str, Any]:
    if codec == "h264":
        return {
            "name": "h264",
            "codec": "libx264",
            "lossy": True,
            "pre_encode_framemd5_required": True,
        }
    if codec == "hevc":
        return {
            "name": "hevc",
            "codec": "libx265",
            "lossy": True,
            "pre_encode_framemd5_required": True,
        }
    if codec == "ffv1":
        if not allow_ffv1:
            raise EvidenceError("FFV1 requires explicit opt-in and a storage preflight")
        return {
            "name": "ffv1",
            "codec": "ffv1",
            "lossy": False,
            "pre_encode_framemd5_required": True,
        }
    raise EvidenceError("derivative codec must be h264, hevc, or ffv1")


def estimate_normalization_bytes(
    *,
    width: int,
    height: int,
    normalized_frame_count: int,
    source_sample_count: int,
    collision_sample_count: int,
    codec: str,
    max_bitrate_mbps: Decimal = DEFAULT_MAX_BITRATE_MBPS,
) -> dict[str, int]:
    if width <= 0 or height <= 0 or normalized_frame_count <= 0:
        raise EvidenceError("normalization estimate dimensions/count must be positive")
    rgb_frame_bytes = width * height * 3
    collision_bytes = int(collision_sample_count * (rgb_frame_bytes * 1.02 + 256))
    duration = Decimal(normalized_frame_count) / GRID_RATE
    if codec == "ffv1":
        derivative_bytes = max(
            16 * 1024 * 1024,
            int(Decimal(rgb_frame_bytes * normalized_frame_count) * Decimal("1.10")),
        )
    else:
        max_bitrate_bps = _decimal(max_bitrate_mbps, "max bitrate Mbps") * Decimal(1_000_000)
        if max_bitrate_bps <= 0:
            raise EvidenceError("max bitrate must be positive")
        derivative_bytes = int(max_bitrate_bps * duration / Decimal(8) * Decimal("1.10"))
        derivative_bytes += 16 * 1024 * 1024
    metadata_bytes = (
        normalized_frame_count * 320
        + source_sample_count * 768
        + 4 * 1024 * 1024
    )
    required = derivative_bytes + collision_bytes + metadata_bytes
    return {
        "derivative_upper_bound_bytes": derivative_bytes,
        "collision_png_upper_bound_bytes": collision_bytes,
        "metadata_upper_bound_bytes": metadata_bytes,
        "required_bytes": required,
    }


def enforce_storage_budget(
    *, required_bytes: int, free_bytes: int, reserve_bytes: int
) -> None:
    if min(required_bytes, free_bytes, reserve_bytes) < 0:
        raise EvidenceError("storage budget values cannot be negative")
    if free_bytes - reserve_bytes < required_bytes:
        raise EvidenceError("insufficient free space for safe evidence output")


def _png_chunk(chunk_type: bytes, payload: bytes) -> bytes:
    checksum = zlib.crc32(chunk_type)
    checksum = zlib.crc32(payload, checksum) & 0xFFFFFFFF
    return struct.pack(">I", len(payload)) + chunk_type + payload + struct.pack(">I", checksum)


def _rgb_png_bytes(width: int, height: int, rgb: bytes) -> bytes:
    expected = width * height * 3
    if len(rgb) != expected:
        raise EvidenceError("decoded RGB sample has an unexpected byte count")
    scanlines = b"".join(
        b"\x00" + rgb[row * width * 3 : (row + 1) * width * 3]
        for row in range(height)
    )
    return (
        b"\x89PNG\r\n\x1a\n"
        + _png_chunk(
            b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
        )
        + _png_chunk(b"IDAT", zlib.compress(scanlines, level=9))
        + _png_chunk(b"IEND", b"")
    )


def _write_rgb_png(path: Path, width: int, height: int, rgb: bytes) -> str:
    png = _rgb_png_bytes(width, height, rgb)
    with path.open("xb") as handle:
        handle.write(png)
    return hashlib.sha256(png).hexdigest()


def _partial_path(final_path: Path) -> Path:
    suffix = final_path.suffix
    basename = final_path.name[: -len(suffix)] if suffix else final_path.name
    token = f"partial-{os.getpid()}-{uuid.uuid4().hex}"
    return final_path.parent / f".{basename}.{token}{suffix}"


def _publish_file_no_overwrite(partial: Path, final: Path) -> None:
    if os.path.lexists(final):
        raise EvidenceError("an evidence output appeared during publication")
    try:
        os.link(partial, final)
    except FileExistsError as error:
        raise EvidenceError("an evidence output appeared during publication") from error
    partial.unlink()


def _publish_flat_directory_no_overwrite(partial: Path, final: Path) -> None:
    try:
        final.mkdir(mode=0o700)
    except FileExistsError as error:
        raise EvidenceError("an evidence output appeared during publication") from error
    try:
        for child in partial.iterdir():
            if not child.is_file() or child.is_symlink():
                raise EvidenceError("collision staging directory must contain only regular files")
            os.link(child, final / child.name)
        shutil.rmtree(partial)
    except Exception:
        shutil.rmtree(final)
        raise


def _write_framemd5_header(handle: Any, width: int, height: int) -> None:
    handle.write("#format: frame checksums\n")
    handle.write("#version: 2\n")
    handle.write("#hash: MD5\n")
    handle.write("#software: xabber-chat-open-video-evidence\n")
    handle.write("#tb 0: 1/60\n")
    handle.write("#media_type 0: video\n")
    handle.write("#codec_id 0: rawvideo\n")
    handle.write(f"#dimensions 0: {width}x{height}\n")
    handle.write("#sar 0: 0/1\n")


def _write_framemd5_line(handle: Any, index: int, size: int, digest: str) -> None:
    handle.write(f"0, {index:10d}, {index:10d},        1, {size:10d}, {digest}\n")


def _encoder_command(
    ffmpeg: str,
    *,
    width: int,
    height: int,
    codec: dict[str, Any],
    max_bitrate_mbps: Decimal,
    output: Path,
) -> list[str]:
    command = [
        ffmpeg,
        "-v",
        "error",
        "-f",
        "rawvideo",
        "-pix_fmt",
        "rgb24",
        "-video_size",
        f"{width}x{height}",
        "-framerate",
        "60",
        "-i",
        "pipe:0",
        "-an",
    ]
    if codec["name"] == "h264":
        bitrate = f"{max_bitrate_mbps.normalize()}M"
        command.extend(
            [
                "-c:v",
                "libx264",
                "-preset",
                "veryfast",
                "-crf",
                "18",
                "-maxrate",
                bitrate,
                "-bufsize",
                f"{(max_bitrate_mbps * 2).normalize()}M",
                "-pix_fmt",
                "yuv420p",
                "-fps_mode",
                "cfr",
                "-movflags",
                "+faststart",
                "-f",
                "mp4",
            ]
        )
    elif codec["name"] == "hevc":
        bitrate = f"{max_bitrate_mbps.normalize()}M"
        command.extend(
            [
                "-c:v",
                "libx265",
                "-preset",
                "fast",
                "-crf",
                "20",
                "-maxrate",
                bitrate,
                "-bufsize",
                f"{(max_bitrate_mbps * 2).normalize()}M",
                "-x265-params",
                "log-level=error",
                "-pix_fmt",
                "yuv420p",
                "-fps_mode",
                "cfr",
                "-tag:v",
                "hvc1",
                "-movflags",
                "+faststart",
                "-f",
                "mp4",
            ]
        )
    else:
        command.extend(
            [
                "-c:v",
                "ffv1",
                "-level",
                "3",
                "-g",
                "1",
                "-pix_fmt",
                "rgb24",
                "-fps_mode",
                "cfr",
                "-f",
                "matroska",
            ]
        )
    command.extend(["-n", str(output)])
    return command


def _read_exact(handle: Any, byte_count: int) -> bytes:
    chunks: list[bytes] = []
    remaining = byte_count
    while remaining:
        chunk = handle.read(remaining)
        if not chunk:
            break
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def _raw_rgb_decoder_command(
    ffmpeg: str,
    raw_path: Path,
    probe_data: dict[str, Any],
    *,
    video_filter: str | None = None,
) -> list[str]:
    # Frame timing is taken from ffprobe. The pipe still uses passthrough to prohibit
    # ffmpeg from duplicating/dropping source samples, but its rawvideo encoder must use
    # the proven source time base so distinct VFR PTS cannot quantize to duplicate DTS.
    source_time_base = _fraction(
        _video_stream(probe_data).get("time_base"),
        "time_base",
    )
    if (
        source_time_base.numerator > MAX_FFMPEG_RATIONAL_COMPONENT
        or source_time_base.denominator > MAX_FFMPEG_RATIONAL_COMPONENT
    ):
        raise EvidenceError("time_base is outside the bounded ffmpeg rational grammar")
    command = [
        ffmpeg,
        "-v",
        "error",
        "-i",
        str(raw_path),
        "-map",
        "0:v:0",
    ]
    if video_filter is not None:
        if not isinstance(video_filter, str) or not video_filter:
            raise EvidenceError("raw RGB video filter must be a non-empty string")
        command.extend(["-vf", video_filter])
    command.extend(
        [
            "-fps_mode",
            "passthrough",
            "-enc_time_base",
            f"{source_time_base.numerator}:{source_time_base.denominator}",
            "-f",
            "rawvideo",
            "-pix_fmt",
            "rgb24",
            "pipe:1",
        ]
    )
    return command


def normalize_video(
    *,
    raw_path: Path,
    probe_data: dict[str, Any],
    derivative_path: Path,
    sidecar_path: Path,
    framemd5_path: Path,
    collision_directory: Path,
    codec: str = "h264",
    allow_ffv1: bool = False,
    disk_reserve_bytes: int = DEFAULT_DISK_RESERVE_BYTES,
    max_bitrate_mbps: Decimal = DEFAULT_MAX_BITRATE_MBPS,
    ffmpeg_path: str | None = None,
    ffprobe_path: str | None = None,
) -> dict[str, Any]:
    """Create a CFR60 derivative and a complete immutable provenance package."""

    raw_path = Path(raw_path)
    derivative_path = Path(derivative_path)
    sidecar_path = Path(sidecar_path)
    framemd5_path = Path(framemd5_path)
    collision_directory = Path(collision_directory)
    outputs = [derivative_path, sidecar_path, framemd5_path, collision_directory]
    validate_new_output_paths(raw_path, outputs)
    codec_config = choose_derivative_codec(codec, allow_ffv1=allow_ffv1)
    source_report = analyze_probe(raw_path, probe_data)
    frame_pts = extract_frame_pts(probe_data)
    source_duration = _probe_duration(probe_data, frame_pts)
    grid_plan = build_grid_plan(frame_pts, source_duration)
    width = source_report["source"]["width"]
    height = source_report["source"]["height"]
    estimate = estimate_normalization_bytes(
        width=width,
        height=height,
        normalized_frame_count=grid_plan["normalized_frame_count"],
        source_sample_count=grid_plan["source_sample_count"],
        collision_sample_count=grid_plan["collision_sample_count"],
        codec=codec,
        max_bitrate_mbps=max_bitrate_mbps,
    )
    largest_collision_group = max(
        (len(group["source_indices"]) for group in grid_plan["collision_groups"]),
        default=1,
    )
    peak_decode_group_bytes = largest_collision_group * width * height * 3
    if peak_decode_group_bytes > MAX_DECODE_GROUP_BYTES:
        raise EvidenceError("an intra-grid collision group exceeds the bounded decode memory budget")
    estimate["peak_decode_group_bytes"] = peak_decode_group_bytes
    estimate["maximum_decode_group_bytes"] = MAX_DECODE_GROUP_BYTES
    free_bytes = shutil.disk_usage(derivative_path.parent).free
    enforce_storage_budget(
        required_bytes=estimate["required_bytes"],
        free_bytes=free_bytes,
        reserve_bytes=disk_reserve_bytes,
    )

    ffmpeg = ffmpeg_path or shutil.which("ffmpeg")
    if not ffmpeg:
        raise EvidenceError("ffmpeg executable is unavailable")
    frame_size = width * height * 3
    source_hash_before = source_report["source"]["sha256"]

    derivative_partial = _partial_path(derivative_path)
    sidecar_partial = _partial_path(sidecar_path)
    framemd5_partial = _partial_path(framemd5_path)
    collisions_partial = _partial_path(collision_directory)
    os.mkdir(collisions_partial, 0o700)
    partial_files = [derivative_partial, sidecar_partial, framemd5_partial]
    published: list[Path] = []
    decoder: subprocess.Popen[bytes] | None = None
    encoder: subprocess.Popen[bytes] | None = None

    try:
        decoder_command = _raw_rgb_decoder_command(
            ffmpeg,
            raw_path,
            probe_data,
        )
        encoder_command = _encoder_command(
            ffmpeg,
            width=width,
            height=height,
            codec=codec_config,
            max_bitrate_mbps=_decimal(max_bitrate_mbps, "max bitrate Mbps"),
            output=derivative_partial,
        )
        decoder = subprocess.Popen(
            decoder_command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        encoder = subprocess.Popen(
            encoder_command,
            stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
        if decoder.stdout is None or decoder.stderr is None:
            raise EvidenceError("ffmpeg decoder pipes are unavailable")
        if encoder.stdin is None or encoder.stderr is None:
            raise EvidenceError("ffmpeg encoder pipes are unavailable")

        sample_by_index = {
            sample["source_index"]: sample for sample in grid_plan["samples"]
        }
        grid_by_index = {
            frame["grid_index"]: frame for frame in grid_plan["grid_frames"]
        }
        grid_cursor = 0
        previous_frame: bytes | None = None
        previous_source_index: int | None = None

        with framemd5_partial.open("x", encoding="ascii", newline="\n") as framemd5_handle:
            _write_framemd5_header(framemd5_handle, width, height)

            def write_grid_frame(
                frame: bytes,
                grid_index: int,
                source_index: int,
            ) -> None:
                try:
                    encoder.stdin.write(frame)
                except (BrokenPipeError, OSError) as error:
                    raise EvidenceError("ffmpeg encoder stopped before CFR60 completion") from error
                md5 = hashlib.md5(frame, usedforsecurity=False).hexdigest()
                _write_framemd5_line(framemd5_handle, grid_index, len(frame), md5)
                grid_record = grid_by_index[grid_index]
                if grid_record["source_index"] != source_index:
                    raise EvidenceError("internal source-to-grid provenance disagreement")
                grid_record["pre_encode_md5"] = md5

            def write_source_group(target: int, group: list[tuple[int, bytes]]) -> None:
                nonlocal grid_cursor, previous_frame, previous_source_index
                if previous_frame is None and target != 0:
                    raise EvidenceError("first source group does not start at grid zero")
                while grid_cursor < target:
                    if previous_frame is None or previous_source_index is None:
                        raise EvidenceError("cannot duplicate before the first source sample")
                    write_grid_frame(previous_frame, grid_cursor, previous_source_index)
                    grid_cursor += 1

                if len(group) > 1:
                    for source_index, frame in group:
                        name = f"collision-g{target:09d}-s{source_index:09d}.png"
                        png_hash = _write_rgb_png(
                            collisions_partial / name,
                            width,
                            height,
                            frame,
                        )
                        sample_by_index[source_index]["collision_png"] = {
                            "file": name,
                            "sha256": png_hash,
                        }

                selected_source_index, selected_frame = group[-1]
                write_grid_frame(selected_frame, target, selected_source_index)
                previous_frame = selected_frame
                previous_source_index = selected_source_index
                grid_cursor = target + 1

            current_target: int | None = None
            current_group: list[tuple[int, bytes]] = []
            for sample in grid_plan["samples"]:
                frame = _read_exact(decoder.stdout, frame_size)
                if len(frame) != frame_size:
                    raise EvidenceError("ffmpeg decoded fewer frames than ffprobe reported")
                source_index = sample["source_index"]
                sample["decoded_rgb_sha256"] = hashlib.sha256(frame).hexdigest()
                target = sample["target_grid_index"]
                if current_target is None:
                    current_target = target
                elif target != current_target:
                    write_source_group(current_target, current_group)
                    current_target = target
                    current_group = []
                current_group.append((source_index, frame))
            if current_target is not None:
                write_source_group(current_target, current_group)

            while grid_cursor < grid_plan["normalized_frame_count"]:
                if previous_frame is None or previous_source_index is None:
                    raise EvidenceError("normalization ended without a selected source sample")
                write_grid_frame(previous_frame, grid_cursor, previous_source_index)
                grid_cursor += 1

        if _read_exact(decoder.stdout, 1):
            raise EvidenceError("ffmpeg decoded more frames than ffprobe reported")
        decoder.stdout.close()
        decoder_stderr = decoder.stderr.read()
        decoder.stderr.close()
        decoder_returncode = decoder.wait()
        if decoder_returncode != 0:
            raise EvidenceError("ffmpeg failed while decoding the raw source")
        if decoder_stderr:
            raise EvidenceError("ffmpeg emitted a decoder error")

        encoder.stdin.close()
        encoder_stderr = encoder.stderr.read()
        encoder.stderr.close()
        encoder_returncode = encoder.wait()
        if encoder_returncode != 0:
            raise EvidenceError("ffmpeg failed while encoding the CFR60 derivative")
        if encoder_stderr:
            raise EvidenceError("ffmpeg emitted an encoder error")
        if not derivative_partial.is_file() or derivative_partial.stat().st_size == 0:
            raise EvidenceError("ffmpeg did not finalize a non-empty derivative")
        if derivative_partial.stat().st_size > estimate["derivative_upper_bound_bytes"]:
            raise EvidenceError("derivative exceeded its storage-bounded upper estimate")

        source_hash_after = sha256_file(raw_path)
        if source_hash_after != source_hash_before:
            raise EvidenceError("raw source changed during normalization")

        derivative_probe = run_ffprobe(derivative_partial, ffprobe_path=ffprobe_path)
        derivative_report = analyze_probe(derivative_partial, derivative_probe)
        if not derivative_report["source"]["native_60_proven"]:
            raise EvidenceError("normalized derivative did not prove constant 60 fps")
        if (
            derivative_report["source"]["frame_count"]
            != grid_plan["normalized_frame_count"]
        ):
            raise EvidenceError("normalized derivative frame count disagrees with grid plan")

        sidecar = {
            "schema_version": SCHEMA_VERSION,
            "privacy": {
                "contains_paths": False,
                "contains_account_or_message_fields": False,
                "collision_pngs_are_sensitive_visual_evidence": True,
            },
            "source": source_report["source"],
            "raw_integrity": {
                "sha256_before": source_hash_before,
                "sha256_after": source_hash_after,
                "unchanged": True,
                "authoritative": True,
            },
            "normalization": {
                "rate": "60/1",
                "codec": codec_config["name"],
                "lossy": codec_config["lossy"],
                "raw_source_remains_lossless_authority": True,
                "pre_encode_framemd5_required": True,
                "derivative_sha256": derivative_report["source"]["sha256"],
                "frame_count": derivative_report["source"]["frame_count"],
                "duration_seconds": derivative_report["source"]["duration_seconds"],
                "strictly_monotonic_pts": derivative_report["source"][
                    "strictly_monotonic_pts"
                ],
                "native_60_proven_by_ffprobe": derivative_report["source"][
                    "native_60_proven"
                ],
            },
            "storage_preflight": {
                **estimate,
                "free_bytes_at_start": free_bytes,
                "reserved_bytes": disk_reserve_bytes,
                "passed": True,
            },
            "mapping": grid_plan,
        }
        with sidecar_partial.open("x", encoding="utf-8", newline="\n") as handle:
            json.dump(sidecar, handle, indent=2, sort_keys=True, ensure_ascii=True)
            handle.write("\n")

        staged_bytes = sum(path.stat().st_size for path in partial_files)
        staged_bytes += sum(
            path.stat().st_size for path in collisions_partial.iterdir() if path.is_file()
        )
        if staged_bytes > estimate["required_bytes"]:
            raise EvidenceError("evidence package exceeded its storage-bounded estimate")

        _publish_flat_directory_no_overwrite(collisions_partial, collision_directory)
        published.append(collision_directory)
        _publish_file_no_overwrite(derivative_partial, derivative_path)
        published.append(derivative_path)
        _publish_file_no_overwrite(framemd5_partial, framemd5_path)
        published.append(framemd5_path)
        _publish_file_no_overwrite(sidecar_partial, sidecar_path)
        published.append(sidecar_path)

        return {
            "schema_version": SCHEMA_VERSION,
            "source_artifact_id": source_report["source"]["artifact_id"],
            "source_sample_count": grid_plan["source_sample_count"],
            "collision_sample_count": grid_plan["collision_sample_count"],
            "normalized_frame_count": grid_plan["normalized_frame_count"],
            "normalized_rate": "60/1",
            "derivative_codec": codec_config["name"],
            "raw_unchanged": True,
            "final_audit_requires_classifications_and_signposts": True,
        }
    except Exception:
        if encoder is not None and encoder.poll() is None:
            if encoder.stdin is not None:
                try:
                    encoder.stdin.close()
                except OSError:
                    pass
            encoder.kill()
            encoder.wait()
        if decoder is not None and decoder.poll() is None:
            decoder.kill()
            decoder.wait()
        for path in partial_files:
            if path.exists() and path.is_file():
                path.unlink()
        if collisions_partial.exists() and collisions_partial.is_dir():
            shutil.rmtree(collisions_partial)
        for path in reversed(published):
            if path.is_dir():
                shutil.rmtree(path)
            elif path.exists():
                path.unlink()
        raise


def validate_classifications(
    classifications: dict[str, Any],
    source_indices: Iterable[int],
    *,
    calibration_source_indices: Iterable[int] | None = None,
) -> dict[int, dict[str, Any]]:
    if not isinstance(classifications, dict):
        raise EvidenceError("classification JSON root must be an object")
    if set(classifications) != {"schema_version", "samples"}:
        raise EvidenceError("classification JSON has unsupported top-level fields")
    if classifications.get("schema_version") != SCHEMA_VERSION:
        raise EvidenceError("classification schema version is unsupported")
    samples = classifications.get("samples")
    if not isinstance(samples, dict):
        raise EvidenceError("classification samples must be an object")
    expected = {str(index) for index in source_indices}
    if set(samples) != expected:
        raise EvidenceError("classification JSON must classify every source sample exactly once")

    validated: dict[int, dict[str, Any]] = {}
    for raw_index, record in samples.items():
        if not isinstance(record, dict):
            raise EvidenceError("each classification must be an object")
        if set(record) != {
            "visual_state",
            "forbidden_frame",
            "calibration_marker",
        }:
            raise EvidenceError("unsupported classification fields")
        state = record.get("visual_state")
        forbidden = record.get("forbidden_frame")
        calibration_marker = record.get("calibration_marker")
        if state not in VISUAL_STATES:
            raise EvidenceError("classification visual_state is outside the closed enum")
        if not isinstance(forbidden, bool):
            raise EvidenceError("classification forbidden_frame must be boolean")
        if not isinstance(calibration_marker, bool):
            raise EvidenceError("classification calibration_marker must be boolean")
        validated[int(raw_index)] = {
            "visual_state": state,
            "forbidden_frame": forbidden,
            "calibration_marker": calibration_marker,
        }
    if calibration_source_indices is not None:
        expected_markers = set(calibration_source_indices)
        actual_markers = {
            index
            for index, record in validated.items()
            if record["calibration_marker"]
        }
        if actual_markers != expected_markers:
            raise EvidenceError(
                "visual calibration-marker classifications do not match measured markers"
            )
    return validated


def validate_numeric_signpost_export_schema(
    signposts: dict[str, Any],
    *,
    phase_manifest: dict[str, Any],
    require_records: bool,
) -> list[dict[str, Any]]:
    """Validate the app export before any capture-stage publication."""

    base_fields = {
        "schema_version",
        "phase_manifest_sha256",
        "phase_count",
        "records",
    }
    route_fields = {"matrix_route_code", "fixture_scenario"}
    if (
        not isinstance(signposts, dict)
        or frozenset(signposts) not in {
            frozenset(base_fields),
            frozenset(base_fields | route_fields),
        }
    ):
        raise EvidenceError("signpost JSON must use the closed numeric recorder schema")
    if signposts.get("schema_version") != SCHEMA_VERSION:
        raise EvidenceError("signpost schema version is unsupported")
    if not isinstance(phase_manifest, dict) or set(phase_manifest) != {
        "schema_version",
        "phases",
        "sha256",
        "source_sha256",
        "mechanically_derived_from_swift",
    }:
        raise EvidenceError("Swift phase manifest is incomplete")
    if (
        phase_manifest.get("schema_version") != SCHEMA_VERSION
        or phase_manifest.get("mechanically_derived_from_swift") is not True
        or signposts.get("phase_manifest_sha256") != phase_manifest.get("sha256")
    ):
        raise EvidenceError("signpost phase manifest does not match production Swift")
    phases = phase_manifest.get("phases")
    if (
        not isinstance(phases, list)
        or not phases
        or not all(isinstance(phase, str) for phase in phases)
        or len(set(phases)) != len(phases)
    ):
        raise EvidenceError("Swift phase manifest phases are invalid")
    if signposts.get("phase_count") != len(phases):
        raise EvidenceError("numeric signpost phase count is inconsistent")
    records = signposts.get("records")
    if not isinstance(records, list) or (require_records and not records):
        raise EvidenceError("numeric signpost records must use the required array")

    previous_sequence = 0
    previous_uptime_ns: int | None = None
    for record in records:
        if not isinstance(record, dict) or set(record) != {
            "sequence",
            "record_kind_code",
            "phase_code",
            "trace_id",
            "generation",
            "operation_kind_code",
            "purpose_code",
            "terminal_code",
            "uptime_ns",
            "thread_code",
            "counters",
        }:
            raise EvidenceError("numeric signpost record has unsupported fields")
        integer_fields = {
            field: record.get(field)
            for field in (
                "sequence",
                "record_kind_code",
                "phase_code",
                "trace_id",
                "generation",
                "operation_kind_code",
                "purpose_code",
                "terminal_code",
                "uptime_ns",
                "thread_code",
            )
        }
        if any(
            isinstance(value, bool) or not isinstance(value, int)
            for value in integer_fields.values()
        ):
            raise EvidenceError("numeric signpost fields must be integers")
        sequence = integer_fields["sequence"]
        uptime_ns = integer_fields["uptime_ns"]
        if (
            sequence <= previous_sequence
            or sequence > 0xFFFFFFFFFFFFFFFF
            or uptime_ns < 0
            or uptime_ns > 0xFFFFFFFFFFFFFFFF
            or (previous_uptime_ns is not None and uptime_ns < previous_uptime_ns)
        ):
            raise EvidenceError("numeric signpost sequence/uptime order is invalid")
        previous_sequence = sequence
        previous_uptime_ns = uptime_ns
        record_kind_code = integer_fields["record_kind_code"]
        phase_code = integer_fields["phase_code"]
        terminal_code = integer_fields["terminal_code"]
        if record_kind_code not in SIGNPOST_RECORD_KIND_CODES:
            raise EvidenceError("numeric signpost record kind is invalid")
        if phase_code < 1 or phase_code > len(phases):
            raise EvidenceError("numeric signpost phase code is invalid")
        if (
            integer_fields["trace_id"] <= 0
            or integer_fields["trace_id"] > 0xFFFFFFFFFFFFFFFF
            or integer_fields["generation"] <= 0
            or integer_fields["generation"] > 0xFFFFFFFFFFFFFFFF
            or integer_fields["operation_kind_code"] not in SIGNPOST_OPERATION_KIND_CODES
            or integer_fields["purpose_code"] not in SIGNPOST_PURPOSE_CODES
            or terminal_code not in SIGNPOST_TERMINAL_CODES
            or integer_fields["thread_code"] not in SIGNPOST_THREAD_CODES
        ):
            raise EvidenceError("numeric signpost context or terminal code is invalid")
        if (record_kind_code == 3) != (terminal_code != 0):
            raise EvidenceError("numeric signpost terminal code does not match record kind")
        counters = record.get("counters")
        if not isinstance(counters, list) or len(counters) > 4:
            raise EvidenceError("numeric signpost counters exceed the closed bound")
        counter_codes: list[int] = []
        for counter in counters:
            if not isinstance(counter, dict) or set(counter) != {"code", "value"}:
                raise EvidenceError("numeric signpost counter has unsupported fields")
            code = counter.get("code")
            counter_value = counter.get("value")
            if (
                isinstance(code, bool)
                or not isinstance(code, int)
                or code not in SIGNPOST_COUNTER_CODES
                or isinstance(counter_value, bool)
                or not isinstance(counter_value, int)
                or counter_value < -(2**63)
                or counter_value > 2**63 - 1
            ):
                raise EvidenceError("numeric signpost counter is invalid")
            counter_codes.append(code)
        if counter_codes != sorted(set(counter_codes)):
            raise EvidenceError("numeric signpost counter codes must be unique and ordered")
    return records


def correlate_signposts(
    signposts: dict[str, Any],
    *,
    calibration: dict[str, Any],
    phase_manifest: dict[str, Any],
    source_pts: Sequence[Decimal],
    source_duration: Decimal | None = None,
) -> list[dict[str, Any]]:
    validate_numeric_signpost_export_schema(
        signposts,
        phase_manifest=phase_manifest,
        require_records=True,
    )
    base_fields = {
        "schema_version",
        "phase_manifest_sha256",
        "phase_count",
        "records",
    }
    route_fields = {"matrix_route_code", "fixture_scenario"}
    if (
        not isinstance(signposts, dict)
        or frozenset(signposts) not in {
            frozenset(base_fields),
            frozenset(base_fields | route_fields),
        }
    ):
        raise EvidenceError(
            "signpost JSON must use the closed numeric recorder schema"
        )
    if signposts.get("schema_version") != SCHEMA_VERSION:
        raise EvidenceError("signpost schema version is unsupported")
    if not isinstance(phase_manifest, dict) or set(phase_manifest) != {
        "schema_version",
        "phases",
        "sha256",
        "source_sha256",
        "mechanically_derived_from_swift",
    }:
        raise EvidenceError("Swift phase manifest is incomplete")
    if (
        phase_manifest.get("schema_version") != SCHEMA_VERSION
        or phase_manifest.get("mechanically_derived_from_swift") is not True
        or signposts.get("phase_manifest_sha256") != phase_manifest.get("sha256")
    ):
        raise EvidenceError("signpost phase manifest does not match production Swift")
    phases = phase_manifest.get("phases")
    if (
        not isinstance(phases, list)
        or not phases
        or not all(isinstance(phase, str) for phase in phases)
        or len(set(phases)) != len(phases)
    ):
        raise EvidenceError("Swift phase manifest phases are invalid")
    if signposts.get("phase_count") != len(phases):
        raise EvidenceError("numeric signpost phase count is inconsistent")
    records = signposts.get("records")
    if not isinstance(records, list) or not records:
        raise EvidenceError("numeric signpost records must be a non-empty array")
    if not source_pts:
        raise EvidenceError("signpost correlation requires source PTS")
    clock_mapping, intercept, slope = _clock_fit(calibration, source_pts)
    first_source_pts = source_pts[0]
    normalized_source_pts = [pts - first_source_pts for pts in source_pts]
    correlation_duration = (
        _decimal(source_duration, "source duration")
        if source_duration is not None
        else normalized_source_pts[-1]
    )
    if correlation_duration < normalized_source_pts[-1]:
        raise EvidenceError("signpost correlation duration is shorter than source PTS")
    uncertainty = _decimal(
        clock_mapping["bounded_uncertainty_seconds"],
        "clock mapping bounded uncertainty",
    )

    result: list[dict[str, Any]] = []
    previous_sequence = 0
    previous_uptime_ns: int | None = None
    for record in records:
        if not isinstance(record, dict) or set(record) != {
            "sequence",
            "record_kind_code",
            "phase_code",
            "trace_id",
            "generation",
            "operation_kind_code",
            "purpose_code",
            "terminal_code",
            "uptime_ns",
            "thread_code",
            "counters",
        }:
            raise EvidenceError("numeric signpost record has unsupported fields")
        integer_fields = {
            field: record.get(field)
            for field in (
                "sequence",
                "record_kind_code",
                "phase_code",
                "trace_id",
                "generation",
                "operation_kind_code",
                "purpose_code",
                "terminal_code",
                "uptime_ns",
                "thread_code",
            )
        }
        if any(isinstance(value, bool) or not isinstance(value, int) for value in integer_fields.values()):
            raise EvidenceError("numeric signpost fields must be integers")
        sequence = integer_fields["sequence"]
        uptime_ns = integer_fields["uptime_ns"]
        if (
            sequence <= previous_sequence
            or sequence > 0xFFFFFFFFFFFFFFFF
            or uptime_ns < 0
            or uptime_ns > 0xFFFFFFFFFFFFFFFF
            or (previous_uptime_ns is not None and uptime_ns < previous_uptime_ns)
        ):
            raise EvidenceError("numeric signpost sequence/uptime order is invalid")
        previous_sequence = sequence
        previous_uptime_ns = uptime_ns
        record_kind_code = integer_fields["record_kind_code"]
        phase_code = integer_fields["phase_code"]
        terminal_code = integer_fields["terminal_code"]
        if record_kind_code not in SIGNPOST_RECORD_KIND_CODES:
            raise EvidenceError("numeric signpost record kind is invalid")
        if phase_code < 1 or phase_code > len(phases):
            raise EvidenceError("numeric signpost phase code is invalid")
        if (
            integer_fields["trace_id"] <= 0
            or integer_fields["trace_id"] > 0xFFFFFFFFFFFFFFFF
            or integer_fields["generation"] <= 0
            or integer_fields["generation"] > 0xFFFFFFFFFFFFFFFF
            or integer_fields["operation_kind_code"] not in SIGNPOST_OPERATION_KIND_CODES
            or integer_fields["purpose_code"] not in SIGNPOST_PURPOSE_CODES
            or terminal_code not in SIGNPOST_TERMINAL_CODES
            or integer_fields["thread_code"] not in SIGNPOST_THREAD_CODES
        ):
            raise EvidenceError("numeric signpost context or terminal code is invalid")
        if (record_kind_code == 3) != (terminal_code != 0):
            raise EvidenceError("numeric signpost terminal code does not match record kind")
        counters = record.get("counters")
        if not isinstance(counters, list) or len(counters) > 4:
            raise EvidenceError("numeric signpost counters exceed the closed bound")
        counter_codes: list[int] = []
        validated_counters: list[dict[str, int]] = []
        for counter in counters:
            if not isinstance(counter, dict) or set(counter) != {"code", "value"}:
                raise EvidenceError("numeric signpost counter has unsupported fields")
            code = counter.get("code")
            value = counter.get("value")
            if (
                isinstance(code, bool)
                or not isinstance(code, int)
                or code not in SIGNPOST_COUNTER_CODES
                or isinstance(value, bool)
                or not isinstance(value, int)
                or value < -(2**63)
                or value > 2**63 - 1
            ):
                raise EvidenceError("numeric signpost counter is invalid")
            counter_codes.append(code)
            validated_counters.append({"code": code, "value": value})
        if counter_codes != sorted(set(counter_codes)):
            raise EvidenceError("numeric signpost counter codes must be unique and ordered")
        phase = phases[phase_code - 1]
        monotonic = _monotonic_seconds(
            uptime_ns,
            "numeric signpost uptime",
        )
        relative = (monotonic - intercept) / slope
        if relative < -uncertainty or relative > correlation_duration + uncertainty:
            raise EvidenceError("signpost event falls outside the calibrated video interval")
        if relative < 0:
            relative = Decimal(0)
        elif relative >= correlation_duration:
            relative = max(Decimal(0), correlation_duration - GRID_EPSILON)
        nearest_index = min(
            range(len(normalized_source_pts)),
            key=lambda index: (abs(normalized_source_pts[index] - relative), index),
        )
        grid_index = int(
            (relative * GRID_RATE - GRID_EPSILON).to_integral_value(
                rounding=ROUND_CEILING
            )
        )
        result.append(
            {
                "sequence": sequence,
                "record_kind_code": record_kind_code,
                "phase_code": phase_code,
                "phase": phase,
                "trace_id": integer_fields["trace_id"],
                "generation": integer_fields["generation"],
                "operation_kind_code": integer_fields["operation_kind_code"],
                "purpose_code": integer_fields["purpose_code"],
                "terminal_code": terminal_code,
                "thread_code": integer_fields["thread_code"],
                "counters": validated_counters,
                "relative_video_seconds": _seconds(relative),
                "nearest_source_index": nearest_index,
                "nearest_source_pts_seconds": _seconds(normalized_source_pts[nearest_index]),
                "normalized_grid_index": grid_index,
                "clock_uncertainty_seconds": clock_mapping[
                    "bounded_uncertainty_seconds"
                ],
            }
        )
    return result


def _load_json(path: Path, label: str) -> dict[str, Any]:
    _require_regular_file(path, label)
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise EvidenceError(f"{label} must contain valid UTF-8 JSON") from error
    if not isinstance(value, dict):
        raise EvidenceError(f"{label} JSON root must be an object")
    return value


def _framemd5_hashes(path: Path) -> list[str]:
    _require_regular_file(path, "pre-encode framemd5")
    hashes: list[str] = []
    for line in path.read_text(encoding="ascii").splitlines():
        if not line or line.startswith("#"):
            continue
        fields = [field.strip() for field in line.split(",")]
        if len(fields) != 6 or not re.fullmatch(r"[0-9a-f]{32}", fields[-1]):
            raise EvidenceError("pre-encode framemd5 contains an invalid frame record")
        hashes.append(fields[-1])
    if not hashes:
        raise EvidenceError("pre-encode framemd5 has no frame records")
    return hashes


def _recompute_grid_evidence(
    *,
    raw_path: Path,
    probe_data: dict[str, Any],
    expected_plan: dict[str, Any],
    ffmpeg_path: str | None = None,
) -> dict[str, Any]:
    """Tie sidecar hashes and framemd5 back to decoded bytes from immutable raw."""

    stream = _video_stream(probe_data)
    width = stream.get("width")
    height = stream.get("height")
    if not isinstance(width, int) or not isinstance(height, int):
        raise EvidenceError("ffprobe dimensions are incomplete")
    ffmpeg = ffmpeg_path or shutil.which("ffmpeg")
    if not ffmpeg:
        raise EvidenceError("ffmpeg executable is unavailable")
    frame_size = width * height * 3
    command = _raw_rgb_decoder_command(
        ffmpeg,
        raw_path,
        probe_data,
    )
    decoder = subprocess.Popen(
        command,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if decoder.stdout is None or decoder.stderr is None:
        decoder.kill()
        decoder.wait()
        raise EvidenceError("ffmpeg validation decoder pipes are unavailable")

    source_sha256: dict[int, str] = {}
    source_md5: dict[int, str] = {}
    collision_png_sha256: dict[int, str] = {}
    grid_md5: list[str] = []
    grid_cursor = 0
    previous_source_index: int | None = None
    current_target: int | None = None
    current_group: list[tuple[int, bytes]] = []

    def flush_group(target: int, group: list[tuple[int, bytes]]) -> None:
        nonlocal grid_cursor, previous_source_index
        if previous_source_index is None and target != 0:
            raise EvidenceError("recomputed grid does not begin at zero")
        while grid_cursor < target:
            if previous_source_index is None:
                raise EvidenceError("recomputed grid duplicates before its first sample")
            grid_md5.append(source_md5[previous_source_index])
            grid_cursor += 1
        if len(group) > 1:
            for source_index, frame in group:
                collision_png_sha256[source_index] = hashlib.sha256(
                    _rgb_png_bytes(width, height, frame)
                ).hexdigest()
        selected_source_index, selected_frame = group[-1]
        selected_md5 = hashlib.md5(
            selected_frame,
            usedforsecurity=False,
        ).hexdigest()
        source_md5[selected_source_index] = selected_md5
        grid_md5.append(selected_md5)
        previous_source_index = selected_source_index
        grid_cursor = target + 1

    try:
        for sample in expected_plan["samples"]:
            frame = _read_exact(decoder.stdout, frame_size)
            if len(frame) != frame_size:
                raise EvidenceError("validation decode produced fewer source samples than ffprobe")
            source_index = sample["source_index"]
            source_sha256[source_index] = hashlib.sha256(frame).hexdigest()
            source_md5[source_index] = hashlib.md5(
                frame,
                usedforsecurity=False,
            ).hexdigest()
            target = sample["target_grid_index"]
            if current_target is None:
                current_target = target
            elif target != current_target:
                flush_group(current_target, current_group)
                current_target = target
                current_group = []
            current_group.append((source_index, frame))
        if current_target is not None:
            flush_group(current_target, current_group)
        while grid_cursor < expected_plan["normalized_frame_count"]:
            if previous_source_index is None:
                raise EvidenceError("recomputed grid ended without a source sample")
            grid_md5.append(source_md5[previous_source_index])
            grid_cursor += 1
        if _read_exact(decoder.stdout, 1):
            raise EvidenceError("validation decode produced more source samples than ffprobe")
        decoder.stdout.close()
        stderr = decoder.stderr.read()
        decoder.stderr.close()
        returncode = decoder.wait()
        if returncode != 0 or stderr:
            raise EvidenceError("ffmpeg failed while independently validating raw frames")
    except Exception:
        if decoder.poll() is None:
            decoder.kill()
            decoder.wait()
        try:
            decoder.stdout.close()
        except OSError:
            pass
        try:
            decoder.stderr.close()
        except OSError:
            pass
        raise

    return {
        "source_sha256": source_sha256,
        "grid_md5": grid_md5,
        "collision_png_sha256": collision_png_sha256,
    }


def validate_capture_receipt_prebuilt_binary_provenance(
    capture_receipt: Mapping[str, Any],
) -> dict[str, Any]:
    if (
        capture_receipt.get("prebuilt_binary_provenance_closed") is not True
        or capture_receipt.get("prebuilt_destination_architecture") != "arm64"
        or capture_receipt.get("prebuilt_xctestrun_selection_policy")
        != "locked_simulator_sdk_arm64"
        or isinstance(capture_receipt.get("prebuilt_xctestrun_count"), bool)
        or not isinstance(capture_receipt.get("prebuilt_xctestrun_count"), int)
        or capture_receipt.get("prebuilt_xctestrun_count") != 1
        or capture_receipt.get("prebuilt_referenced_product_count") != 4
        or capture_receipt.get("prebuilt_runnable_executable_count") != 4
        or isinstance(
            capture_receipt.get("prebuilt_referenced_regular_file_count"), bool
        )
        or not isinstance(
            capture_receipt.get("prebuilt_referenced_regular_file_count"), int
        )
        or capture_receipt.get("prebuilt_referenced_regular_file_count") <= 0
        or capture_receipt.get("prebuilt_referenced_regular_file_count")
        > MAX_PREBUILT_REFERENCED_REGULAR_FILES
        or isinstance(
            capture_receipt.get("prebuilt_referenced_regular_file_byte_count"),
            bool,
        )
        or not isinstance(
            capture_receipt.get("prebuilt_referenced_regular_file_byte_count"),
            int,
        )
        or capture_receipt.get("prebuilt_referenced_regular_file_byte_count") <= 0
        or capture_receipt.get("prebuilt_referenced_regular_file_byte_count")
        > MAX_PREBUILT_REFERENCED_BYTES
        or not re.fullmatch(
            r"[0-9a-f]{64}",
            str(
                capture_receipt.get(
                    "prebuilt_referenced_files_manifest_sha256"
                )
            ),
        )
    ):
        raise EvidenceError(
            "capture receipt does not close prebuilt binary provenance"
        )
    return {
        "binary_provenance_closed": True,
        "destination_architecture": "arm64",
        "xctestrun_count": 1,
        "referenced_product_count": 4,
        "runnable_executable_count": 4,
        "referenced_regular_file_count": capture_receipt[
            "prebuilt_referenced_regular_file_count"
        ],
        "referenced_regular_file_byte_count": capture_receipt[
            "prebuilt_referenced_regular_file_byte_count"
        ],
        "referenced_files_manifest_sha256": capture_receipt[
            "prebuilt_referenced_files_manifest_sha256"
        ],
        "contains_paths": False,
    }


def validate_evidence_package(
    *,
    raw_path: Path,
    raw_probe_data: dict[str, Any],
    derivative_path: Path,
    derivative_probe_data: dict[str, Any],
    sidecar_path: Path,
    framemd5_path: Path,
    collision_directory: Path,
    classifications_path: Path,
    signposts_path: Path,
    marker_events_path: Path,
    calibration_path: Path,
    test_log_path: Path,
    capture_receipt_path: Path,
    signpost_swift_path: Path = DEFAULT_SIGNPOST_SWIFT_PATH,
    expected_artifact_manifest: dict[str, Any] | None = None,
    ffmpeg_path: str | None = None,
) -> dict[str, Any]:
    """Validate an immutable normalization package and closed-enum visual audit."""

    sidecar_path = Path(sidecar_path)
    classifications_path = Path(classifications_path)
    signposts_path = Path(signposts_path)
    marker_events_path = Path(marker_events_path)
    calibration_path = Path(calibration_path)
    test_log_path = Path(test_log_path)
    capture_receipt_path = Path(capture_receipt_path)
    sidecar = _load_json(sidecar_path, "normalization sidecar")
    classifications = _load_json(classifications_path, "classifications")
    signposts = _load_json(signposts_path, "signposts")
    marker_events = _load_json(marker_events_path, "marker-event export")
    calibration = _load_json(calibration_path, "clock calibration")
    capture_receipt = _load_json(capture_receipt_path, "capture receipt")
    _require_regular_file(test_log_path, "bounded captured test log")
    if test_log_path.stat().st_size > MAX_CAPTURE_LOG_BYTES:
        raise EvidenceError("captured test log exceeds its closed byte bound")
    test_log_bytes = test_log_path.read_bytes()
    _validate_privacy_safe_capture_log(test_log_bytes)
    phase_manifest = load_signpost_phase_manifest(signpost_swift_path)
    validate_marker_events(marker_events)

    if set(sidecar) != {
        "schema_version",
        "privacy",
        "source",
        "raw_integrity",
        "normalization",
        "storage_preflight",
        "mapping",
    }:
        raise EvidenceError("normalization sidecar has unsupported top-level fields")
    if sidecar.get("schema_version") != SCHEMA_VERSION:
        raise EvidenceError("normalization sidecar schema version is unsupported")
    mapping = sidecar.get("mapping")
    source = sidecar.get("source")
    normalized = sidecar.get("normalization")
    if not all(isinstance(value, dict) for value in (mapping, source, normalized)):
        raise EvidenceError("normalization sidecar is incomplete")

    raw_report = analyze_probe(Path(raw_path), raw_probe_data)
    derivative_report = analyze_probe(Path(derivative_path), derivative_probe_data)
    if raw_report["source"]["sha256"] != source.get("sha256"):
        raise EvidenceError("raw hash does not match normalization sidecar")
    if derivative_report["source"]["sha256"] != normalized.get("derivative_sha256"):
        raise EvidenceError("derivative hash does not match normalization sidecar")
    if not derivative_report["source"]["native_60_proven"]:
        raise EvidenceError("derivative ffprobe JSON does not prove constant 60 fps")
    raw_integrity = sidecar.get("raw_integrity")
    if (
        not isinstance(raw_integrity, dict)
        or raw_integrity.get("sha256_before") != raw_report["source"]["sha256"]
        or raw_integrity.get("sha256_after") != raw_report["source"]["sha256"]
        or raw_integrity.get("unchanged") is not True
        or raw_integrity.get("authoritative") is not True
    ):
        raise EvidenceError("raw before/after integrity record is incomplete")
    if (
        normalized.get("rate") != "60/1"
        or normalized.get("raw_source_remains_lossless_authority") is not True
        or normalized.get("pre_encode_framemd5_required") is not True
        or normalized.get("native_60_proven_by_ffprobe") is not True
        or normalized.get("codec") not in {"h264", "hevc", "ffv1"}
        or not isinstance(normalized.get("lossy"), bool)
    ):
        raise EvidenceError("normalization contract fields are incomplete")

    raw_frame_pts = extract_frame_pts(raw_probe_data)
    expected_mapping = build_grid_plan(
        raw_frame_pts,
        _probe_duration(raw_probe_data, raw_frame_pts),
    )

    samples = mapping.get("samples")
    grid_frames = mapping.get("grid_frames")
    collision_groups = mapping.get("collision_groups")
    if not isinstance(samples, list) or not isinstance(grid_frames, list) or not isinstance(collision_groups, list):
        raise EvidenceError("normalization mapping arrays are incomplete")
    source_indices = [sample.get("source_index") for sample in samples if isinstance(sample, dict)]
    if source_indices != list(range(len(samples))):
        raise EvidenceError("source mapping indices are not complete and ordered")
    if mapping.get("mapped_source_sample_count") != len(samples):
        raise EvidenceError("source mapping count is incomplete")
    if derivative_report["source"]["frame_count"] != len(grid_frames):
        raise EvidenceError("grid mapping count disagrees with derivative")
    for field in (
        "policy",
        "grid_rate",
        "grid_interval_seconds",
        "source_sample_count",
        "mapped_source_sample_count",
        "normalized_frame_count",
        "collision_group_count",
        "collision_sample_count",
        "intra_grid_hidden_sample_count",
        "collision_groups",
    ):
        if mapping.get(field) != expected_mapping[field]:
            raise EvidenceError("source-to-grid mapping disagrees with raw PTS")
    for actual_sample, expected_sample in zip(samples, expected_mapping["samples"]):
        if not isinstance(actual_sample, dict):
            raise EvidenceError("source sample mapping must be an object")
        for field, expected_value in expected_sample.items():
            if actual_sample.get(field) != expected_value:
                raise EvidenceError("source sample mapping disagrees with raw PTS")
        if not re.fullmatch(r"[0-9a-f]{64}", str(actual_sample.get("decoded_rgb_sha256"))):
            raise EvidenceError("source sample decoded RGB hash is missing")
    for actual_frame, expected_frame in zip(grid_frames, expected_mapping["grid_frames"]):
        if not isinstance(actual_frame, dict):
            raise EvidenceError("grid frame mapping must be an object")
        for field, expected_value in expected_frame.items():
            if actual_frame.get(field) != expected_value:
                raise EvidenceError("grid frame provenance disagrees with raw PTS")

    hashes = _framemd5_hashes(Path(framemd5_path))
    if len(hashes) != len(grid_frames):
        raise EvidenceError("pre-encode framemd5 count disagrees with grid mapping")
    for index, (frame, digest) in enumerate(zip(grid_frames, hashes)):
        if not isinstance(frame, dict) or frame.get("grid_index") != index:
            raise EvidenceError("grid mapping indices are not complete and ordered")
        if frame.get("pre_encode_md5") != digest:
            raise EvidenceError("pre-encode framemd5 disagrees with grid provenance")
        if frame.get("provenance") not in {
            "source_sample",
            "duplicate_of_source_sample",
        }:
            raise EvidenceError("grid frame provenance is unsupported")

    collision_directory = Path(collision_directory)
    if not collision_directory.is_dir():
        raise EvidenceError("collision PNG directory is missing")
    collision_indices = {
        index
        for group in expected_mapping["collision_groups"]
        for index in group["source_indices"]
    }
    largest_collision_group = max(
        (len(group["source_indices"]) for group in expected_mapping["collision_groups"]),
        default=1,
    )
    validation_decode_bytes = (
        largest_collision_group
        * raw_report["source"]["width"]
        * raw_report["source"]["height"]
        * 3
    )
    if validation_decode_bytes > MAX_DECODE_GROUP_BYTES:
        raise EvidenceError("validation collision group exceeds the decode memory budget")

    recomputed = _recompute_grid_evidence(
        raw_path=Path(raw_path),
        probe_data=raw_probe_data,
        expected_plan=expected_mapping,
        ffmpeg_path=ffmpeg_path,
    )
    if recomputed["grid_md5"] != hashes:
        raise EvidenceError("pre-encode framemd5 does not match independently decoded raw")
    for source_index, sample in enumerate(samples):
        if sample.get("decoded_rgb_sha256") != recomputed["source_sha256"][source_index]:
            raise EvidenceError("source sample hash does not match independently decoded raw")

    expected_collision_files: set[str] = set()
    for source_index in collision_indices:
        sample = samples[source_index]
        png = sample.get("collision_png")
        if not isinstance(png, dict) or set(png) != {"file", "sha256"}:
            raise EvidenceError("each collision sample must have a lossless PNG record")
        filename = png["file"]
        if not isinstance(filename, str) or Path(filename).name != filename:
            raise EvidenceError("collision PNG filename must be local and relative")
        expected_filename = (
            f"collision-g{sample['target_grid_index']:09d}-"
            f"s{source_index:09d}.png"
        )
        if filename != expected_filename:
            raise EvidenceError("collision PNG filename is outside the numeric closed grammar")
        png_path = collision_directory / filename
        expected_collision_files.add(filename)
        if (
            png.get("sha256")
            != recomputed["collision_png_sha256"].get(source_index)
            or sha256_file(png_path) != png.get("sha256")
        ):
            raise EvidenceError("collision PNG hash mismatch")
    actual_collision_files = {
        path.name
        for path in collision_directory.iterdir()
        if path.is_file() and not path.is_symlink()
    }
    if actual_collision_files != expected_collision_files or any(
        not path.is_file() or path.is_symlink() for path in collision_directory.iterdir()
    ):
        raise EvidenceError("collision PNG directory contains missing or unexpected artifacts")

    independently_derived_calibration = derive_video_calibration(
        raw_path=Path(raw_path),
        probe_data=raw_probe_data,
        marker_events_path=marker_events_path,
        signpost_swift_path=signpost_swift_path,
        ffmpeg_path=ffmpeg_path,
    )
    if independently_derived_calibration != calibration:
        raise EvidenceError(
            "clock calibration does not exactly match offline raw-video detection"
        )
    validate_calibration_bindings(
        calibration,
        raw_video_sha256=raw_report["source"]["sha256"],
        marker_event_sha256=sha256_file(marker_events_path),
        phase_manifest_sha256=phase_manifest["sha256"],
    )
    clock_mapping = derive_clock_mapping(calibration, raw_frame_pts)
    validated_classifications = validate_classifications(
        classifications,
        source_indices,
        calibration_source_indices=clock_mapping["marker_source_indices"],
    )
    validate_exported_route_binding(
        signposts,
        expected_test_preflight=capture_receipt,
    )
    correlated_signposts = correlate_signposts(
        signposts,
        calibration=calibration,
        phase_manifest=phase_manifest,
        source_pts=raw_frame_pts,
        source_duration=_probe_duration(raw_probe_data, raw_frame_pts),
    )
    if any(
        event["normalized_grid_index"] < 0
        or event["normalized_grid_index"] >= len(grid_frames)
        for event in correlated_signposts
    ):
        raise EvidenceError("a correlated signpost falls outside the normalized video")
    forbidden_indices = [
        index
        for index, classification in validated_classifications.items()
        if classification["forbidden_frame"]
        or classification["visual_state"] == "forbidden"
    ]
    first_state_locations: dict[str, dict[str, Any]] = {}
    for sample in samples:
        index = sample["source_index"]
        state = validated_classifications[index]["visual_state"]
        first_state_locations.setdefault(
            state,
            {
                "source_index": index,
                "source_pts_seconds": sample["pts_seconds"],
                "normalized_grid_index": sample["target_grid_index"],
            },
        )

    if not isinstance(capture_receipt, dict) or set(capture_receipt) != {
        "schema_version",
        "terminal",
        "capture_finalized",
        "raw_sha256",
        "raw_byte_count",
        "test_log",
        "capture_command_sha256",
        "test_command_sha256",
        "test_without_building",
        "no_build_test_command_sha256",
        "prebuilt_build_receipt_sha256",
        "prebuilt_build_command_sha256",
        "prebuilt_build_products_manifest_sha256",
        "prebuilt_binary_provenance_closed",
        "prebuilt_destination_architecture",
        "prebuilt_xctestrun_selection_policy",
        "prebuilt_xctestrun_count",
        "prebuilt_referenced_product_count",
        "prebuilt_runnable_executable_count",
        "prebuilt_referenced_regular_file_count",
        "prebuilt_referenced_regular_file_byte_count",
        "prebuilt_referenced_files_manifest_sha256",
        "capture_backend",
        "only_locked_simulator_booted",
        "simulator_udid",
        "window_owner_application",
        "window_snapshot_sha256",
        "window_geometry",
        "window_measurement_monotonic_nanoseconds",
        "capture_spawn_before_monotonic_nanoseconds",
        "capture_spawn_after_monotonic_nanoseconds",
        "test_profile",
        "fixture_bundle_identifier",
        "selector_count",
        "test_selector",
        "matrix_route_code",
        "fixture_scenario",
        "parallel_testing_disabled",
        "signpost_export_sha256",
        "marker_event_export_sha256",
        "contains_paths",
    }:
        raise EvidenceError("capture receipt uses an unsupported schema")
    validate_capture_receipt_prebuilt_binary_provenance(capture_receipt)
    if (
        capture_receipt.get("schema_version") != SCHEMA_VERSION
        or capture_receipt.get("terminal") != "success"
        or capture_receipt.get("capture_finalized") is not True
        or capture_receipt.get("raw_sha256") != raw_report["source"]["sha256"]
        or capture_receipt.get("raw_byte_count") != Path(raw_path).stat().st_size
        or capture_receipt.get("signpost_export_sha256") != sha256_file(signposts_path)
        or capture_receipt.get("marker_event_export_sha256") != sha256_file(marker_events_path)
        or capture_receipt.get("contains_paths") is not False
        or capture_receipt.get("capture_backend") != "native_window"
        or capture_receipt.get("only_locked_simulator_booted") is not True
        or capture_receipt.get("simulator_udid") != LOCKED_SIMULATOR_ID
        or capture_receipt.get("window_owner_application") != "Simulator"
        or capture_receipt.get("test_profile")
        != "isolated_chat_performance_fixture"
        or capture_receipt.get("fixture_bundle_identifier")
        != "xabber.ios.codex-chat-performance"
        or capture_receipt.get("parallel_testing_disabled") is not True
        or capture_receipt.get("selector_count") != 1
        or not re.fullmatch(
            r"[0-9a-f]{64}", str(capture_receipt.get("window_snapshot_sha256"))
        )
        or not re.fullmatch(
            r"[0-9a-f]{64}", str(capture_receipt.get("capture_command_sha256"))
        )
        or not re.fullmatch(
            r"[0-9a-f]{64}", str(capture_receipt.get("test_command_sha256"))
        )
        or capture_receipt.get("test_without_building") is not True
        or capture_receipt.get("no_build_test_command_sha256")
        != capture_receipt.get("test_command_sha256")
        or not re.fullmatch(
            r"[0-9a-f]{64}",
            str(capture_receipt.get("prebuilt_build_receipt_sha256")),
        )
        or not re.fullmatch(
            r"[0-9a-f]{64}",
            str(capture_receipt.get("prebuilt_build_command_sha256")),
        )
        or not re.fullmatch(
            r"[0-9a-f]{64}",
            str(capture_receipt.get("prebuilt_build_products_manifest_sha256")),
        )
    ):
        raise EvidenceError("capture receipt does not close the successful capture")
    validate_capture_receipt_window_geometry(capture_receipt, raw_report)
    route_binding = _closed_route_binding(capture_receipt)
    capture_timing = [
        capture_receipt.get("window_measurement_monotonic_nanoseconds"),
        capture_receipt.get("capture_spawn_before_monotonic_nanoseconds"),
        capture_receipt.get("capture_spawn_after_monotonic_nanoseconds"),
    ]
    if (
        any(
            isinstance(value, bool)
            or not isinstance(value, int)
            or value < 0
            for value in capture_timing
        )
        or capture_timing != sorted(capture_timing)
    ):
        raise EvidenceError("capture receipt window-to-recorder timing is incomplete")
    receipt_log = capture_receipt.get("test_log")
    if (
        not isinstance(receipt_log, dict)
        or set(receipt_log) != {
            "published_byte_count",
            "collected_raw_byte_count",
            "observed_raw_byte_count",
            "bounded_at_bytes",
            "raw_collection_truncated",
            "published_log_bounded",
            "truncated",
            "published_log_sha256",
            "privacy_redaction_applied",
        }
        or receipt_log.get("published_byte_count") != len(test_log_bytes)
        or receipt_log.get("bounded_at_bytes") != MAX_CAPTURE_LOG_BYTES
        or receipt_log.get("privacy_redaction_applied") is not True
        or isinstance(receipt_log.get("collected_raw_byte_count"), bool)
        or not isinstance(receipt_log.get("collected_raw_byte_count"), int)
        or receipt_log.get("collected_raw_byte_count") < 0
        or receipt_log.get("collected_raw_byte_count") > MAX_CAPTURE_LOG_BYTES
        or isinstance(receipt_log.get("observed_raw_byte_count"), bool)
        or not isinstance(receipt_log.get("observed_raw_byte_count"), int)
        or receipt_log.get("observed_raw_byte_count")
        < receipt_log.get("collected_raw_byte_count")
        or not isinstance(receipt_log.get("raw_collection_truncated"), bool)
        or receipt_log.get("raw_collection_truncated")
        != (
            receipt_log.get("observed_raw_byte_count")
            > receipt_log.get("collected_raw_byte_count")
        )
        or not isinstance(receipt_log.get("published_log_bounded"), bool)
        or not isinstance(receipt_log.get("truncated"), bool)
        or receipt_log.get("truncated")
        != (
            receipt_log.get("raw_collection_truncated")
            or receipt_log.get("published_log_bounded")
        )
        or receipt_log.get("published_log_sha256")
        != hashlib.sha256(test_log_bytes).hexdigest()
    ):
        raise EvidenceError("capture receipt test-log provenance is incomplete")

    collision_files = [collision_directory / name for name in sorted(expected_collision_files)]
    authorities = {
        "raw": Path(raw_path),
        "derivative": Path(derivative_path),
        "sidecar": sidecar_path,
        "framemd5": Path(framemd5_path),
        "classifications": classifications_path,
        "signposts": signposts_path,
        "marker_events": marker_events_path,
        "calibration": calibration_path,
        "test_log": test_log_path,
        "capture_receipt": capture_receipt_path,
    }
    artifact_manifest = build_artifact_manifest(
        authorities,
        collision_files=collision_files,
        phase_manifest_sha256=phase_manifest["sha256"],
        route_binding=route_binding,
    )
    if expected_artifact_manifest is not None:
        verify_artifact_manifest(
            expected_artifact_manifest,
            authorities,
            collision_files=collision_files,
            phase_manifest_sha256=phase_manifest["sha256"],
            route_binding=route_binding,
        )

    final_status = (
        "fail_forbidden_frames"
        if forbidden_indices
        else "pass"
        if expected_artifact_manifest is not None
        else "manifest_created_requires_revalidation"
    )
    return {
        "schema_version": SCHEMA_VERSION,
        "status": final_status,
        "privacy": {
            "contains_paths": False,
            "contains_account_or_message_fields": False,
            "captured_log_forbidden_field_scan_passed": True,
            "classification_schema_is_closed": True,
            "signpost_schema_is_closed": True,
            "clock_origin_is_measured": True,
            "artifact_manifest_is_complete": True,
            "artifact_manifest_revalidated": expected_artifact_manifest is not None,
        },
        "source": raw_report["source"],
        "normalized": {
            "artifact_id": derivative_report["source"]["artifact_id"],
            "sha256": derivative_report["source"]["sha256"],
            "duration_seconds": derivative_report["source"]["duration_seconds"],
            "frame_count": derivative_report["source"]["frame_count"],
            "rate": "60/1",
            "strictly_monotonic_pts": True,
            "raw_source_remains_authority": True,
        },
        "mapping_summary": {
            "source_sample_count": len(samples),
            "mapped_source_sample_count": mapping.get("mapped_source_sample_count"),
            "normalized_frame_count": len(grid_frames),
            "source_grid_frames": sum(
                frame["provenance"] == "source_sample" for frame in grid_frames
            ),
            "duplicated_grid_frames": sum(
                frame["provenance"] == "duplicate_of_source_sample"
                for frame in grid_frames
            ),
            "collision_group_count": len(collision_groups),
            "collision_sample_count": len(collision_indices),
            "all_collision_samples_have_lossless_png": True,
            "all_source_samples_classified": True,
        },
        "first_state_locations": first_state_locations,
        "forbidden_source_indices": forbidden_indices,
        "signpost_phase_manifest": {
            "sha256": phase_manifest["sha256"],
            "source_sha256": phase_manifest["source_sha256"],
            "phase_count": len(phase_manifest["phases"]),
            "mechanically_derived_from_swift": True,
        },
        "clock_mapping": clock_mapping,
        "signpost_correlation": correlated_signposts,
        "artifact_manifest": artifact_manifest,
    }


def _assert_locked_simulator(simulator_id: str) -> None:
    if simulator_id.lower() == "booted":
        raise EvidenceError("literal 'booted' is forbidden")
    if simulator_id != LOCKED_SIMULATOR_ID:
        raise EvidenceError("capture must declare the one locked simulator")


def _validate_uuid_tokens(
    command: Sequence[str],
    *,
    approved_container_path_fragments: Mapping[int, str] | None = None,
) -> None:
    approved_by_index = dict(approved_container_path_fragments or {})
    for index, argument in enumerate(command):
        if argument.lower() == "booted" or re.search(r"(?i)(?:^|[=,])booted(?:$|[,])", argument):
            raise EvidenceError("literal 'booted' is forbidden")
        uuid_subject = argument
        approved_fragment = approved_by_index.get(index)
        if approved_fragment is not None:
            if uuid_subject.count(approved_fragment) != 1:
                raise EvidenceError("verified app container path is not exact in test command")
            uuid_subject = uuid_subject.replace(approved_fragment, "", 1)
        for candidate in UUID_PATTERN.findall(uuid_subject):
            if candidate.upper() != LOCKED_SIMULATOR_ID:
                raise EvidenceError("command contains a simulator other than the locked simulator")


def _run_json_command(command: Sequence[str], label: str) -> Any:
    completed = subprocess.run(
        list(command),
        stdin=subprocess.DEVNULL,
        capture_output=True,
        check=False,
        shell=False,
    )
    if completed.returncode != 0:
        raise EvidenceError(f"{label} query failed")
    try:
        return json.loads(completed.stdout.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise EvidenceError(f"{label} query did not return valid JSON") from error


def collect_native_window_snapshot(window_id: int) -> dict[str, Any]:
    """Measure booted devices and the target CoreGraphics window.

    This function is called only by an explicit native-window preflight. Unit
    tests inject a snapshot provider and never execute either system query.
    """

    if isinstance(window_id, bool) or not isinstance(window_id, int) or window_id <= 0:
        raise EvidenceError("native window ID must be a positive integer")
    devices_json = _run_json_command(
        ["/usr/bin/xcrun", "simctl", "list", "devices", "--json"],
        "simulator inventory",
    )
    devices_by_runtime = devices_json.get("devices") if isinstance(devices_json, dict) else None
    if not isinstance(devices_by_runtime, dict):
        raise EvidenceError("simulator inventory JSON is incomplete")
    booted_devices: list[dict[str, Any]] = []
    for devices in devices_by_runtime.values():
        if not isinstance(devices, list):
            raise EvidenceError("simulator inventory device list is invalid")
        for device in devices:
            if not isinstance(device, dict) or device.get("state") != "Booted":
                continue
            booted_devices.append(
                {
                    "udid": device.get("udid"),
                    "name": device.get("name"),
                    "state": "Booted",
                }
            )

    script = f"""
import CoreGraphics
import Foundation

func jsonValue(_ value: Any?) -> Any {{
    value ?? NSNull()
}}

func normalizedBounds(_ value: Any?) -> Any {{
    guard
        let raw = value as? NSDictionary,
        let x = raw["X"] as? NSNumber,
        let y = raw["Y"] as? NSNumber,
        let width = raw["Width"] as? NSNumber,
        let height = raw["Height"] as? NSNumber
    else {{
        return NSNull()
    }}
    return ["x": x, "y": y, "width": width, "height": height]
}}

let target = CGWindowID({window_id})
let raw = CGWindowListCopyWindowInfo(.optionIncludingWindow, target) as NSArray? ?? []
let normalized: [[String: Any]] = raw.compactMap {{ item in
    guard let value = item as? NSDictionary else {{
        return nil
    }}
    return [
        "window_id": jsonValue(value[kCGWindowNumber] as? NSNumber),
        "owner_application": jsonValue(value[kCGWindowOwnerName] as? String),
        "title": jsonValue(value[kCGWindowName] as? String),
        "layer": jsonValue(value[kCGWindowLayer] as? NSNumber),
        "on_screen": jsonValue(value[kCGWindowIsOnscreen] as? NSNumber),
        "bounds": normalizedBounds(value[kCGWindowBounds]),
    ]
}}
let data = try JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys])
FileHandle.standardOutput.write(data)
"""
    windows = _run_json_command(
        [
            "/usr/bin/swift",
            "-e",
            script,
        ],
        "CoreGraphics window",
    )
    if not isinstance(windows, list):
        raise EvidenceError("CoreGraphics window JSON is incomplete")
    return {"booted_devices": booted_devices, "windows": windows}


def _native_window_geometry_policy() -> dict[str, Any]:
    return {
        "schema_version": SCHEMA_VERSION,
        "minimum_width_points": NATIVE_WINDOW_MIN_WIDTH_POINTS,
        "minimum_height_points": NATIVE_WINDOW_MIN_HEIGHT_POINTS,
        "minimum_width_over_height_milli": NATIVE_WINDOW_MIN_ASPECT_MILLI,
        "maximum_width_over_height_milli": NATIVE_WINDOW_MAX_ASPECT_MILLI,
        "orientation": "portrait",
        "configured_output_scale_milli": NATIVE_WINDOW_OUTPUT_SCALE_MILLI,
        "h264_dimension_alignment_pixels": (
            NATIVE_WINDOW_H264_DIMENSION_ALIGNMENT_PIXELS
        ),
    }


def _native_window_geometry_policy_sha256() -> str:
    return hashlib.sha256(
        _canonical_json(_native_window_geometry_policy()).encode("ascii")
    ).hexdigest()


def _normalize_native_window_bounds(bounds: Any) -> dict[str, int]:
    if not isinstance(bounds, dict) or set(bounds) != {"x", "y", "width", "height"}:
        raise EvidenceError("native capture window bounds use an unsupported schema")
    normalized: dict[str, int] = {}
    for field in ("x", "y", "width", "height"):
        value = bounds.get(field)
        is_integral_number = isinstance(value, int) or (
            isinstance(value, float) and math.isfinite(value) and value.is_integer()
        )
        if (
            isinstance(value, bool)
            or not is_integral_number
        ):
            raise EvidenceError(
                "native capture window bounds require integral coordinates and "
                "positive integral dimensions"
            )
        normalized[field] = int(value)
    width = normalized["width"]
    height = normalized["height"]
    if width <= 0 or height <= 0:
        raise EvidenceError(
            "native capture window bounds require integral coordinates and "
            "positive integral dimensions"
        )
    if (
        width < NATIVE_WINDOW_MIN_WIDTH_POINTS
        or height < NATIVE_WINDOW_MIN_HEIGHT_POINTS
    ):
        raise EvidenceError(
            "native capture window geometry is below the evidence minimum"
        )
    if not (
        height * NATIVE_WINDOW_MIN_ASPECT_MILLI
        <= width * 1000
        <= height * NATIVE_WINDOW_MAX_ASPECT_MILLI
    ):
        raise EvidenceError(
            "native capture window geometry is outside the locked portrait aspect ratio"
        )
    return normalized


def _aligned_native_h264_dimension(points: int) -> int:
    alignment = NATIVE_WINDOW_H264_DIMENSION_ALIGNMENT_PIXELS
    return ((points + alignment - 1) // alignment) * alignment


def _native_window_geometry(
    bounds: Any,
    *,
    snapshot_sha256: str,
) -> dict[str, Any]:
    if re.fullmatch(r"[0-9a-f]{64}", snapshot_sha256) is None:
        raise EvidenceError("native capture window snapshot hash is invalid")
    normalized_bounds = _normalize_native_window_bounds(bounds)
    policy = _native_window_geometry_policy()
    geometry_without_hash = {
        "bounds_points": normalized_bounds,
        "expected_h264_pixels": {
            "width": _aligned_native_h264_dimension(normalized_bounds["width"]),
            "height": _aligned_native_h264_dimension(normalized_bounds["height"]),
        },
        "policy": policy,
        "policy_sha256": _native_window_geometry_policy_sha256(),
        "snapshot_sha256": snapshot_sha256,
    }
    return {
        **geometry_without_hash,
        "geometry_sha256": hashlib.sha256(
            _canonical_json(geometry_without_hash).encode("ascii")
        ).hexdigest(),
    }


def validate_capture_receipt_window_geometry(
    capture_receipt: Mapping[str, Any],
    raw_report: Mapping[str, Any],
) -> dict[str, Any]:
    geometry = capture_receipt.get("window_geometry")
    if not isinstance(geometry, dict) or set(geometry) != {
        "bounds_points",
        "expected_h264_pixels",
        "policy",
        "policy_sha256",
        "snapshot_sha256",
        "geometry_sha256",
    }:
        raise EvidenceError("capture receipt window geometry is incomplete")
    snapshot_sha256 = capture_receipt.get("window_snapshot_sha256")
    if (
        not isinstance(snapshot_sha256, str)
        or geometry.get("snapshot_sha256") != snapshot_sha256
    ):
        raise EvidenceError("capture receipt window geometry snapshot hash is inconsistent")
    expected_geometry = _native_window_geometry(
        geometry.get("bounds_points"),
        snapshot_sha256=snapshot_sha256,
    )
    if (
        geometry.get("policy") != expected_geometry["policy"]
        or geometry.get("policy_sha256") != expected_geometry["policy_sha256"]
    ):
        raise EvidenceError("capture receipt window geometry policy is not current")
    if geometry.get("geometry_sha256") != expected_geometry["geometry_sha256"]:
        raise EvidenceError("capture receipt window geometry hash is inconsistent")
    if geometry != expected_geometry:
        raise EvidenceError("capture receipt window geometry is not canonical")
    raw_source = raw_report.get("source")
    if not isinstance(raw_source, Mapping):
        raise EvidenceError("raw video dimensions are unavailable for geometry validation")
    raw_dimensions = {
        "width": raw_source.get("width"),
        "height": raw_source.get("height"),
    }
    if raw_dimensions != expected_geometry["expected_h264_pixels"]:
        raise EvidenceError(
            "raw video dimensions do not match the measured native window geometry"
        )
    return expected_geometry


def validate_native_window_snapshot(
    snapshot: dict[str, Any], window_id: int
) -> dict[str, Any]:
    if not isinstance(snapshot, dict) or set(snapshot) != {
        "booted_devices",
        "windows",
    }:
        raise EvidenceError("native window snapshot uses an unsupported schema")
    booted = snapshot.get("booted_devices")
    windows = snapshot.get("windows")
    if not isinstance(booted, list) or not isinstance(windows, list):
        raise EvidenceError("native window snapshot arrays are incomplete")
    if len(booted) != 1 or not isinstance(booted[0], dict):
        raise EvidenceError("exactly one simulator must be booted for native capture")
    device = booted[0]
    if set(device) != {"udid", "name", "state"}:
        raise EvidenceError("booted simulator provenance is incomplete")
    if (
        device.get("udid") != LOCKED_SIMULATOR_ID
        or device.get("name") != LOCKED_SIMULATOR_NAME
        or device.get("state") != "Booted"
    ):
        raise EvidenceError("the only booted simulator is not the locked C302 device")
    matching = [
        window
        for window in windows
        if isinstance(window, dict) and window.get("window_id") == window_id
    ]
    if len(matching) != 1:
        raise EvidenceError("native window identity is missing or ambiguous")
    window = matching[0]
    if set(window) != {
        "window_id",
        "owner_application",
        "title",
        "layer",
        "on_screen",
        "bounds",
    }:
        raise EvidenceError("native window provenance is incomplete")
    if window.get("owner_application") != "Simulator":
        raise EvidenceError("native capture window is not owned by Simulator")
    title = window.get("title")
    if not isinstance(title, str) or LOCKED_SIMULATOR_NAME not in title:
        raise EvidenceError("native capture window title does not match the locked device")
    if window.get("layer") != 0 or window.get("on_screen") is not True:
        raise EvidenceError("native capture window must be a visible layer-zero window")
    snapshot_hash = hashlib.sha256(
        _canonical_json(snapshot).encode("utf-8")
    ).hexdigest()
    window_geometry = _native_window_geometry(
        window.get("bounds"),
        snapshot_sha256=snapshot_hash,
    )
    return {
        "simulator_udid": LOCKED_SIMULATOR_ID,
        "simulator_name": LOCKED_SIMULATOR_NAME,
        "only_locked_simulator_booted": True,
        "window_id": window_id,
        "owner_application": "Simulator",
        "window_title_sha256": hashlib.sha256(title.encode("utf-8")).hexdigest(),
        "title_matches_locked_device": True,
        "visible_layer_zero": True,
        "snapshot_sha256": snapshot_hash,
        "window_geometry": window_geometry,
        "measured_monotonic_nanoseconds": time.monotonic_ns(),
        "measured_immediately_before_capture": True,
    }


def _export_path_from_assignment(argument: str, key: str) -> Path:
    prefix = f"{key}="
    if not argument.startswith(prefix):
        raise EvidenceError(f"test command must declare {key}")
    path = Path(argument[len(prefix) :])
    if not path.is_absolute() or not path.parent.is_dir():
        raise EvidenceError(f"{key} must name an absolute output in an existing directory")
    if ".." in path.parts:
        raise EvidenceError(f"{key} must not contain parent traversal")
    if os.path.lexists(path):
        metadata = path.lstat()
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
            raise EvidenceError(
                f"{key} existing route cache must be one owned regular file"
            )
    return path


def _data_container_from_assignment(argument: str) -> Path:
    prefix = f"{ARTIFACT_DATA_CONTAINER_ENVIRONMENT_KEY}="
    if not argument.startswith(prefix):
        raise EvidenceError(
            f"test command must declare {ARTIFACT_DATA_CONTAINER_ENVIRONMENT_KEY}"
        )
    path = Path(argument[len(prefix) :])
    if not path.is_absolute() or ".." in path.parts or not path.is_dir():
        raise EvidenceError("artifact data container must be an existing absolute directory")
    resolved = path.resolve(strict=True)
    if not os.access(resolved, os.W_OK | os.X_OK):
        raise EvidenceError("artifact data container is not writable")
    return resolved


def _require_output_inside_data_container(path: Path, container: Path) -> None:
    resolved_parent = path.parent.resolve(strict=True)
    try:
        resolved_parent.relative_to(container)
    except ValueError as error:
        raise EvidenceError(
            "artifact export output must be inside the performance app data container"
        ) from error
    if resolved_parent == container:
        raise EvidenceError(
            "artifact exports require a dedicated existing directory inside the app container"
        )
    if not os.access(resolved_parent, os.W_OK | os.X_OK):
        raise EvidenceError("artifact export parent is not writable")


def _relative_runtime_export_path(path: Path, container: Path) -> Path:
    """Return the app-authored descendant without the ephemeral container UUID."""

    path = Path(path)
    container = Path(container).resolve(strict=True)
    resolved_parent = path.parent.resolve(strict=True)
    try:
        relative_parent = resolved_parent.relative_to(container)
    except ValueError as error:
        raise EvidenceError(
            "artifact export output must be inside the performance app data container"
        ) from error
    if relative_parent.parts != ("Library", "Caches"):
        raise EvidenceError(
            "artifact exports require the closed Library/Caches runtime directory"
        )
    filename = path.name
    if (
        len(filename) > 128
        or not filename.endswith(".json")
        or re.fullmatch(r"[A-Za-z0-9._-]+", filename) is None
    ):
        raise EvidenceError("artifact export filename is outside the closed grammar")
    return Path("Library", "Caches", filename)


def _route_bound_runtime_export_paths(
    matrix_route_code: str,
) -> tuple[Path, Path]:
    known_codes = {
        route["matrix_route_code"]
        for route in CHAT_OPEN_VIDEO_ROUTE_MANIFEST.values()
    }
    if matrix_route_code not in known_codes:
        raise EvidenceError("artifact export route is outside the closed video manifest")
    base = Path("Library", "Caches")
    return (
        base / f"chat-open-{matrix_route_code}-signposts.json",
        base / f"chat-open-{matrix_route_code}-markers.json",
    )


def _runtime_export_path(container: Path, relative_path: Path) -> Path:
    container = Path(container).resolve(strict=True)
    relative_path = Path(relative_path)
    if (
        relative_path.is_absolute()
        or relative_path.parts[:2] != ("Library", "Caches")
        or len(relative_path.parts) != 3
    ):
        raise EvidenceError("runtime artifact descendant is outside the closed grammar")
    expected_parent = (container / "Library/Caches").resolve(strict=True)
    candidate = container / relative_path
    if candidate.parent.resolve(strict=True) != expected_parent:
        raise EvidenceError("runtime artifact descendant escaped the current app container")
    return candidate


def _stage_owned_runtime_export(
    source: Path,
    destination: Path,
    *,
    not_created_before_epoch_nanoseconds: int,
) -> tuple[int, int]:
    """Copy one bounded app-owned regular file without following a replacement link."""

    source = Path(source)
    destination = Path(destination)
    source_metadata = source.lstat()
    source_birth_nanoseconds = int(
        getattr(source_metadata, "st_birthtime", source_metadata.st_ctime)
        * 1_000_000_000
    )
    if (
        not stat.S_ISREG(source_metadata.st_mode)
        or source_metadata.st_nlink != 1
        or source_metadata.st_size <= 0
        or source_metadata.st_size > MAX_CAPTURE_EXPORT_BYTES
        or source_birth_nanoseconds < not_created_before_epoch_nanoseconds
        or source_metadata.st_ctime_ns < not_created_before_epoch_nanoseconds
    ):
        raise EvidenceError("runtime artifact export is not a bounded owned regular file")
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    source_fd = os.open(source, flags)
    try:
        opened_metadata = os.fstat(source_fd)
        if (
            opened_metadata.st_dev != source_metadata.st_dev
            or opened_metadata.st_ino != source_metadata.st_ino
            or not stat.S_ISREG(opened_metadata.st_mode)
        ):
            raise EvidenceError("runtime artifact export changed during staging")
        with os.fdopen(source_fd, "rb", closefd=False) as source_handle:
            with destination.open("xb") as destination_handle:
                shutil.copyfileobj(source_handle, destination_handle, 64 * 1024)
        final_metadata = os.fstat(source_fd)
        if (
            final_metadata.st_dev != source_metadata.st_dev
            or final_metadata.st_ino != source_metadata.st_ino
            or final_metadata.st_size != source_metadata.st_size
            or destination.stat().st_size != source_metadata.st_size
        ):
            destination.unlink(missing_ok=True)
            raise EvidenceError("runtime artifact export changed during staging")
    finally:
        os.close(source_fd)
    return source_metadata.st_dev, source_metadata.st_ino


def _remove_owned_runtime_export(
    source: Path,
    identity: tuple[int, int],
) -> None:
    """Remove only the exact inode staged by this capture session."""

    try:
        metadata = Path(source).lstat()
    except FileNotFoundError:
        return
    if (
        stat.S_ISREG(metadata.st_mode)
        and (metadata.st_dev, metadata.st_ino) == identity
    ):
        Path(source).unlink()


def resolve_performance_app_data_container(
    simulator_id: str,
    bundle_identifier: str = PERFORMANCE_APP_BUNDLE_IDENTIFIER,
) -> Path:
    """Resolve an already-installed app container without changing simulator state."""

    _assert_locked_simulator(simulator_id)
    if bundle_identifier != PERFORMANCE_APP_BUNDLE_IDENTIFIER:
        raise EvidenceError("only the isolated performance bundle container is allowed")
    executable = shutil.which("xcrun") or "/usr/bin/xcrun"
    command = [
        executable,
        "simctl",
        "get_app_container",
        LOCKED_SIMULATOR_ID,
        PERFORMANCE_APP_BUNDLE_IDENTIFIER,
        "data",
    ]
    try:
        result = subprocess.run(
            command,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise EvidenceError("unable to resolve the performance app data container") from error
    lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    if result.returncode != 0 or len(lines) != 1:
        raise EvidenceError("performance app data container is not installed and resolvable")
    container = Path(lines[0])
    if not container.is_absolute() or ".." in container.parts or not container.is_dir():
        raise EvidenceError("resolved performance app data container is invalid")
    resolved = container.resolve(strict=True)
    expected_device_root = (
        Path.home()
        / "Library/Developer/CoreSimulator/Devices"
        / LOCKED_SIMULATOR_ID
    ).resolve(strict=False)
    try:
        resolved.relative_to(expected_device_root)
    except ValueError as error:
        raise EvidenceError("resolved app container does not belong to the locked simulator") from error
    if not os.access(resolved, os.W_OK | os.X_OK):
        raise EvidenceError("resolved performance app data container is not writable")
    return resolved


def _closed_route_binding(record: Mapping[str, Any]) -> dict[str, str]:
    selector = record.get("test_selector")
    matrix_route_code = record.get("matrix_route_code")
    fixture_scenario = record.get("fixture_scenario")
    if not all(
        isinstance(value, str) and value
        for value in (selector, matrix_route_code, fixture_scenario)
    ):
        raise EvidenceError("video route binding is incomplete")
    expected = CHAT_OPEN_VIDEO_ROUTE_MANIFEST.get(selector)
    if expected != {
        "matrix_route_code": matrix_route_code,
        "fixture_scenario": fixture_scenario,
    }:
        raise EvidenceError("video route binding is outside the closed manifest")
    return {
        "test_selector": selector,
        "matrix_route_code": matrix_route_code,
        "fixture_scenario": fixture_scenario,
    }


def validate_exported_route_binding(
    signposts: Mapping[str, Any],
    *,
    expected_test_preflight: Mapping[str, Any],
) -> bool:
    """Bind optional app-authored route evidence to the selected XCTest.

    Older standalone numeric-trace unit fixtures may omit both public fields.
    A real successful capture requires them in ``finalize_capture_evidence``.
    """

    if not isinstance(signposts, Mapping):
        raise EvidenceError("signpost route binding is not an object")
    has_route = "matrix_route_code" in signposts
    has_scenario = "fixture_scenario" in signposts
    if not has_route and not has_scenario:
        return False
    if not has_route or not has_scenario:
        raise EvidenceError("exported video route binding is incomplete")
    expected = _closed_route_binding(expected_test_preflight)
    exported = {
        "matrix_route_code": signposts.get("matrix_route_code"),
        "fixture_scenario": signposts.get("fixture_scenario"),
    }
    if exported != {
        "matrix_route_code": expected["matrix_route_code"],
        "fixture_scenario": expected["fixture_scenario"],
    }:
        raise EvidenceError("exported video route binding does not match selector")
    return True


def _validate_non_destructive_fixture_command(command: Sequence[str]) -> None:
    forbidden_tokens = {
        "booted",
        "clean",
        "clean-cache",
        "erase",
        "uninstall",
        "reset",
        "shutdown",
        "delete",
        "terminate",
        "kill",
    }
    for argument in command:
        normalized_tokens = {
            token.lower()
            for token in re.split(r"[^A-Za-z0-9_.-]+", argument)
            if token
        }
        if normalized_tokens & forbidden_tokens:
            raise EvidenceError("fixture command contains a destructive or unsafe token")


def _validate_closed_xcode_action_tail(
    command: Sequence[str],
    *,
    cursor: int,
    action: str,
) -> tuple[str, dict[str, str]]:
    if command[cursor : cursor + 8] != [
        str(APPROVED_XCODEBUILD_WRAPPER),
        action,
        "-jobs",
        "1",
        "-parallel-testing-enabled",
        "NO",
        "-collect-test-diagnostics",
        "never",
    ]:
        raise EvidenceError(
            f"{action} command must use the cached wrapper in single-worker sequential "
            "mode with diagnostics disabled"
        )
    tail = list(command[cursor + 8 :])
    expected_bundle_tail = [
        "XABBER_APP_BUNDLE_IDENTIFIER=xabber.ios.codex-chat-performance",
        (
            "XABBER_PUSH_EXTENSION_BUNDLE_IDENTIFIER="
            "xabber.ios.codex-chat-performance.xabber-push-extension"
        ),
    ]
    if len(tail) < 3 or tail[-2:] != expected_bundle_tail:
        raise EvidenceError(
            f"{action} command must use the isolated performance fixture bundles"
        )
    selectors = tail[:-2]
    if len(selectors) != 1:
        raise EvidenceError(f"{action} command requires exactly one video-route selector")
    selector_prefix = (
        "-only-testing:xabberChatPerformanceUITests/ChatPerformanceUITests/"
    )
    if not selectors[0].startswith(selector_prefix):
        raise EvidenceError(f"{action} command requires the closed video-route manifest")
    test_selector = selectors[0][len(selector_prefix) :]
    route = CHAT_OPEN_VIDEO_ROUTE_MANIFEST.get(test_selector)
    if route is None:
        raise EvidenceError(f"{action} command requires the closed video-route manifest")
    return test_selector, route


def _fixture_action_preflight(
    command: Sequence[str],
    *,
    action: str,
    test_selector: str,
    route: Mapping[str, str],
) -> dict[str, Any]:
    compatibility = {
        "schema_version": SCHEMA_VERSION,
        "profile": "isolated_chat_performance_fixture",
        "simulator_udid": LOCKED_SIMULATOR_ID,
        "test_selector": test_selector,
        "matrix_route_code": route["matrix_route_code"],
        "fixture_scenario": route["fixture_scenario"],
        "worker_job_limit": 1,
        "parallel_testing_disabled": True,
        "test_diagnostics_collection_disabled": True,
        "fixture_bundle_identifier": PERFORMANCE_APP_BUNDLE_IDENTIFIER,
    }
    return {
        **compatibility,
        "command_sha256": hashlib.sha256(
            _canonical_json(list(command)).encode("utf-8")
        ).hexdigest(),
        "selector_count": 1,
        "build_for_testing": action == "build-for-testing",
        "test_without_building": action == "test-without-building",
        "build_compatibility_sha256": hashlib.sha256(
            _canonical_json(compatibility).encode("utf-8")
        ).hexdigest(),
        "production_bundle_untouched": True,
        "contains_paths": False,
    }


def validate_build_for_testing_command(command: Sequence[str]) -> dict[str, Any]:
    if not command or not all(isinstance(argument, str) and argument for argument in command):
        raise EvidenceError("build-for-testing command must be a non-empty JSON string array")
    command = list(command)
    _validate_non_destructive_fixture_command(command)
    fixed_prefix = [
        "/usr/bin/env",
        "-u",
        "TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT",
        "-u",
        "TEST_RUNNER_XABBER_ISOLATED_STORAGE",
        "-u",
        "XABBER_CHAT_LIVE_QA_MODE",
        "XABBER_SCHEME=Chat Performance UI Tests",
        f"XABBER_DESTINATION=platform=iOS Simulator,id={LOCKED_SIMULATOR_ID}",
    ]
    if command[: len(fixed_prefix)] != fixed_prefix:
        raise EvidenceError(
            "build-for-testing command is outside the approved isolated fixture grammar"
        )
    _validate_uuid_tokens(command)
    test_selector, route = _validate_closed_xcode_action_tail(
        command,
        cursor=len(fixed_prefix),
        action="build-for-testing",
    )
    return _fixture_action_preflight(
        command,
        action="build-for-testing",
        test_selector=test_selector,
        route=route,
    )


def _prebuilt_path_artifact_id(relative_path: Path) -> str:
    return hashlib.sha256(
        ("build-products-relative-path\0" + relative_path.as_posix()).encode(
            "utf-8"
        )
    ).hexdigest()


def _resolve_prebuilt_descendant_without_symlinks(
    root: Path,
    relative_path: Path,
    *,
    label: str,
) -> Path:
    if (
        relative_path.is_absolute()
        or not relative_path.parts
        or any(part in {"", ".", ".."} for part in relative_path.parts)
    ):
        raise EvidenceError(f"{label} uses an unsafe build-products reference")
    current = root
    for component in relative_path.parts:
        current = current / component
        try:
            metadata = current.lstat()
        except (FileNotFoundError, OSError) as error:
            raise EvidenceError(f"{label} is missing from build products") from error
        if stat.S_ISLNK(metadata.st_mode):
            raise EvidenceError(f"{label} contains a symlink")
    try:
        resolved = current.resolve(strict=True)
        resolved.relative_to(root)
    except (FileNotFoundError, OSError, ValueError) as error:
        raise EvidenceError(f"{label} escaped the build-products root") from error
    return resolved


def _relative_path_from_testroot_reference(reference: Any, *, label: str) -> Path:
    prefix = "__TESTROOT__/"
    if not isinstance(reference, str) or not reference.startswith(prefix):
        raise EvidenceError(f"{label} must use the closed __TESTROOT__ reference")
    relative = Path(reference[len(prefix) :])
    if (
        relative.is_absolute()
        or not relative.parts
        or any(part in {"", ".", ".."} for part in relative.parts)
    ):
        raise EvidenceError(f"{label} uses an unsafe build-products reference")
    return relative


def _safe_prebuilt_regular_file_record(path: Path, root: Path) -> dict[str, Any]:
    try:
        relative = path.relative_to(root)
        path_metadata = os.stat(path, follow_symlinks=False)
    except (FileNotFoundError, OSError, ValueError) as error:
        raise EvidenceError("prebuilt regular file is unavailable") from error
    if stat.S_ISLNK(path_metadata.st_mode) or not stat.S_ISREG(path_metadata.st_mode):
        raise EvidenceError("prebuilt product contains a non-regular file")
    if (
        path_metadata.st_size < 0
        or path_metadata.st_size > MAX_PREBUILT_REGULAR_FILE_BYTES
    ):
        raise EvidenceError("prebuilt regular file size is unbounded")
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise EvidenceError("prebuilt regular file could not be opened safely") from error
    try:
        opened_before = os.fstat(descriptor)
        path_signature = (
            path_metadata.st_dev,
            path_metadata.st_ino,
            path_metadata.st_mode,
            path_metadata.st_size,
            path_metadata.st_mtime_ns,
            path_metadata.st_ctime_ns,
        )
        opened_signature = (
            opened_before.st_dev,
            opened_before.st_ino,
            opened_before.st_mode,
            opened_before.st_size,
            opened_before.st_mtime_ns,
            opened_before.st_ctime_ns,
        )
        if path_signature != opened_signature or not stat.S_ISREG(opened_before.st_mode):
            raise EvidenceError("prebuilt regular file changed before hashing")
        digest = hashlib.sha256()
        byte_count = 0
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            byte_count += len(chunk)
            if byte_count > MAX_PREBUILT_REGULAR_FILE_BYTES:
                raise EvidenceError("prebuilt regular file size is unbounded")
            digest.update(chunk)
        opened_after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    try:
        path_after = os.stat(path, follow_symlinks=False)
    except (FileNotFoundError, OSError) as error:
        raise EvidenceError("prebuilt regular file changed during hashing") from error
    after_signatures = (
        (
            opened_after.st_dev,
            opened_after.st_ino,
            opened_after.st_mode,
            opened_after.st_size,
            opened_after.st_mtime_ns,
            opened_after.st_ctime_ns,
        ),
        (
            path_after.st_dev,
            path_after.st_ino,
            path_after.st_mode,
            path_after.st_size,
            path_after.st_mtime_ns,
            path_after.st_ctime_ns,
        ),
    )
    if (
        opened_signature != after_signatures[0]
        or opened_signature != after_signatures[1]
        or byte_count != opened_before.st_size
    ):
        raise EvidenceError("prebuilt regular file changed during hashing")
    return {
        "artifact_id": _prebuilt_path_artifact_id(relative),
        "sha256": digest.hexdigest(),
        "byte_count": byte_count,
        "mode": stat.S_IMODE(opened_before.st_mode),
    }


def _load_prebuilt_plist_document(
    path: Path,
    root: Path,
    *,
    label: str,
) -> tuple[dict[str, Any], dict[str, Any]]:
    record_before = _safe_prebuilt_regular_file_record(path, root)
    if record_before["byte_count"] > MAX_PREBUILT_XCTESTRUN_BYTES:
        raise EvidenceError(f"{label} is unbounded")
    try:
        completed = subprocess.run(
            [str(SYSTEM_PLUTIL_PATH), "-convert", "json", "-o", "-", "--", str(path)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            shell=False,
            check=False,
            timeout=10.0,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise EvidenceError(f"{label} could not be decoded") from error
    if (
        completed.returncode != 0
        or not isinstance(completed.stdout, bytes)
        or not completed.stdout
        or len(completed.stdout) > MAX_PREBUILT_PLIST_JSON_BYTES
    ):
        raise EvidenceError(f"{label} could not be decoded")
    try:
        document = json.loads(completed.stdout)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise EvidenceError(f"{label} could not be decoded") from error
    if not isinstance(document, dict):
        raise EvidenceError(f"{label} must decode to a dictionary")
    record_after = _safe_prebuilt_regular_file_record(path, root)
    if record_before != record_after:
        raise EvidenceError(f"{label} changed during decoding")
    return document, record_after


def _closed_xctestrun_product_specs(
    document: Mapping[str, Any],
) -> tuple[dict[str, Any], dict[str, dict[str, Any]]]:
    expected_top_level_keys = {
        "__xctestrun_metadata__",
        PERFORMANCE_UI_TEST_TARGET_NAME,
    }
    if set(document) != expected_top_level_keys:
        raise EvidenceError("prebuilt xctestrun uses an unsupported target schema")
    expected_metadata = {
        "FormatVersion": 1,
        "ContainerInfo": {
            "ContainerName": "xabber",
            "SchemeName": "Chat Performance UI Tests",
        },
    }
    if document.get("__xctestrun_metadata__") != expected_metadata:
        raise EvidenceError("prebuilt xctestrun metadata is incompatible")
    target = document.get(PERFORMANCE_UI_TEST_TARGET_NAME)
    if not isinstance(target, dict):
        raise EvidenceError("prebuilt xctestrun target is unavailable")
    expected_scalar_fields = {
        "BlueprintName": PERFORMANCE_UI_TEST_TARGET_NAME,
        "BlueprintProviderName": "xabber",
        "BlueprintProviderRelativePath": "xabber.xcodeproj",
        "ProductModuleName": PERFORMANCE_UI_TEST_TARGET_NAME,
        "IsUITestBundle": True,
        "IsXCTRunnerHostedTestBundle": True,
        "TestHostBundleIdentifier": PERFORMANCE_UI_TEST_RUNNER_BUNDLE_IDENTIFIER,
        "TestBundlePath": PERFORMANCE_UI_TEST_BUNDLE_HOST_REFERENCE,
        "TestHostPath": PERFORMANCE_UI_TEST_HOST_REFERENCE,
        "UITargetAppPath": PERFORMANCE_UI_TARGET_APP_REFERENCE,
    }
    if any(target.get(key) != value for key, value in expected_scalar_fields.items()):
        raise EvidenceError("prebuilt xctestrun target binding is incompatible")
    dependent_products = target.get("DependentProductPaths")
    if (
        not isinstance(dependent_products, list)
        or dependent_products != list(PERFORMANCE_DEPENDENT_PRODUCT_REFERENCES)
    ):
        raise EvidenceError("prebuilt xctestrun dependent products are unexpected")
    expected_crash_bundle_identifiers = [
        PERFORMANCE_APP_BUNDLE_IDENTIFIER,
        PERFORMANCE_PUSH_EXTENSION_BUNDLE_IDENTIFIER,
        PERFORMANCE_UI_TEST_BUNDLE_IDENTIFIER,
    ]
    if target.get("BundleIdentifiersForCrashReportEmphasis") != (
        expected_crash_bundle_identifiers
    ):
        raise EvidenceError("prebuilt xctestrun bundle identifiers are incompatible")
    product_specs = {
        PERFORMANCE_UI_TARGET_APP_REFERENCE: {
            "role_codes": ["dependent_product", "ui_target_app"],
            "product_kind": "application",
            "bundle_identifier": PERFORMANCE_APP_BUNDLE_IDENTIFIER,
            "executable_name": "xabber",
        },
        PERFORMANCE_UI_TEST_HOST_REFERENCE: {
            "role_codes": ["dependent_product", "ui_test_runner"],
            "product_kind": "ui_test_runner_application",
            "bundle_identifier": PERFORMANCE_UI_TEST_RUNNER_BUNDLE_IDENTIFIER,
            "executable_name": "xabberChatPerformanceUITests-Runner",
        },
        PERFORMANCE_UI_TEST_BUNDLE_REFERENCE: {
            "role_codes": ["dependent_product", "ui_test_bundle"],
            "product_kind": "ui_test_bundle",
            "bundle_identifier": PERFORMANCE_UI_TEST_BUNDLE_IDENTIFIER,
            "executable_name": PERFORMANCE_UI_TEST_TARGET_NAME,
        },
        PERFORMANCE_PUSH_EXTENSION_REFERENCE: {
            "role_codes": ["dependent_product", "push_extension"],
            "product_kind": "app_extension",
            "bundle_identifier": PERFORMANCE_PUSH_EXTENSION_BUNDLE_IDENTIFIER,
            "executable_name": "xabber-push-extension",
        },
    }
    product_path_ids = sorted(
        _prebuilt_path_artifact_id(
            _relative_path_from_testroot_reference(reference, label="product")
        )
        for reference in product_specs
    )
    target_binding = {
        "schema_version": SCHEMA_VERSION,
        "test_target_name": PERFORMANCE_UI_TEST_TARGET_NAME,
        "product_module_name": PERFORMANCE_UI_TEST_TARGET_NAME,
        "ui_test_bundle": True,
        "xctrunner_hosted": True,
        "test_host_bundle_identifier": PERFORMANCE_UI_TEST_RUNNER_BUNDLE_IDENTIFIER,
        "crash_emphasis_bundle_identifiers": expected_crash_bundle_identifiers,
        "referenced_product_ids": product_path_ids,
    }
    return target_binding, product_specs


def _collect_prebuilt_bundle_inventory(
    *,
    root: Path,
    bundle_path: Path,
    spec: Mapping[str, Any],
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    try:
        bundle_metadata = bundle_path.lstat()
        bundle_relative = bundle_path.relative_to(root)
    except (FileNotFoundError, OSError, ValueError) as error:
        raise EvidenceError("referenced prebuilt product is unavailable") from error
    if stat.S_ISLNK(bundle_metadata.st_mode) or not stat.S_ISDIR(bundle_metadata.st_mode):
        raise EvidenceError("referenced prebuilt product must be a regular directory")
    info_plist = _resolve_prebuilt_descendant_without_symlinks(
        bundle_path,
        Path("Info.plist"),
        label="referenced product metadata",
    )
    info, info_plist_record = _load_prebuilt_plist_document(
        info_plist,
        root,
        label="referenced product metadata",
    )
    if (
        info.get("CFBundleIdentifier") != spec["bundle_identifier"]
        or info.get("CFBundleExecutable") != spec["executable_name"]
    ):
        raise EvidenceError("referenced prebuilt product metadata is incompatible")
    executable = _resolve_prebuilt_descendant_without_symlinks(
        bundle_path,
        Path(str(spec["executable_name"])),
        label="referenced runnable executable",
    )
    executable_record = _safe_prebuilt_regular_file_record(executable, root)

    files: list[dict[str, Any]] = []
    pending_directories = [bundle_path]
    while pending_directories:
        directory = pending_directories.pop()
        try:
            entries = sorted(os.scandir(directory), key=lambda entry: entry.name)
        except OSError as error:
            raise EvidenceError("referenced prebuilt product could not be inventoried") from error
        for entry in entries:
            try:
                metadata = entry.stat(follow_symlinks=False)
            except OSError as error:
                raise EvidenceError("referenced prebuilt product entry is unavailable") from error
            if stat.S_ISLNK(metadata.st_mode):
                raise EvidenceError("referenced prebuilt product contains a symlink")
            entry_path = Path(entry.path)
            if stat.S_ISDIR(metadata.st_mode):
                pending_directories.append(entry_path)
            elif stat.S_ISREG(metadata.st_mode):
                files.append(_safe_prebuilt_regular_file_record(entry_path, root))
                if len(files) > MAX_PREBUILT_REFERENCED_REGULAR_FILES:
                    raise EvidenceError("referenced prebuilt product inventory is unbounded")
            else:
                raise EvidenceError("referenced prebuilt product contains a non-regular entry")
    files.sort(key=lambda record: record["artifact_id"])
    if not files:
        raise EvidenceError("referenced prebuilt product inventory is empty")
    product_bytes = sum(record["byte_count"] for record in files)
    if product_bytes > MAX_PREBUILT_REFERENCED_BYTES:
        raise EvidenceError("referenced prebuilt product inventory is unbounded")
    executable_matches = [
        record
        for record in files
        if record["artifact_id"] == executable_record["artifact_id"]
    ]
    if executable_matches != [executable_record]:
        raise EvidenceError("referenced runnable executable is not uniquely inventoried")
    info_plist_matches = [
        record
        for record in files
        if record["artifact_id"] == info_plist_record["artifact_id"]
    ]
    if info_plist_matches != [info_plist_record]:
        raise EvidenceError("referenced product metadata changed during inventory")
    product = {
        "product_id": _prebuilt_path_artifact_id(bundle_relative),
        "role_codes": sorted(spec["role_codes"]),
        "product_kind": spec["product_kind"],
        "bundle_identifier": spec["bundle_identifier"],
        "executable_artifact_id": executable_record["artifact_id"],
        "executable_sha256": executable_record["sha256"],
        "executable_byte_count": executable_record["byte_count"],
        "executable_mode": executable_record["mode"],
        "regular_file_count": len(files),
        "regular_file_byte_count": product_bytes,
        "content_manifest_sha256": hashlib.sha256(
            _canonical_json(files).encode("utf-8")
        ).hexdigest(),
    }
    return product, files


def collect_prebuilt_build_products(
    build_products_root: Path = DEFAULT_XCODE_BUILD_PRODUCTS_ROOT,
) -> dict[str, Any]:
    root = Path(build_products_root)
    if root.is_symlink():
        raise EvidenceError("prebuilt build-products root must not be a symlink")
    try:
        resolved_root = root.resolve(strict=True)
    except (FileNotFoundError, OSError) as error:
        raise EvidenceError("prebuilt build-products root is unavailable") from error
    if not resolved_root.is_dir():
        raise EvidenceError("prebuilt build-products root is not a directory")
    try:
        candidates = sorted(
            candidate
            for candidate in resolved_root.iterdir()
            if PERFORMANCE_XCTESTRUN_FILENAME_PATTERN.fullmatch(candidate.name)
        )
    except OSError as error:
        raise EvidenceError("prebuilt xctestrun inventory is unavailable") from error
    if not candidates or len(candidates) > MAX_PREBUILT_XCTESTRUN_FILES:
        raise EvidenceError("prebuilt xctestrun inventory is empty or unbounded")

    xctestrun_records: list[dict[str, Any]] = []
    product_specs_by_id: dict[str, tuple[Path, dict[str, Any]]] = {}
    expected_product_id_set: tuple[str, ...] | None = None
    for candidate in candidates:
        try:
            lexical_relative = candidate.relative_to(resolved_root)
        except ValueError as error:
            raise EvidenceError("prebuilt xctestrun escaped the build-products root") from error
        resolved_candidate = _resolve_prebuilt_descendant_without_symlinks(
            resolved_root,
            lexical_relative,
            label="prebuilt xctestrun",
        )
        candidate_record = _safe_prebuilt_regular_file_record(
            resolved_candidate,
            resolved_root,
        )
        if candidate_record["byte_count"] > MAX_PREBUILT_XCTESTRUN_BYTES:
            raise EvidenceError("prebuilt xctestrun inventory is unbounded")
        document, decoded_candidate_record = _load_prebuilt_plist_document(
            resolved_candidate,
            resolved_root,
            label="prebuilt xctestrun",
        )
        if candidate_record != decoded_candidate_record:
            raise EvidenceError("prebuilt xctestrun changed during inventory")
        target_binding, product_specs = _closed_xctestrun_product_specs(document)
        product_ids: list[str] = []
        for reference, spec in product_specs.items():
            relative = _relative_path_from_testroot_reference(
                reference,
                label="prebuilt product",
            )
            product_id = _prebuilt_path_artifact_id(relative)
            product_ids.append(product_id)
            existing = product_specs_by_id.get(product_id)
            candidate_spec = (relative, dict(spec))
            if existing is not None and existing != candidate_spec:
                raise EvidenceError("prebuilt xctestrun product bindings disagree")
            product_specs_by_id[product_id] = candidate_spec
        current_product_id_set = tuple(sorted(product_ids))
        if expected_product_id_set is None:
            expected_product_id_set = current_product_id_set
        elif expected_product_id_set != current_product_id_set:
            raise EvidenceError("prebuilt xctestrun product sets disagree")
        candidate_record["test_target_binding_sha256"] = hashlib.sha256(
            _canonical_json(target_binding).encode("utf-8")
        ).hexdigest()
        xctestrun_records.append(candidate_record)

    if (
        len(product_specs_by_id) != 4
        or len(product_specs_by_id) > MAX_PREBUILT_REFERENCED_PRODUCTS
    ):
        raise EvidenceError("prebuilt referenced product inventory is incomplete or unbounded")
    product_records: list[dict[str, Any]] = []
    unique_file_records: dict[str, dict[str, Any]] = {}
    for product_id, (relative, spec) in sorted(product_specs_by_id.items()):
        bundle_path = _resolve_prebuilt_descendant_without_symlinks(
            resolved_root,
            relative,
            label="referenced prebuilt product",
        )
        product, files = _collect_prebuilt_bundle_inventory(
            root=resolved_root,
            bundle_path=bundle_path,
            spec=spec,
        )
        if product["product_id"] != product_id:
            raise EvidenceError("prebuilt referenced product identity changed")
        product_records.append(product)
        for record in files:
            existing = unique_file_records.get(record["artifact_id"])
            if existing is not None and existing != record:
                raise EvidenceError("prebuilt referenced file inventory disagrees")
            unique_file_records[record["artifact_id"]] = record
    if (
        not unique_file_records
        or len(unique_file_records) > MAX_PREBUILT_REFERENCED_REGULAR_FILES
    ):
        raise EvidenceError("prebuilt referenced file inventory is empty or unbounded")
    unique_files = sorted(
        unique_file_records.values(),
        key=lambda record: record["artifact_id"],
    )
    referenced_bytes = sum(record["byte_count"] for record in unique_files)
    if referenced_bytes > MAX_PREBUILT_REFERENCED_BYTES:
        raise EvidenceError("prebuilt referenced file inventory is unbounded")
    xctestrun_records.sort(key=lambda record: record["artifact_id"])
    product_records.sort(key=lambda record: record["product_id"])
    referenced_files_manifest_sha256 = hashlib.sha256(
        _canonical_json(unique_files).encode("utf-8")
    ).hexdigest()
    manifest_material = {
        "destination_architecture": "arm64",
        "xctestrun_selection_policy": "locked_simulator_sdk_arm64",
        "xctestrun_files": xctestrun_records,
        "referenced_products": product_records,
        "referenced_regular_file_count": len(unique_files),
        "referenced_regular_file_byte_count": referenced_bytes,
        "referenced_files_manifest_sha256": referenced_files_manifest_sha256,
    }
    return {
        "schema_version": SCHEMA_VERSION,
        "root_kind": "cached_derived_data_build_products",
        "destination_architecture": "arm64",
        "xctestrun_selection_policy": "locked_simulator_sdk_arm64",
        "xctestrun_count": len(xctestrun_records),
        "xctestrun_files": xctestrun_records,
        "referenced_product_count": len(product_records),
        "referenced_products": product_records,
        "runnable_executable_count": len(product_records),
        "referenced_regular_file_count": len(unique_files),
        "referenced_regular_file_byte_count": referenced_bytes,
        "referenced_files_manifest_sha256": referenced_files_manifest_sha256,
        "manifest_sha256": hashlib.sha256(
            _canonical_json(manifest_material).encode("utf-8")
        ).hexdigest(),
        "contains_paths": False,
    }


def run_build_for_testing_session(
    *,
    simulator_id: str,
    build_command: Sequence[str],
    receipt_output: Path,
    build_products_root: Path = DEFAULT_XCODE_BUILD_PRODUCTS_ROOT,
    command_runner: Callable[..., subprocess.CompletedProcess[Any]] = subprocess.run,
) -> dict[str, Any]:
    _assert_locked_simulator(simulator_id)
    preflight = validate_build_for_testing_command(build_command)
    receipt_output = Path(receipt_output)
    try:
        receipt_parent_is_directory = receipt_output.parent.resolve(
            strict=True
        ).is_dir()
    except (FileNotFoundError, OSError):
        receipt_parent_is_directory = False
    if (
        not receipt_output.is_absolute()
        or ".." in receipt_output.parts
        or os.path.lexists(receipt_output)
        or not receipt_parent_is_directory
    ):
        raise EvidenceError("prebuild receipt must be a new absolute output")
    lock_fd: int | None = None
    owned_lock_inode: int | None = None
    try:
        flags = os.O_CREAT | os.O_EXCL | os.O_WRONLY
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        try:
            lock_fd = os.open(PREBUILD_LOCK_PATH, flags, 0o600)
        except FileExistsError as error:
            raise EvidenceError("another prebuild owns the single-device build lock") from error
        owned_lock_inode = os.fstat(lock_fd).st_ino
        os.write(lock_fd, f"pid={os.getpid()}\n".encode("ascii"))
        if os.path.lexists(CAPTURE_LOCK_PATH):
            raise EvidenceError("a recorder is active; prebuild is forbidden")
        completed = command_runner(
            list(build_command),
            stdin=subprocess.DEVNULL,
            shell=False,
            check=False,
        )
        if completed.returncode != 0:
            raise EvidenceError("build-for-testing failed")
        products = collect_prebuilt_build_products(build_products_root)
        receipt = {
            "schema_version": SCHEMA_VERSION,
            "status": "success",
            "build_for_testing": True,
            "build_command_sha256": preflight["command_sha256"],
            "build_compatibility_sha256": preflight[
                "build_compatibility_sha256"
            ],
            "simulator_udid": LOCKED_SIMULATOR_ID,
            "profile": preflight["profile"],
            "selector_count": 1,
            "test_selector": preflight["test_selector"],
            "matrix_route_code": preflight["matrix_route_code"],
            "fixture_scenario": preflight["fixture_scenario"],
            "worker_job_limit": 1,
            "parallel_testing_disabled": True,
            "test_diagnostics_collection_disabled": True,
            "fixture_bundle_identifier": PERFORMANCE_APP_BUNDLE_IDENTIFIER,
            "build_products": products,
            "contains_paths": False,
        }
        _write_new_json(receipt_output, receipt)
        return receipt
    finally:
        if lock_fd is not None:
            os.close(lock_fd)
        if owned_lock_inode is not None:
            try:
                if PREBUILD_LOCK_PATH.lstat().st_ino == owned_lock_inode:
                    PREBUILD_LOCK_PATH.unlink()
            except FileNotFoundError:
                pass


def validate_prebuilt_build_receipt(
    receipt_path: Path,
    *,
    expected_test_preflight: Mapping[str, Any],
    build_products_root: Path = DEFAULT_XCODE_BUILD_PRODUCTS_ROOT,
) -> dict[str, Any]:
    receipt_path = Path(receipt_path)
    if (
        not receipt_path.is_absolute()
        or ".." in receipt_path.parts
        or receipt_path.is_symlink()
        or not receipt_path.is_file()
    ):
        raise EvidenceError("prebuilt build receipt must be an exact regular file")
    receipt = _load_json(receipt_path, "prebuilt build receipt")
    expected_keys = {
        "schema_version",
        "status",
        "build_for_testing",
        "build_command_sha256",
        "build_compatibility_sha256",
        "simulator_udid",
        "profile",
        "selector_count",
        "test_selector",
        "matrix_route_code",
        "fixture_scenario",
        "worker_job_limit",
        "parallel_testing_disabled",
        "test_diagnostics_collection_disabled",
        "fixture_bundle_identifier",
        "build_products",
        "contains_paths",
    }
    if not isinstance(receipt, dict) or set(receipt) != expected_keys:
        raise EvidenceError("prebuilt build receipt uses an unsupported schema")
    expected_binding = _closed_route_binding(expected_test_preflight)
    if (
        receipt.get("schema_version") != SCHEMA_VERSION
        or receipt.get("status") != "success"
        or receipt.get("build_for_testing") is not True
        or receipt.get("simulator_udid") != LOCKED_SIMULATOR_ID
        or receipt.get("profile") != "isolated_chat_performance_fixture"
        or receipt.get("selector_count") != 1
        or receipt.get("worker_job_limit") != 1
        or receipt.get("parallel_testing_disabled") is not True
        or receipt.get("test_diagnostics_collection_disabled") is not True
        or receipt.get("fixture_bundle_identifier")
        != PERFORMANCE_APP_BUNDLE_IDENTIFIER
        or receipt.get("contains_paths") is not False
        or _closed_route_binding(receipt) != expected_binding
        or receipt.get("build_compatibility_sha256")
        != expected_test_preflight.get("build_compatibility_sha256")
        or not re.fullmatch(
            r"[0-9a-f]{64}", str(receipt.get("build_command_sha256"))
        )
    ):
        raise EvidenceError("prebuilt build receipt is incompatible with the no-build test")
    try:
        current_products = collect_prebuilt_build_products(build_products_root)
    except EvidenceError as error:
        raise EvidenceError(
            "prebuilt build products changed after build-for-testing"
        ) from error
    if receipt.get("build_products") != current_products:
        raise EvidenceError("prebuilt build products changed after build-for-testing")
    validated = dict(receipt)
    validated["receipt_sha256"] = sha256_file(receipt_path)
    return validated


def validate_test_command(
    command: Sequence[str],
    *,
    expected_signpost_output: Path | None = None,
    expected_marker_event_output: Path | None = None,
    expected_data_container: Path | None = None,
) -> dict[str, Any]:
    if not command or not all(isinstance(argument, str) and argument for argument in command):
        raise EvidenceError("test command must be a non-empty JSON string array")
    command = list(command)
    _validate_non_destructive_fixture_command(command)

    fixed_prefix = [
        "/usr/bin/env",
        "-u",
        "TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT",
        "-u",
        "TEST_RUNNER_XABBER_ISOLATED_STORAGE",
        "-u",
        "XABBER_CHAT_LIVE_QA_MODE",
        "XABBER_SCHEME=Chat Performance UI Tests",
        f"XABBER_DESTINATION=platform=iOS Simulator,id={LOCKED_SIMULATOR_ID}",
    ]
    if command[: len(fixed_prefix)] != fixed_prefix:
        raise EvidenceError("test command is outside the approved isolated fixture grammar")
    if len(command) < len(fixed_prefix) + 14:
        raise EvidenceError("test command is missing required sequential fixture fields")
    data_container_index = len(fixed_prefix)
    signpost_output_index = data_container_index + 1
    marker_event_output_index = data_container_index + 2
    data_container = _data_container_from_assignment(command[data_container_index])
    signpost_output = _export_path_from_assignment(
        command[signpost_output_index], "XABBER_CHAT_SIGNPOST_EXPORT_PATH"
    )
    marker_event_output = _export_path_from_assignment(
        command[marker_event_output_index],
        "XABBER_CHAT_VIDEO_CALIBRATION_EXPORT_PATH",
    )
    if signpost_output == marker_event_output:
        raise EvidenceError("test command export outputs must be distinct")
    if expected_signpost_output is not None and signpost_output != Path(
        expected_signpost_output
    ):
        raise EvidenceError("test command signpost output does not match capture declaration")
    if expected_marker_event_output is not None and marker_event_output != Path(
        expected_marker_event_output
    ):
        raise EvidenceError("test command marker-event output does not match capture declaration")
    approved_container_path_fragments: dict[int, str] = {}
    if expected_data_container is not None:
        expected_container = Path(expected_data_container).resolve(strict=True)
        if data_container != expected_container:
            raise EvidenceError(
                "test command data container does not match the locked performance app"
            )
        verified_container_path = command[data_container_index].split("=", 1)[1]
        approved_container_path_fragments[data_container_index] = verified_container_path
        if expected_signpost_output is not None:
            approved_container_path_fragments[signpost_output_index] = verified_container_path
        if expected_marker_event_output is not None:
            approved_container_path_fragments[marker_event_output_index] = verified_container_path
    _require_output_inside_data_container(signpost_output, data_container)
    _require_output_inside_data_container(marker_event_output, data_container)
    _relative_runtime_export_path(signpost_output, data_container)
    _relative_runtime_export_path(marker_event_output, data_container)
    _validate_uuid_tokens(
        command,
        approved_container_path_fragments=approved_container_path_fragments,
    )

    cursor = marker_event_output_index + 1
    test_selector, route = _validate_closed_xcode_action_tail(
        command,
        cursor=cursor,
        action="test-without-building",
    )
    preflight = _fixture_action_preflight(
        command,
        action="test-without-building",
        test_selector=test_selector,
        route=route,
    )
    preflight["app_data_container_verified"] = expected_data_container is not None
    return preflight


def validate_capture_command(
    simulator_id: str,
    raw_output: Path,
    command: Sequence[str],
    *,
    window_snapshot_provider: Callable[[int], dict[str, Any]] = collect_native_window_snapshot,
) -> dict[str, Any]:
    _assert_locked_simulator(simulator_id)
    raw_output = Path(raw_output)
    if not raw_output.is_absolute():
        raise EvidenceError("raw capture output must be an absolute path")
    if os.path.lexists(raw_output):
        raise EvidenceError("raw capture output already exists; overwrite is forbidden")
    if not raw_output.parent.is_dir():
        raise EvidenceError("raw capture output parent must already exist")
    if not command or not all(isinstance(argument, str) and argument for argument in command):
        raise EvidenceError("capture command must be a non-empty JSON string array")
    command = list(command)
    _validate_uuid_tokens(command)
    if str(raw_output) not in command:
        raise EvidenceError("capture command must use the declared raw output exactly")

    executable = command[0]
    result: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "simulator_lock": "C302-only",
        "command_sha256": hashlib.sha256(_canonical_json(command).encode("utf-8")).hexdigest(),
        "requested_fps_supported": False,
        "native_60_proven": False,
        "rate_must_be_measured_by_ffprobe": True,
        "raw_overwrite_forbidden": True,
        "contains_paths": False,
    }

    if executable == "/usr/sbin/screencapture":
        raise EvidenceError(
            "screencapture does not provide a persistent window video recorder"
        )

    if executable == "/usr/bin/swift":
        if len(command) != 6:
            raise EvidenceError("native window recorder command uses an unsupported grammar")
        if command[1] != str(BUNDLED_WINDOW_RECORDER_SOURCE):
            raise EvidenceError("native window recorder must use the bundled Swift source")
        source = BUNDLED_WINDOW_RECORDER_SOURCE
        if (
            not source.is_file()
            or source.is_symlink()
            or source.resolve(strict=True) != BUNDLED_WINDOW_RECORDER_SOURCE.resolve(strict=True)
        ):
            raise EvidenceError("bundled native window recorder source is unavailable")
        if command[2] != "--window-id" or not command[3].isdigit():
            raise EvidenceError("native window recorder requires a numeric window target")
        window_id = int(command[3])
        if window_id <= 0:
            raise EvidenceError("native window recorder window target must be positive")
        if command[4:] != ["--output", str(raw_output)]:
            raise EvidenceError("native window recorder raw output must be exact")
        window_snapshot = window_snapshot_provider(window_id)
        window_provenance = validate_native_window_snapshot(window_snapshot, window_id)
        result.update(
            {
                "capture_backend": "native_window",
                "capture_backend_implementation": "screencapturekit",
                "window_id": window_id,
                "window_provenance": window_provenance,
                "recorder_source_sha256": sha256_file(source),
                "requested_fps_supported": False,
                "static_capability": (
                    "ScreenCaptureKit desktop-independent window H264 MOV; "
                    "stream rate must be measured"
                ),
            }
        )
        return result

    if executable == BUNDLED_AXE_PATH:
        if len(command) != 7 or command[1] != "record-video":
            raise EvidenceError("AXe command must use the closed record-video grammar")
        try:
            udid = command[command.index("--udid") + 1]
            fps = int(command[command.index("--fps") + 1])
        except (ValueError, IndexError) as error:
            raise EvidenceError("AXe command must include --udid and --fps") from error
        if udid != LOCKED_SIMULATOR_ID:
            raise EvidenceError("AXe command must target the locked simulator")
        if not 1 <= fps <= 30:
            raise EvidenceError("AXe supports only 1-30 FPS; requested FPS is not proof")
        if command != [
            BUNDLED_AXE_PATH,
            "record-video",
            "--udid",
            LOCKED_SIMULATOR_ID,
            "--fps",
            str(fps),
            str(raw_output),
        ]:
            raise EvidenceError("AXe command is outside the closed capture grammar")
        result.update(
            {
                "capture_backend": "axe",
                "requested_fps": fps,
                "requested_fps_supported": True,
                "maximum_declared_fps": 30,
                "requested_fps_accepted_as_rate_proof": False,
            }
        )
        return result

    if executable == "/usr/bin/xcrun":
        required = [
            "/usr/bin/xcrun",
            "simctl",
            "io",
            LOCKED_SIMULATOR_ID,
            "recordVideo",
            str(raw_output),
        ]
        if command != required:
            raise EvidenceError("simctl command must explicitly record the locked simulator")
        result.update(
            {
                "capture_backend": "simctl",
                "requested_fps_supported": False,
                "static_capability": "variable-rate until measured",
            }
        )
        return result

    raise EvidenceError("capture executable is outside the closed allowlist")


def _parse_command_json(value: str, label: str) -> list[str]:
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError as error:
        raise EvidenceError(f"{label} must be valid JSON") from error
    if not isinstance(parsed, list) or not all(
        isinstance(argument, str) and argument for argument in parsed
    ):
        raise EvidenceError(f"{label} must be a JSON string array")
    return parsed


def _stop_process(process: subprocess.Popen[Any], grace_seconds: float = 10.0) -> None:
    if process.poll() is not None:
        return
    try:
        process.send_signal(signal.SIGINT)
    except ProcessLookupError:
        process.wait()
        return
    try:
        process.wait(timeout=grace_seconds)
        return
    except subprocess.TimeoutExpired:
        try:
            process.terminate()
        except ProcessLookupError:
            process.wait()
            return
    try:
        process.wait(timeout=5.0)
        return
    except subprocess.TimeoutExpired:
        try:
            process.kill()
        except ProcessLookupError:
            pass
        process.wait()


def _wait_for_window_recorder_ready(
    process: subprocess.Popen[Any], timeout_seconds: float = 15.0
) -> None:
    stream = process.stdout
    if stream is None:
        raise EvidenceError("native window recorder has no readiness channel")
    diagnostic_stream = process.stderr
    diagnostic_bytes = bytearray()

    def collect_diagnostic(chunk: bytes) -> None:
        remaining = (
            MAX_WINDOW_RECORDER_STARTUP_DIAGNOSTIC_BYTES
            - len(diagnostic_bytes)
        )
        if remaining > 0:
            diagnostic_bytes.extend(chunk[:remaining])

    def startup_code() -> str:
        for line in bytes(diagnostic_bytes).splitlines():
            if not line.startswith(WINDOW_RECORDER_STARTUP_ERROR_PREFIX):
                continue
            candidate = line[len(WINDOW_RECORDER_STARTUP_ERROR_PREFIX) :]
            try:
                decoded = candidate.decode("ascii")
            except UnicodeDecodeError:
                continue
            if decoded in WINDOW_RECORDER_STARTUP_ERROR_CODES:
                return decoded
        return "unavailable"

    def readiness_error(message: str) -> EvidenceError:
        return EvidenceError(f"{message}; startup-code={startup_code()}")

    selector = selectors.DefaultSelector()
    try:
        selector.register(stream, selectors.EVENT_READ, "readiness")
        diagnostic_registered = diagnostic_stream is not None
        if diagnostic_registered:
            selector.register(diagnostic_stream, selectors.EVENT_READ, "diagnostic")
        deadline = time.monotonic() + timeout_seconds
        received = bytearray()
        readiness_closed = False
        while len(received) < len(WINDOW_RECORDER_READY_RECORD):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise readiness_error("native window recorder readiness timed out")
            events = selector.select(remaining)
            if not events:
                raise readiness_error("native window recorder readiness timed out")
            for key, _mask in events:
                if key.data == "diagnostic":
                    chunk = os.read(key.fileobj.fileno(), 64 * 1024)
                    if chunk:
                        collect_diagnostic(chunk)
                    else:
                        selector.unregister(key.fileobj)
                        diagnostic_registered = False
                    continue
                chunk = os.read(
                    stream.fileno(),
                    len(WINDOW_RECORDER_READY_RECORD) - len(received),
                )
                if chunk:
                    received.extend(chunk)
                else:
                    selector.unregister(stream)
                    readiness_closed = True
            if readiness_closed and len(received) < len(WINDOW_RECORDER_READY_RECORD):
                try:
                    process.wait(timeout=0.25)
                except subprocess.TimeoutExpired:
                    pass
                while diagnostic_registered:
                    pending = selector.select(0)
                    if not pending:
                        break
                    diagnostic_events = [
                        key for key, _mask in pending if key.data == "diagnostic"
                    ]
                    if not diagnostic_events:
                        break
                    for key in diagnostic_events:
                        chunk = os.read(key.fileobj.fileno(), 64 * 1024)
                        if chunk:
                            collect_diagnostic(chunk)
                        else:
                            selector.unregister(key.fileobj)
                            diagnostic_registered = False
                raise readiness_error(
                    "native window recorder closed its readiness channel"
                )
            if process.poll() is not None and len(received) < len(
                WINDOW_RECORDER_READY_RECORD
            ):
                raise readiness_error("native window recorder exited before readiness")
        if bytes(received) != WINDOW_RECORDER_READY_RECORD:
            raise readiness_error(
                "native window recorder emitted an invalid readiness record"
            )
    finally:
        selector.close()
        stream.close()
        if diagnostic_stream is not None:
            diagnostic_stream.close()


class _BoundedStreamCollector:
    def __init__(self, stream: Any, limit: int = MAX_CAPTURE_LOG_BYTES):
        self.stream = stream
        self.limit = limit
        self.buffer = bytearray()
        self.total_bytes = 0
        self.error: Exception | None = None
        self.thread = threading.Thread(target=self._drain, daemon=True)

    def _drain(self) -> None:
        try:
            while True:
                chunk = self.stream.read(64 * 1024)
                if not chunk:
                    return
                if not isinstance(chunk, bytes):
                    chunk = bytes(chunk)
                self.total_bytes += len(chunk)
                remaining = self.limit - len(self.buffer)
                if remaining > 0:
                    self.buffer.extend(chunk[:remaining])
        except Exception as error:  # pragma: no cover - defensive process boundary
            self.error = error

    def start(self) -> None:
        self.thread.start()

    def finish(self) -> tuple[bytes, int]:
        self.thread.join(timeout=15.0)
        if self.thread.is_alive():
            raise EvidenceError("test log collector did not reach EOF")
        if self.error is not None:
            raise EvidenceError("test log collector failed") from self.error
        return bytes(self.buffer), self.total_bytes


def run_capture_session(
    *,
    simulator_id: str,
    raw_output: Path,
    capture_command: Sequence[str],
    test_command: Sequence[str],
    timeout_seconds: float,
    capture_evidence_directory: Path,
    signpost_export_path: Path,
    marker_event_export_path: Path,
    build_receipt_path: Path,
    window_snapshot_provider: Callable[[int], dict[str, Any]] = collect_native_window_snapshot,
    app_data_container_resolver: Callable[[str, str], Path] =
        resolve_performance_app_data_container,
    build_products_root: Path = DEFAULT_XCODE_BUILD_PRODUCTS_ROOT,
    recorder_ready_waiter: Callable[[subprocess.Popen[Any], float], None] =
        _wait_for_window_recorder_ready,
    process_spawner: Callable[..., subprocess.Popen[Any]] = subprocess.Popen,
) -> dict[str, Any]:
    """Serialize one capture and finalize it for every test exit path."""

    if timeout_seconds <= 0:
        raise EvidenceError("capture timeout must be positive")
    raw_output = Path(raw_output)
    capture_evidence_directory = Path(capture_evidence_directory)
    signpost_export_path = Path(signpost_export_path)
    marker_event_export_path = Path(marker_event_export_path)
    declared_paths = [raw_output, signpost_export_path, marker_event_export_path]
    resolved_declared_paths = [
        path.parent.resolve(strict=True) / path.name for path in declared_paths
    ]
    if (
        not all(path.is_absolute() and ".." not in path.parts for path in declared_paths)
        or len(set(resolved_declared_paths)) != 3
    ):
        raise EvidenceError("capture raw/signpost/marker-event outputs must be absolute and distinct")
    if os.path.lexists(capture_evidence_directory):
        raise EvidenceError("capture evidence directory already exists")
    if not capture_evidence_directory.parent.is_dir():
        raise EvidenceError("capture evidence parent must already exist")
    preflight = validate_capture_command(
        simulator_id,
        raw_output,
        capture_command,
        window_snapshot_provider=window_snapshot_provider,
    )
    app_data_container = Path(app_data_container_resolver(
        simulator_id,
        PERFORMANCE_APP_BUNDLE_IDENTIFIER,
    )).resolve(strict=True)
    test_preflight = validate_test_command(
        test_command,
        expected_signpost_output=signpost_export_path,
        expected_marker_event_output=marker_event_export_path,
        expected_data_container=app_data_container,
    )
    prebuilt = validate_prebuilt_build_receipt(
        build_receipt_path,
        expected_test_preflight=test_preflight,
        build_products_root=build_products_root,
    )
    test_preflight.update(
        {
            "prebuilt_build_receipt_sha256": prebuilt["receipt_sha256"],
            "prebuilt_build_command_sha256": prebuilt["build_command_sha256"],
            "prebuilt_build_products_manifest_sha256": prebuilt["build_products"][
                "manifest_sha256"
            ],
            "prebuilt_binary_provenance_closed": True,
            "prebuilt_destination_architecture": prebuilt["build_products"][
                "destination_architecture"
            ],
            "prebuilt_xctestrun_selection_policy": prebuilt["build_products"][
                "xctestrun_selection_policy"
            ],
            "prebuilt_xctestrun_count": prebuilt["build_products"][
                "xctestrun_count"
            ],
            "prebuilt_referenced_product_count": prebuilt["build_products"][
                "referenced_product_count"
            ],
            "prebuilt_runnable_executable_count": prebuilt["build_products"][
                "runnable_executable_count"
            ],
            "prebuilt_referenced_regular_file_count": prebuilt[
                "build_products"
            ]["referenced_regular_file_count"],
            "prebuilt_referenced_regular_file_byte_count": prebuilt[
                "build_products"
            ]["referenced_regular_file_byte_count"],
            "prebuilt_referenced_files_manifest_sha256": prebuilt[
                "build_products"
            ]["referenced_files_manifest_sha256"],
        }
    )
    relative_signpost_export = _relative_runtime_export_path(
        signpost_export_path,
        app_data_container,
    )
    relative_marker_event_export = _relative_runtime_export_path(
        marker_event_export_path,
        app_data_container,
    )
    expected_runtime_exports = _route_bound_runtime_export_paths(
        test_preflight["matrix_route_code"]
    )
    if (
        relative_signpost_export,
        relative_marker_event_export,
    ) != expected_runtime_exports:
        raise EvidenceError(
            "artifact export filenames do not match the selected video route"
        )
    raw_partial = _partial_path(raw_output)
    runtime_capture_command = [
        str(raw_partial) if argument == str(raw_output) else argument
        for argument in capture_command
    ]
    lock_fd: int | None = None
    owned_lock_inode: int | None = None
    capture: subprocess.Popen[Any] | None = None
    test: subprocess.Popen[Any] | None = None
    test_log_collector: _BoundedStreamCollector | None = None
    test_log = b""
    total_test_log_bytes = 0
    test_returncode: int | None = None
    test_spawn_before_epoch_nanoseconds: int | None = None
    timed_out = False
    cancelled = False
    pending_error: Exception | None = None
    previous_signal_handlers: dict[signal.Signals, Any] = {}

    def cancel_capture(signum: int, _frame: Any) -> None:
        raise _CaptureCancelled(signum)

    try:
        for signal_name in ("SIGINT", "SIGTERM", "SIGHUP"):
            candidate = getattr(signal, signal_name, None)
            if candidate is None:
                continue
            previous_signal_handlers[candidate] = signal.getsignal(candidate)
            signal.signal(candidate, cancel_capture)
        flags = os.O_CREAT | os.O_EXCL | os.O_WRONLY
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        try:
            lock_fd = os.open(CAPTURE_LOCK_PATH, flags, 0o600)
        except FileExistsError as error:
            raise EvidenceError("another recorder owns the single-device capture lock") from error
        owned_lock_inode = os.fstat(lock_fd).st_ino
        os.write(lock_fd, f"pid={os.getpid()}\n".encode("ascii"))
        if os.path.lexists(PREBUILD_LOCK_PATH):
            raise EvidenceError("a prebuild is active; recorder start is forbidden")
        if os.path.lexists(raw_output):
            raise EvidenceError("raw capture output appeared before recording")

        measured_preflight = validate_capture_command(
            simulator_id,
            raw_output,
            capture_command,
            window_snapshot_provider=window_snapshot_provider,
        )
        if measured_preflight.get("command_sha256") != preflight.get("command_sha256"):
            raise EvidenceError("capture command changed between preflight measurements")
        if measured_preflight.get("recorder_source_sha256") != preflight.get(
            "recorder_source_sha256"
        ):
            raise EvidenceError("native recorder source changed between preflight measurements")
        preflight = measured_preflight
        final_prebuilt = validate_prebuilt_build_receipt(
            build_receipt_path,
            expected_test_preflight=test_preflight,
            build_products_root=build_products_root,
        )
        if final_prebuilt != prebuilt:
            raise EvidenceError("prebuilt build products changed before recorder start")
        preflight["capture_spawn_before_monotonic_nanoseconds"] = time.monotonic_ns()

        try:
            requires_readiness = (
                preflight.get("capture_backend_implementation") == "screencapturekit"
            )
            capture = process_spawner(
                runtime_capture_command,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE if requires_readiness else subprocess.DEVNULL,
                stderr=subprocess.PIPE if requires_readiness else subprocess.DEVNULL,
                shell=False,
            )
            preflight["capture_spawn_after_monotonic_nanoseconds"] = time.monotonic_ns()
        except OSError as error:
            raise EvidenceError("capture process failed to start") from error
        if requires_readiness:
            recorder_ready_waiter(capture, 15.0)
        else:
            time.sleep(0.25)
        if capture.poll() is not None:
            raise EvidenceError("capture process exited before the test started")
        try:
            test_spawn_before_epoch_nanoseconds = time.time_ns()
            test = process_spawner(
                list(test_command),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                shell=False,
            )
            if test.stdout is None:
                raise EvidenceError("test process did not expose a capturable log stream")
            test_log_collector = _BoundedStreamCollector(test.stdout)
            test_log_collector.start()
        except OSError as error:
            raise EvidenceError("test process failed to start") from error
        deadline = time.monotonic() + timeout_seconds
        while True:
            test_returncode = test.poll()
            if test_returncode is not None:
                break
            if capture.poll() is not None:
                _stop_process(test, grace_seconds=5.0)
                test_returncode = test.returncode
                raise EvidenceError("capture process exited before the test completed")
            if time.monotonic() >= deadline:
                timed_out = True
                _stop_process(test, grace_seconds=5.0)
                test_returncode = test.returncode
                break
            time.sleep(0.05)
    except _CaptureCancelled:
        cancelled = True
    except Exception as error:
        pending_error = error
    finally:
        if test is not None and test.poll() is None:
            _stop_process(test, grace_seconds=5.0)
        if test_log_collector is not None:
            try:
                test_log, total_test_log_bytes = (
                    test_log_collector.finish()
                )
            except Exception as error:
                if pending_error is None:
                    pending_error = error
        if capture is not None:
            _stop_process(capture)
        if lock_fd is not None:
            os.close(lock_fd)
            lock_fd = None
        if owned_lock_inode is not None:
            try:
                if CAPTURE_LOCK_PATH.lstat().st_ino == owned_lock_inode:
                    CAPTURE_LOCK_PATH.unlink()
            except FileNotFoundError:
                pass
        for captured_signal, previous_handler in previous_signal_handlers.items():
            signal.signal(captured_signal, previous_handler)

    if raw_partial.is_file() and raw_partial.stat().st_size > 0:
        try:
            _publish_file_no_overwrite(raw_partial, raw_output)
        except Exception as error:
            if pending_error is None:
                pending_error = error
    elif capture is not None and pending_error is None:
        pending_error = EvidenceError("capture did not finalize a non-empty raw artifact")

    runtime_stage_directory = (
        capture_evidence_directory.parent
        / f".chat-open-runtime-exports-{uuid.uuid4().hex}"
    )
    staged_signpost_export = runtime_stage_directory / "signposts.json"
    staged_marker_event_export = runtime_stage_directory / "marker-events.json"
    owned_runtime_exports: list[tuple[Path, tuple[int, int]]] = []
    missing_staged_exports: list[Path] = []
    os.mkdir(runtime_stage_directory, 0o700)
    try:
        try:
            runtime_data_container = Path(app_data_container_resolver(
                simulator_id,
                PERFORMANCE_APP_BUNDLE_IDENTIFIER,
            )).resolve(strict=True)
            runtime_signpost_export = _runtime_export_path(
                runtime_data_container,
                relative_signpost_export,
            )
            runtime_marker_event_export = _runtime_export_path(
                runtime_data_container,
                relative_marker_event_export,
            )
            test_preflight["runtime_container_reresolved_after_test"] = True
            test_preflight["runtime_container_replaced_during_test"] = (
                runtime_data_container != app_data_container
            )
            for runtime_export, staged_export in (
                (runtime_signpost_export, staged_signpost_export),
                (runtime_marker_event_export, staged_marker_event_export),
            ):
                try:
                    if test_spawn_before_epoch_nanoseconds is None:
                        raise EvidenceError(
                            "runtime artifact ownership has no XCTest spawn boundary"
                        )
                    identity = _stage_owned_runtime_export(
                        runtime_export,
                        staged_export,
                        not_created_before_epoch_nanoseconds=(
                            test_spawn_before_epoch_nanoseconds
                        ),
                    )
                    owned_runtime_exports.append((runtime_export, identity))
                except FileNotFoundError:
                    missing_staged_exports.append(staged_export)
                except Exception as error:
                    missing_staged_exports.append(staged_export)
                    if pending_error is None:
                        pending_error = error
            test_preflight["runtime_exports_staged_from_current_container"] = (
                not missing_staged_exports
            )
        except Exception as error:
            missing_staged_exports = [
                staged_signpost_export,
                staged_marker_event_export,
            ]
            if pending_error is None:
                pending_error = error

        terminal = (
            "cancelled"
            if cancelled
            else "timeout"
            if timed_out
            else "success"
            if test_returncode == 0 and pending_error is None
            else "failure"
        )
        if terminal == "success" and missing_staged_exports:
            pending_error = EvidenceError(
                "successful XCTest did not publish required signpost and marker-event exports"
            )
            terminal = "failure"
        unavailable_exports = {
            staged_signpost_export: {
                "schema_version": SCHEMA_VERSION,
                "phase_manifest_sha256": "0" * 64,
                "phase_count": 0,
                "records": [],
                "capture_terminal": terminal,
                "available": False,
            },
            staged_marker_event_export: {
                "schema_version": SCHEMA_VERSION,
                "marker_manifest_sha256": MARKER_MANIFEST_SHA256,
                "events": [],
                "capture_terminal": terminal,
                "available": False,
            },
        }
        for staged_export in missing_staged_exports:
            if not staged_export.exists():
                try:
                    _write_new_json(
                        staged_export,
                        unavailable_exports[staged_export],
                    )
                except Exception as error:
                    if pending_error is None:
                        pending_error = error

        capture_artifacts: dict[str, Any] | None = None
        if raw_output.is_file() and raw_output.stat().st_size > 0:
            try:
                capture_artifacts = finalize_capture_evidence(
                    output_directory=capture_evidence_directory,
                    raw_path=raw_output,
                    test_log=test_log,
                    total_test_log_bytes=total_test_log_bytes,
                    signpost_export_path=staged_signpost_export,
                    marker_event_export_path=staged_marker_event_export,
                    terminal=terminal,
                    capture_preflight=preflight,
                    test_preflight=test_preflight,
                )
            except Exception as error:
                if pending_error is None:
                    pending_error = error
    finally:
        for runtime_export, identity in owned_runtime_exports:
            _remove_owned_runtime_export(runtime_export, identity)
        if runtime_stage_directory.is_dir():
            shutil.rmtree(runtime_stage_directory)

    if pending_error is not None:
        if isinstance(pending_error, EvidenceError):
            raise pending_error
        raise EvidenceError("capture workflow failed after recorder finalization") from pending_error
    if not raw_output.is_file() or raw_output.stat().st_size == 0:
        raise EvidenceError("capture did not finalize a non-empty raw artifact")
    raw_hash = sha256_file(raw_output)
    result = {
        **preflight,
        "capture_finalized": True,
        "raw_artifact_id": f"sha256:{raw_hash[:16]}",
        "raw_sha256": raw_hash,
        "test_exit_status": terminal,
        "capture_evidence_preserved": capture_artifacts is not None,
        "capture_artifact_manifest_sha256": (
            capture_artifacts.get("artifact_manifest_sha256")
            if capture_artifacts is not None
            else None
        ),
    }
    if cancelled:
        raise EvidenceError("capture was cancelled; raw artifact was finalized and preserved")
    if timed_out:
        raise EvidenceError("test timed out; raw capture was finalized and preserved")
    if test_returncode != 0:
        raise EvidenceError("test failed; raw capture was finalized and preserved")
    return result


def _write_new_json(path: Path, value: Any) -> None:
    with path.open("x", encoding="utf-8", newline="\n") as handle:
        json.dump(value, handle, indent=2, sort_keys=True, ensure_ascii=True)
        handle.write("\n")


def _write_new_text(path: Path, value: str) -> None:
    with path.open("x", encoding="utf-8", newline="\n") as handle:
        handle.write(value)


def _artifact_record(path: Path) -> dict[str, Any]:
    path = Path(path)
    _require_regular_file(path, "evidence authority")
    if path.is_symlink():
        raise EvidenceError("evidence authorities must not be symbolic links")
    digest = sha256_file(path)
    return {
        "artifact_id": f"sha256:{digest[:16]}",
        "sha256": digest,
        "byte_count": path.stat().st_size,
    }


def build_artifact_manifest(
    authorities: Mapping[str, Path],
    *,
    collision_files: Sequence[Path],
    phase_manifest_sha256: str,
    route_binding: Mapping[str, Any],
) -> dict[str, Any]:
    if not isinstance(authorities, Mapping) or not authorities:
        raise EvidenceError("artifact manifest requires named authorities")
    if not re.fullmatch(r"[0-9a-f]{64}", str(phase_manifest_sha256)):
        raise EvidenceError("artifact manifest phase contract hash is invalid")
    closed_route_binding = _closed_route_binding(route_binding)
    capture_roles = {
        "raw",
        "test_log",
        "signposts",
        "marker_events",
        "capture_receipt",
    }
    final_roles = {
        "raw",
        "derivative",
        "sidecar",
        "framemd5",
        "classifications",
        "signposts",
        "marker_events",
        "calibration",
        "test_log",
        "capture_receipt",
    }
    authority_roles = set(authorities)
    if authority_roles == capture_roles:
        manifest_stage = "capture"
    elif authority_roles == final_roles:
        manifest_stage = "final"
    else:
        raise EvidenceError("artifact manifest roles do not match capture or final stage")
    records = {
        role: _artifact_record(Path(path))
        for role, path in sorted(authorities.items())
    }
    collision_records: list[dict[str, Any]] = []
    seen_names: set[str] = set()
    for ordinal, raw_path in enumerate(
        sorted((Path(path) for path in collision_files), key=lambda path: path.name)
    ):
        if raw_path.name in seen_names or raw_path.name != str(raw_path.name):
            raise EvidenceError("artifact manifest collision filenames must be unique")
        seen_names.add(raw_path.name)
        collision_records.append(
            {"ordinal": ordinal, **_artifact_record(raw_path)}
        )
    collision_set_hash = hashlib.sha256(
        _canonical_json(collision_records).encode("utf-8")
    ).hexdigest()
    unsigned = {
        "schema_version": SCHEMA_VERSION,
        "stage": manifest_stage,
        "phase_manifest_sha256": phase_manifest_sha256,
        "video_route": closed_route_binding,
        "authorities": records,
        "collision_set": {
            "sha256": collision_set_hash,
            "file_count": len(collision_records),
            "files": collision_records,
        },
        "contains_paths": False,
    }
    return {
        **unsigned,
        "artifact_manifest_sha256": hashlib.sha256(
            _canonical_json(unsigned).encode("utf-8")
        ).hexdigest(),
    }


def verify_artifact_manifest(
    expected: dict[str, Any],
    authorities: Mapping[str, Path],
    *,
    collision_files: Sequence[Path],
    phase_manifest_sha256: str,
    route_binding: Mapping[str, Any],
) -> None:
    if not isinstance(expected, dict):
        raise EvidenceError("artifact manifest is not an object")
    actual = build_artifact_manifest(
        authorities,
        collision_files=collision_files,
        phase_manifest_sha256=phase_manifest_sha256,
        route_binding=route_binding,
    )
    if actual != expected:
        raise EvidenceError("artifact manifest does not match current evidence bytes")


class _CaptureLogField(NamedTuple):
    key: str
    key_start: int
    delimiter_index: int
    value_start: int
    key_quote: str | None


def _capture_log_field_before_delimiter(
    text: str,
    delimiter_index: int,
) -> _CaptureLogField | None:
    key_end = delimiter_index
    while key_end > 0 and text[key_end - 1] in " \t":
        key_end -= 1
    if key_end <= 0:
        return None
    key_quote: str | None = None
    key_start: int
    key: str
    if text[key_end - 1] in {'"', "'"}:
        key_quote = text[key_end - 1]
        lower_bound = max(0, key_end - MAX_CAPTURE_LOG_FIELD_KEY_CHARS - 2)
        key_start = text.rfind(key_quote, lower_bound, key_end - 1)
        if key_start < 0:
            return None
        raw_key = text[key_start:key_end]
        if key_quote == '"':
            try:
                decoded_key = json.loads(raw_key)
            except (json.JSONDecodeError, TypeError, ValueError):
                return None
            if not isinstance(decoded_key, str):
                return None
            key = decoded_key
        else:
            key = raw_key[1:-1]
    else:
        lower_bound = max(0, key_end - MAX_CAPTURE_LOG_FIELD_KEY_CHARS)
        key_start = key_end
        while key_start > lower_bound:
            character = text[key_start - 1]
            if not (
                character.isascii()
                and (character.isalnum() or character in "_.-/[] \t")
            ):
                break
            key_start -= 1
        while key_start < key_end and text[key_start] in " \t":
            key_start += 1
        key = text[key_start:key_end]
    if (
        not key
        or len(key) > MAX_CAPTURE_LOG_FIELD_KEY_CHARS
        or CAPTURE_LOG_KEY_PATTERN.fullmatch(key) is None
    ):
        return None
    value_start = delimiter_index + 1
    while value_start < len(text) and text[value_start] in " \t":
        value_start += 1
    return _CaptureLogField(
        key=key,
        key_start=key_start,
        delimiter_index=delimiter_index,
        value_start=value_start,
        key_quote=key_quote,
    )


def _iter_capture_log_fields(text: str) -> Iterable[_CaptureLogField]:
    for index, character in enumerate(text):
        if character not in ":=":
            continue
        field = _capture_log_field_before_delimiter(text, index)
        if field is not None:
            yield field


def _normalized_capture_log_key(value: str) -> str:
    return re.sub(r"[^a-z0-9]", "", value.lower())


def _capture_log_key_is_forbidden(value: str) -> bool:
    normalized = _normalized_capture_log_key(value)
    return any(
        fragment in normalized
        for fragment in CAPTURE_LOG_FORBIDDEN_KEY_FRAGMENTS
    )


def _capture_log_unquoted_value(value: str) -> str:
    stripped = value.strip()
    if (
        len(stripped) >= 2
        and stripped[0] in {'"', "'"}
        and stripped[-1] == stripped[0]
    ):
        return stripped[1:-1]
    return stripped


def _capture_log_value_is_redacted(value: str) -> bool:
    unquoted = _capture_log_unquoted_value(value).strip().lower()
    return unquoted in {
        CAPTURE_LOG_REDACTED_VALUE,
        "<redacted-identity>",
        "<redacted-path>",
        "<redacted-url>",
    }


def _capture_log_value_is_safe_numeric_counter(*, key: str, value: str) -> bool:
    normalized_key = _normalized_capture_log_key(key)
    if (
        not normalized_key.endswith(CAPTURE_LOG_SAFE_NUMERIC_SUFFIXES)
        or any(
            fragment in normalized_key
            for fragment in CAPTURE_LOG_NEVER_NUMERIC_KEY_FRAGMENTS
        )
    ):
        return False
    scalar = value.strip()
    return re.fullmatch(r"-?(?:0|[1-9][0-9]*)", scalar) is not None


def _capture_log_value_end(text: str, start: int) -> int:
    if start >= len(text):
        return start
    opening = text[start]
    if opening in {'"', "'"}:
        escaped = False
        for index in range(start + 1, len(text)):
            character = text[index]
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == opening:
                return index + 1
            elif character in "\r\n":
                return index
        return len(text)
    if opening in "[{":
        expected_closing = {
            "[": "]",
            "{": "}",
        }
        stack = [expected_closing[opening]]
        quote: str | None = None
        escaped = False
        for index in range(start + 1, len(text)):
            character = text[index]
            if quote is not None:
                if escaped:
                    escaped = False
                elif character == "\\":
                    escaped = True
                elif character == quote:
                    quote = None
                continue
            if character in {'"', "'"}:
                quote = character
            elif character in expected_closing:
                stack.append(expected_closing[character])
            elif stack and character == stack[-1]:
                stack.pop()
                if not stack:
                    return index + 1
        return len(text)
    end = start
    while end < len(text) and text[end] not in "\r\n,;}]":
        end += 1
    return end


def _capture_log_multiline_body_end(text: str, start: int) -> int:
    end = _capture_log_value_end(text, start)
    while end < len(text) and text[end] in "\r\n":
        next_start = end
        while next_start < len(text) and text[next_start] in "\r\n":
            next_start += 1
        if next_start >= len(text):
            return len(text)
        field_boundary = min(
            (
                candidate
                for candidate in (
                    text.find(":", next_start, next_start + MAX_CAPTURE_LOG_FIELD_KEY_CHARS + 2),
                    text.find("=", next_start, next_start + MAX_CAPTURE_LOG_FIELD_KEY_CHARS + 2),
                )
                if candidate >= 0
            ),
            default=-1,
        )
        next_field = (
            _capture_log_field_before_delimiter(text, field_boundary)
            if field_boundary >= 0
            else None
        )
        if next_field is not None and next_field.key_start == next_start:
            return end
        next_end = next_start
        while next_end < len(text) and text[next_end] not in "\r\n":
            next_end += 1
        end = next_end
    return end


def _capture_log_redacted_value(value: str, key_quote: str | None) -> str:
    stripped = value.lstrip()
    if stripped.startswith("\""):
        return f'"{CAPTURE_LOG_REDACTED_VALUE}"'
    if stripped.startswith("'"):
        return f"'{CAPTURE_LOG_REDACTED_VALUE}'"
    if (
        key_quote is not None
        or stripped.startswith(("[", "{"))
    ):
        return f'"{CAPTURE_LOG_REDACTED_VALUE}"'
    return CAPTURE_LOG_REDACTED_VALUE


def _privacy_safe_capture_log(value: bytes) -> bytes:
    text = value.decode("utf-8", errors="replace")
    parts: list[str] = []
    output_cursor = 0
    for field in _iter_capture_log_fields(text):
        if field.key_start < output_cursor:
            continue
        key = field.key
        if not _capture_log_key_is_forbidden(key):
            continue
        value_start = field.value_start
        value_end = _capture_log_value_end(text, value_start)
        if (
            "body" in _normalized_capture_log_key(key)
            and value_end < len(text)
            and text[value_end] in "\r\n"
        ):
            value_end = _capture_log_multiline_body_end(text, value_start)
        field_value = text[value_start:value_end]
        if (
            field_value
            and _capture_log_key_is_forbidden(key)
            and not _capture_log_value_is_redacted(field_value)
            and not _capture_log_value_is_safe_numeric_counter(
                key=key,
                value=field_value,
            )
        ):
            parts.append(text[output_cursor:value_start])
            parts.append(_capture_log_redacted_value(field_value, field.key_quote))
            output_cursor = value_end
    parts.append(text[output_cursor:])
    text = "".join(parts)
    text = CAPTURE_LOG_URL_PATTERN.sub("<redacted-url>", text)
    text = CAPTURE_LOG_PATH_PATTERN.sub("<redacted-path>", text)
    text = CAPTURE_LOG_JID_PATTERN.sub("<redacted-identity>", text)
    return text.encode("utf-8")


def _capture_log_partial_json_unescape(value: str) -> tuple[str, bool]:
    """Decode JSON escapes linearly while retaining malformed input for rejection."""

    result: list[str] = []
    index = 0
    complete = True
    simple_escapes = {
        '"': '"',
        "\\": "\\",
        "/": "/",
        "b": "\b",
        "f": "\f",
        "n": "\n",
        "r": "\r",
        "t": "\t",
    }
    while index < len(value):
        character = value[index]
        if character != "\\":
            result.append(character)
            index += 1
            continue
        if index + 1 >= len(value):
            result.append("\\")
            complete = False
            break
        escape = value[index + 1]
        if escape in simple_escapes:
            result.append(simple_escapes[escape])
            index += 2
            continue
        if escape == "u":
            digits = value[index + 2 : index + 6]
            if len(digits) != 4 or re.fullmatch(r"[0-9A-Fa-f]{4}", digits) is None:
                result.append(value[index : min(len(value), index + 6)])
                complete = False
                index += max(2, min(6, len(value) - index))
                continue
            result.append(chr(int(digits, 16)))
            index += 6
            continue
        # A non-JSON escape can be ordinary diagnostic text. Preserve it so a
        # recursive pass cannot reinterpret or silently normalize it.
        result.append("\\")
        result.append(escape)
        index += 2
    return "".join(result), complete


def _capture_log_consume_privacy_budget(
    budget: list[int],
    character_count: int,
) -> bool:
    if character_count < 0 or character_count > budget[0]:
        return False
    budget[0] -= character_count
    return True


def _json_capture_log_value_has_forbidden_private_data(
    value: Any,
    *,
    depth: int,
    budget: list[int],
) -> bool:
    if depth > MAX_CAPTURE_LOG_PRIVACY_DEPTH:
        return True
    if isinstance(value, Mapping):
        if not _capture_log_consume_privacy_budget(budget, len(value)):
            return True
        for raw_key, nested in value.items():
            key = str(raw_key)
            if not _capture_log_consume_privacy_budget(budget, len(key)):
                return True
            if _capture_log_key_is_forbidden(key):
                if isinstance(nested, str) and _capture_log_value_is_redacted(nested):
                    pass
                elif (
                    isinstance(nested, int)
                    and not isinstance(nested, bool)
                    and _capture_log_value_is_safe_numeric_counter(
                        key=key,
                        value=str(nested),
                    )
                ):
                    pass
                else:
                    return True
            if _json_capture_log_value_has_forbidden_private_data(
                nested,
                depth=depth + 1,
                budget=budget,
            ):
                return True
        return False
    if isinstance(value, list):
        if not _capture_log_consume_privacy_budget(budget, len(value)):
            return True
        return any(
            _json_capture_log_value_has_forbidden_private_data(
                nested,
                depth=depth + 1,
                budget=budget,
            )
            for nested in value
        )
    if isinstance(value, str):
        return _capture_log_text_contains_forbidden_private_data(
            value,
            depth=depth + 1,
            budget=budget,
        )
    return False


def _capture_log_text_contains_forbidden_private_data(
    text: str,
    *,
    depth: int,
    budget: list[int],
) -> bool:
    if depth > MAX_CAPTURE_LOG_PRIVACY_DEPTH:
        return True
    if not _capture_log_consume_privacy_budget(budget, len(text)):
        return True
    if (
        CAPTURE_LOG_JID_PATTERN.search(text) is not None
        or CAPTURE_LOG_PATH_PATTERN.search(text) is not None
        or CAPTURE_LOG_URL_PATTERN.search(text) is not None
    ):
        return True

    for field in _iter_capture_log_fields(text):
        if not _capture_log_key_is_forbidden(field.key):
            continue
        value_end = _capture_log_value_end(text, field.value_start)
        field_value = text[field.value_start:value_end]
        if _capture_log_value_is_redacted(field_value):
            continue
        if _capture_log_value_is_safe_numeric_counter(
            key=field.key,
            value=field_value,
        ):
            continue
        return True

    stripped = text.strip()
    if stripped.startswith(("{", "[")):
        try:
            decoded = json.loads(stripped)
        except (json.JSONDecodeError, TypeError, ValueError, RecursionError):
            decoded = None
        if decoded is not None and _json_capture_log_value_has_forbidden_private_data(
            decoded,
            depth=depth + 1,
            budget=budget,
        ):
            return True

    if "\\" in text:
        unescaped, complete = _capture_log_partial_json_unescape(text)
        if not complete:
            return True
        if unescaped != text and _capture_log_text_contains_forbidden_private_data(
            unescaped,
            depth=depth + 1,
            budget=budget,
        ):
            return True
    return False


def _capture_log_contains_forbidden_private_data(value: bytes) -> bool:
    """Scan preserved bytes independently from the redaction implementation."""

    if not isinstance(value, bytes):
        return True
    text = value.decode("utf-8", errors="replace")
    return _capture_log_text_contains_forbidden_private_data(
        text,
        depth=0,
        budget=[MAX_CAPTURE_LOG_PRIVACY_DECODED_CHARACTERS],
    )


def _bounded_privacy_safe_capture_log(
    sanitized: bytes,
    limit: int = MAX_CAPTURE_LOG_BYTES,
) -> tuple[bytes, bool]:
    """Bound a sanitized log without publishing partial UTF-8/redaction tokens."""

    if not isinstance(sanitized, bytes) or isinstance(limit, bool) or limit <= 0:
        raise EvidenceError("captured test log bound is invalid")
    if len(sanitized) <= limit:
        return sanitized, False
    prefix = sanitized[:limit]
    final_newline = prefix.rfind(b"\n")
    if final_newline >= 0:
        return prefix[: final_newline + 1], True
    omission = b"<published-log-line-omitted-at-byte-bound>\n"
    return omission[:limit], True


def _unavailable_signpost_export(terminal: str) -> dict[str, Any]:
    return {
        "schema_version": SCHEMA_VERSION,
        "phase_manifest_sha256": "0" * 64,
        "phase_count": 0,
        "records": [],
        "capture_terminal": terminal,
        "available": False,
    }


def _unavailable_marker_event_export(terminal: str) -> dict[str, Any]:
    return {
        "schema_version": SCHEMA_VERSION,
        "marker_manifest_sha256": MARKER_MANIFEST_SHA256,
        "events": [],
        "capture_terminal": terminal,
        "available": False,
    }


def _is_exact_unavailable_export(
    value: Any,
    *,
    expected: dict[str, Any],
) -> bool:
    return isinstance(value, dict) and value == expected


def _capture_stage_exports(
    *,
    signpost_export_path: Path,
    marker_event_export_path: Path,
    terminal: str,
    test_preflight: Mapping[str, Any],
) -> tuple[dict[str, Any], dict[str, Any], str]:
    """Return only closed-schema exports safe to publish in capture evidence."""

    phase_manifest = load_signpost_phase_manifest(DEFAULT_SIGNPOST_SWIFT_PATH)
    route_binding = _closed_route_binding(test_preflight)
    unavailable_signposts = _unavailable_signpost_export(terminal)
    unavailable_markers = _unavailable_marker_event_export(terminal)
    try:
        raw_signposts = _load_json(signpost_export_path, "captured signpost export")
    except EvidenceError:
        if terminal == "success":
            raise EvidenceError(
                "successful capture numeric signpost export is invalid"
            ) from None
        raw_signposts = unavailable_signposts
    try:
        raw_markers = _load_json(
            marker_event_export_path,
            "captured marker-event export",
        )
    except EvidenceError:
        if terminal == "success":
            raise EvidenceError(
                "successful capture marker-event export is invalid"
            ) from None
        raw_markers = unavailable_markers

    if terminal == "success":
        try:
            validate_numeric_signpost_export_schema(
                raw_signposts,
                phase_manifest=phase_manifest,
                require_records=True,
            )
            if not validate_exported_route_binding(
                raw_signposts,
                expected_test_preflight=test_preflight,
            ):
                raise EvidenceError("successful capture route binding is missing")
        except EvidenceError:
            raise EvidenceError(
                "successful capture numeric signpost export is invalid"
            ) from None
        try:
            validate_marker_events(raw_markers)
        except EvidenceError:
            raise EvidenceError(
                "successful capture marker-event export is invalid"
            ) from None
        return raw_signposts, raw_markers, str(phase_manifest["sha256"])

    if _is_exact_unavailable_export(
        raw_signposts,
        expected=unavailable_signposts,
    ):
        published_signposts = unavailable_signposts
    else:
        try:
            validate_numeric_signpost_export_schema(
                raw_signposts,
                phase_manifest=phase_manifest,
                require_records=False,
            )
            if (
                "matrix_route_code" in raw_signposts
                and not validate_exported_route_binding(
                    raw_signposts,
                    expected_test_preflight=test_preflight,
                )
            ):
                raise EvidenceError("captured signpost route binding is invalid")
            published_signposts = raw_signposts
        except EvidenceError:
            published_signposts = unavailable_signposts

    if _is_exact_unavailable_export(raw_markers, expected=unavailable_markers):
        published_markers = unavailable_markers
    else:
        try:
            validate_marker_events(raw_markers)
            published_markers = raw_markers
        except EvidenceError:
            published_markers = unavailable_markers
    phase_hash = published_signposts.get("phase_manifest_sha256", "0" * 64)
    if not re.fullmatch(r"[0-9a-f]{64}", str(phase_hash)):
        phase_hash = "0" * 64
    return published_signposts, published_markers, str(phase_hash)


def _validate_privacy_safe_capture_log(value: bytes) -> None:
    if _capture_log_contains_forbidden_private_data(value):
        raise EvidenceError("captured test log contains forbidden private data")


def finalize_capture_evidence(
    *,
    output_directory: Path,
    raw_path: Path,
    test_log: bytes,
    total_test_log_bytes: int,
    signpost_export_path: Path,
    marker_event_export_path: Path,
    terminal: str,
    capture_preflight: dict[str, Any],
    test_preflight: dict[str, Any],
) -> dict[str, Any]:
    """Publish bounded audit artifacts even for failed/cancelled captures."""

    output_directory = Path(output_directory)
    raw_path = Path(raw_path)
    signpost_export_path = Path(signpost_export_path)
    marker_event_export_path = Path(marker_event_export_path)
    _require_regular_file(raw_path, "finalized raw capture")
    _require_regular_file(signpost_export_path, "captured signpost export")
    _require_regular_file(marker_event_export_path, "captured marker-event export")
    if terminal not in {"success", "failure", "timeout", "cancelled"}:
        raise EvidenceError("capture terminal is outside the closed enum")
    if os.path.lexists(output_directory) or not output_directory.parent.is_dir():
        raise EvidenceError("capture evidence directory must be a new output")
    if not isinstance(test_log, bytes):
        raise EvidenceError("captured test log must be bytes")
    if (
        not isinstance(total_test_log_bytes, int)
        or isinstance(total_test_log_bytes, bool)
        or total_test_log_bytes < len(test_log)
        or len(test_log) > MAX_CAPTURE_LOG_BYTES
    ):
        raise EvidenceError("captured test log byte count is invalid")
    for preflight, label in (
        (capture_preflight, "capture"),
        (test_preflight, "test"),
    ):
        if not isinstance(preflight, dict) or not re.fullmatch(
            r"[0-9a-f]{64}", str(preflight.get("command_sha256"))
        ):
            raise EvidenceError(f"{label} preflight command hash is missing")

    sanitized = _privacy_safe_capture_log(test_log)
    bounded_log, published_log_bounded = _bounded_privacy_safe_capture_log(sanitized)
    _validate_privacy_safe_capture_log(bounded_log)
    signposts_json, marker_events_json, phase_manifest_hash = _capture_stage_exports(
        signpost_export_path=signpost_export_path,
        marker_event_export_path=marker_event_export_path,
        terminal=terminal,
        test_preflight=test_preflight,
    )
    raw_collection_truncated = total_test_log_bytes > len(test_log)
    partial = _partial_path(output_directory)
    os.mkdir(partial, 0o700)
    try:
        log_path = partial / "test.log"
        log_path.write_bytes(bounded_log)
        signposts_path = partial / "signposts.json"
        marker_events_path = partial / "marker-events.json"
        _write_new_json(signposts_path, signposts_json)
        _write_new_json(marker_events_path, marker_events_json)
        route_binding = _closed_route_binding(test_preflight)
        receipt = {
            "schema_version": SCHEMA_VERSION,
            "terminal": terminal,
            "capture_finalized": True,
            "raw_sha256": sha256_file(raw_path),
            "raw_byte_count": raw_path.stat().st_size,
            "test_log": {
                "published_byte_count": len(bounded_log),
                "collected_raw_byte_count": len(test_log),
                "observed_raw_byte_count": total_test_log_bytes,
                "bounded_at_bytes": MAX_CAPTURE_LOG_BYTES,
                "raw_collection_truncated": raw_collection_truncated,
                "published_log_bounded": published_log_bounded,
                "truncated": raw_collection_truncated or published_log_bounded,
                "published_log_sha256": hashlib.sha256(bounded_log).hexdigest(),
                "privacy_redaction_applied": True,
            },
            "capture_command_sha256": capture_preflight["command_sha256"],
            "test_command_sha256": test_preflight["command_sha256"],
            "test_without_building": test_preflight.get("test_without_building"),
            "no_build_test_command_sha256": test_preflight["command_sha256"],
            "prebuilt_build_receipt_sha256": test_preflight.get(
                "prebuilt_build_receipt_sha256"
            ),
            "prebuilt_build_command_sha256": test_preflight.get(
                "prebuilt_build_command_sha256"
            ),
            "prebuilt_build_products_manifest_sha256": test_preflight.get(
                "prebuilt_build_products_manifest_sha256"
            ),
            "prebuilt_binary_provenance_closed": test_preflight.get(
                "prebuilt_binary_provenance_closed"
            ),
            "prebuilt_destination_architecture": test_preflight.get(
                "prebuilt_destination_architecture"
            ),
            "prebuilt_xctestrun_selection_policy": test_preflight.get(
                "prebuilt_xctestrun_selection_policy"
            ),
            "prebuilt_xctestrun_count": test_preflight.get(
                "prebuilt_xctestrun_count"
            ),
            "prebuilt_referenced_product_count": test_preflight.get(
                "prebuilt_referenced_product_count"
            ),
            "prebuilt_runnable_executable_count": test_preflight.get(
                "prebuilt_runnable_executable_count"
            ),
            "prebuilt_referenced_regular_file_count": test_preflight.get(
                "prebuilt_referenced_regular_file_count"
            ),
            "prebuilt_referenced_regular_file_byte_count": test_preflight.get(
                "prebuilt_referenced_regular_file_byte_count"
            ),
            "prebuilt_referenced_files_manifest_sha256": test_preflight.get(
                "prebuilt_referenced_files_manifest_sha256"
            ),
            "capture_backend": capture_preflight.get(
                "capture_backend", "synthetic_test_seam"
            ),
            "only_locked_simulator_booted": (
                capture_preflight.get("window_provenance", {}).get(
                    "only_locked_simulator_booted"
                )
                if isinstance(capture_preflight.get("window_provenance"), dict)
                else False
            ),
            "simulator_udid": capture_preflight.get("window_provenance", {}).get(
                "simulator_udid"
            )
            if isinstance(capture_preflight.get("window_provenance"), dict)
            else None,
            "window_owner_application": capture_preflight.get(
                "window_provenance", {}
            ).get("owner_application")
            if isinstance(capture_preflight.get("window_provenance"), dict)
            else None,
            "window_snapshot_sha256": (
                capture_preflight.get("window_provenance", {}).get("snapshot_sha256")
                if isinstance(capture_preflight.get("window_provenance"), dict)
                else None
            ),
            "window_geometry": (
                capture_preflight.get("window_provenance", {}).get("window_geometry")
                if isinstance(capture_preflight.get("window_provenance"), dict)
                else None
            ),
            "window_measurement_monotonic_nanoseconds": (
                capture_preflight.get("window_provenance", {}).get(
                    "measured_monotonic_nanoseconds"
                )
                if isinstance(capture_preflight.get("window_provenance"), dict)
                else None
            ),
            "capture_spawn_before_monotonic_nanoseconds": capture_preflight.get(
                "capture_spawn_before_monotonic_nanoseconds"
            ),
            "capture_spawn_after_monotonic_nanoseconds": capture_preflight.get(
                "capture_spawn_after_monotonic_nanoseconds"
            ),
            "test_profile": test_preflight.get("profile"),
            "fixture_bundle_identifier": test_preflight.get(
                "fixture_bundle_identifier"
            ),
            "selector_count": test_preflight.get("selector_count"),
            "test_selector": route_binding["test_selector"],
            "matrix_route_code": route_binding["matrix_route_code"],
            "fixture_scenario": route_binding["fixture_scenario"],
            "parallel_testing_disabled": test_preflight.get(
                "parallel_testing_disabled"
            ),
            "signpost_export_sha256": sha256_file(signposts_path),
            "marker_event_export_sha256": sha256_file(marker_events_path),
            "contains_paths": False,
        }
        receipt_path = partial / "capture-receipt.json"
        _write_new_json(receipt_path, receipt)
        manifest = build_artifact_manifest(
            {
                "raw": raw_path,
                "test_log": log_path,
                "signposts": signposts_path,
                "marker_events": marker_events_path,
                "capture_receipt": receipt_path,
            },
            collision_files=[],
            phase_manifest_sha256=phase_manifest_hash,
            route_binding=route_binding,
        )
        manifest_path = partial / "artifact-manifest.json"
        _write_new_json(manifest_path, manifest)
        _publish_flat_directory_no_overwrite(partial, output_directory)
    except Exception:
        if partial.is_dir():
            shutil.rmtree(partial)
        raise
    return {
        "schema_version": SCHEMA_VERSION,
        "terminal": terminal,
        "capture_artifacts_preserved": True,
        "artifact_manifest_sha256": manifest["artifact_manifest_sha256"],
        "test_log_truncated": receipt["test_log"]["truncated"],
        "contains_paths": False,
    }


def _markdown_report(report: dict[str, Any]) -> str:
    source = report["source"]
    normalized = report.get("normalized")
    lines = [
        "# Chat-open video evidence report",
        "",
        f"- status: `{report.get('status', 'analysis_only')}`",
        f"- source artifact: `{source['artifact_id']}`",
        f"- source SHA-256: `{source['sha256']}`",
        f"- source duration: `{source['duration_seconds']} s`",
        f"- source frames: `{source['frame_count']}`",
        f"- source rate mode: `{source['measured_rate_mode']}`",
        f"- source first/last PTS: `{source['first_pts_seconds']}` / `{source['last_pts_seconds']}`",
        f"- source PTS strictly monotonic: `{str(source['strictly_monotonic_pts']).lower()}`",
        f"- native 60 fps proven: `{str(source['native_60_proven']).lower()}`",
    ]
    if normalized:
        mapping = report["mapping_summary"]
        clock = report["clock_mapping"]
        artifact_manifest = report["artifact_manifest"]
        lines.extend(
            [
                f"- normalized frames/rate: `{normalized['frame_count']}` / `{normalized['rate']}`",
                f"- duplicated grid frames: `{mapping['duplicated_grid_frames']}`",
                f"- collision groups/samples: `{mapping['collision_group_count']}` / `{mapping['collision_sample_count']}`",
                f"- all source samples classified: `{str(mapping['all_source_samples_classified']).lower()}`",
                f"- forbidden source samples: `{len(report['forbidden_source_indices'])}`",
                f"- measured clock markers: `{clock['marker_count']}`",
                f"- measured source/uptime marker span: `{clock['source_marker_span_seconds']} s` / `{clock['uptime_marker_span_seconds']} s`",
                f"- minimum provable marker span: `{clock['minimum_provable_marker_span_seconds']} s`",
                f"- clock drift: `{clock['clock_drift_ppm']} ppm`",
                f"- clock max/RMS residual: `{clock['maximum_residual_seconds']} s` / `{clock['rms_residual_seconds']} s`",
                f"- video quantization: `{clock['video_quantization_seconds']} s`",
                f"- bounded clock/video uncertainty: `{clock['bounded_uncertainty_seconds']} s`",
                f"- artifact manifest SHA-256: `{artifact_manifest['artifact_manifest_sha256']}`",
                f"- artifact manifest revalidated: `{str(report['privacy']['artifact_manifest_revalidated']).lower()}`",
                "",
                "The raw source remains authoritative. The normalized derivative is an explicitly attributed analysis artifact.",
            ]
        )
    lines.extend(
        [
            "",
            "This report intentionally contains no paths, account/JID fields, message bodies, tokens, or stable message/query identifiers.",
            "",
        ]
    )
    return "\n".join(lines)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    phase_manifest = subparsers.add_parser(
        "phase-manifest",
        help="derive the closed signpost phase manifest from production Swift",
    )
    phase_manifest.add_argument(
        "--swift-source", type=Path, default=DEFAULT_SIGNPOST_SWIFT_PATH
    )
    phase_manifest.add_argument("--json-out", type=Path)

    analyze = subparsers.add_parser("analyze", help="validate raw ffprobe evidence")
    analyze.add_argument("--raw", type=Path, required=True)
    analyze.add_argument("--probe-json", type=Path)
    analyze.add_argument("--requested-fps", type=int)
    analyze.add_argument("--json-out", type=Path)
    analyze.add_argument("--markdown-out", type=Path)

    normalize = subparsers.add_parser("normalize", help="create an attributed CFR60 derivative")
    normalize.add_argument("--raw", type=Path, required=True)
    normalize.add_argument("--probe-json", type=Path)
    normalize.add_argument("--derivative", type=Path, required=True)
    normalize.add_argument("--sidecar", type=Path, required=True)
    normalize.add_argument("--framemd5", type=Path, required=True)
    normalize.add_argument("--collision-directory", type=Path, required=True)
    normalize.add_argument("--codec", choices=("h264", "hevc", "ffv1"), default="h264")
    normalize.add_argument("--allow-ffv1", action="store_true")
    normalize.add_argument(
        "--disk-reserve-bytes", type=int, default=DEFAULT_DISK_RESERVE_BYTES
    )
    normalize.add_argument(
        "--max-bitrate-mbps", type=Decimal, default=DEFAULT_MAX_BITRATE_MBPS
    )

    derive_calibration = subparsers.add_parser(
        "derive-calibration",
        help="derive frame indices and clock calibration from raw visual markers",
    )
    derive_calibration.add_argument("--raw", type=Path, required=True)
    derive_calibration.add_argument("--probe-json", type=Path)
    derive_calibration.add_argument("--marker-events", type=Path, required=True)
    derive_calibration.add_argument(
        "--signpost-swift-source",
        type=Path,
        default=DEFAULT_SIGNPOST_SWIFT_PATH,
    )
    derive_calibration.add_argument("--calibration-out", type=Path, required=True)

    validate = subparsers.add_parser("validate", help="close the evidence package gate")
    validate.add_argument("--raw", type=Path, required=True)
    validate.add_argument("--raw-probe-json", type=Path)
    validate.add_argument("--derivative", type=Path, required=True)
    validate.add_argument("--derivative-probe-json", type=Path)
    validate.add_argument("--sidecar", type=Path, required=True)
    validate.add_argument("--framemd5", type=Path, required=True)
    validate.add_argument("--collision-directory", type=Path, required=True)
    validate.add_argument("--classifications", type=Path, required=True)
    validate.add_argument("--signposts", type=Path, required=True)
    validate.add_argument("--marker-events", type=Path, required=True)
    validate.add_argument("--calibration", type=Path, required=True)
    validate.add_argument("--test-log", type=Path, required=True)
    validate.add_argument("--capture-receipt", type=Path, required=True)
    validate.add_argument(
        "--signpost-swift-source",
        type=Path,
        default=DEFAULT_SIGNPOST_SWIFT_PATH,
    )
    validate.add_argument("--expected-artifact-manifest", type=Path)
    validate.add_argument("--json-out", type=Path, required=True)
    validate.add_argument("--markdown-out", type=Path, required=True)

    preflight = subparsers.add_parser("capture-preflight", help="validate a capture command without running it")
    preflight.add_argument("--simulator-id", required=True)
    preflight.add_argument("--raw-output", type=Path, required=True)
    preflight.add_argument("--capture-command-json", required=True)

    prebuild = subparsers.add_parser(
        "build-for-testing-run",
        help="run one serialized recorder-free build-for-testing and seal its receipt",
    )
    prebuild.add_argument("--simulator-id", required=True)
    prebuild.add_argument("--build-command-json", required=True)
    prebuild.add_argument("--build-receipt", type=Path, required=True)

    capture = subparsers.add_parser("capture-run", help="run one serialized lead-owned capture")
    capture.add_argument("--simulator-id", required=True)
    capture.add_argument("--raw-output", type=Path, required=True)
    capture.add_argument("--capture-command-json", required=True)
    capture.add_argument("--test-command-json", required=True)
    capture.add_argument("--capture-evidence-directory", type=Path, required=True)
    capture.add_argument("--signpost-export", type=Path, required=True)
    capture.add_argument("--marker-event-export", type=Path, required=True)
    capture.add_argument("--build-receipt", type=Path, required=True)
    capture.add_argument("--timeout-seconds", type=float, default=900.0)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    if args.command == "phase-manifest":
        report = load_signpost_phase_manifest(args.swift_source)
        if args.json_out:
            _write_new_json(args.json_out, report)
        print(json.dumps(report, sort_keys=True, ensure_ascii=True))
        return 0

    if args.command == "analyze":
        probe = _load_json(args.probe_json, "ffprobe JSON") if args.probe_json else run_ffprobe(args.raw)
        report = analyze_probe(args.raw, probe, requested_fps=args.requested_fps)
        output_paths = [path for path in (args.json_out, args.markdown_out) if path]
        if output_paths:
            validate_new_output_paths(args.raw, output_paths)
        if args.json_out:
            _write_new_json(args.json_out, report)
        if args.markdown_out:
            _write_new_text(args.markdown_out, _markdown_report(report))
        print(json.dumps(report, sort_keys=True, ensure_ascii=True))
        return 0

    if args.command == "normalize":
        probe = _load_json(args.probe_json, "ffprobe JSON") if args.probe_json else run_ffprobe(args.raw)
        summary = normalize_video(
            raw_path=args.raw,
            probe_data=probe,
            derivative_path=args.derivative,
            sidecar_path=args.sidecar,
            framemd5_path=args.framemd5,
            collision_directory=args.collision_directory,
            codec=args.codec,
            allow_ffv1=args.allow_ffv1,
            disk_reserve_bytes=args.disk_reserve_bytes,
            max_bitrate_mbps=args.max_bitrate_mbps,
        )
        print(json.dumps(summary, sort_keys=True, ensure_ascii=True))
        return 0

    if args.command == "derive-calibration":
        probe = (
            _load_json(args.probe_json, "ffprobe JSON")
            if args.probe_json
            else run_ffprobe(args.raw)
        )
        validate_new_output_paths(args.raw, [args.calibration_out])
        calibration = derive_video_calibration(
            raw_path=args.raw,
            probe_data=probe,
            marker_events_path=args.marker_events,
            signpost_swift_path=args.signpost_swift_source,
        )
        _write_new_json(args.calibration_out, calibration)
        print(json.dumps(calibration, sort_keys=True, ensure_ascii=True))
        return 0

    if args.command == "validate":
        validate_new_output_paths(args.raw, [args.json_out, args.markdown_out])
        raw_probe = (
            _load_json(args.raw_probe_json, "raw ffprobe JSON")
            if args.raw_probe_json
            else run_ffprobe(args.raw)
        )
        derivative_probe = (
            _load_json(args.derivative_probe_json, "derivative ffprobe JSON")
            if args.derivative_probe_json
            else run_ffprobe(args.derivative)
        )
        expected_manifest = None
        if args.expected_artifact_manifest:
            expected_manifest = _load_json(
                args.expected_artifact_manifest,
                "expected artifact manifest",
            )
            if "artifact_manifest" in expected_manifest:
                expected_manifest = expected_manifest["artifact_manifest"]
        report = validate_evidence_package(
            raw_path=args.raw,
            raw_probe_data=raw_probe,
            derivative_path=args.derivative,
            derivative_probe_data=derivative_probe,
            sidecar_path=args.sidecar,
            framemd5_path=args.framemd5,
            collision_directory=args.collision_directory,
            classifications_path=args.classifications,
            signposts_path=args.signposts,
            marker_events_path=args.marker_events,
            calibration_path=args.calibration,
            test_log_path=args.test_log,
            capture_receipt_path=args.capture_receipt,
            signpost_swift_path=args.signpost_swift_source,
            expected_artifact_manifest=expected_manifest,
        )
        _write_new_json(args.json_out, report)
        _write_new_text(args.markdown_out, _markdown_report(report))
        print(json.dumps({"status": report["status"]}, sort_keys=True))
        return 0 if report["status"] == "pass" else 3

    if args.command == "build-for-testing-run":
        build_command = _parse_command_json(
            args.build_command_json,
            "build-for-testing command",
        )
        report = run_build_for_testing_session(
            simulator_id=args.simulator_id,
            build_command=build_command,
            receipt_output=args.build_receipt,
        )
        print(json.dumps(report, sort_keys=True, ensure_ascii=True))
        return 0

    capture_command = _parse_command_json(args.capture_command_json, "capture command")
    if args.command == "capture-preflight":
        report = validate_capture_command(args.simulator_id, args.raw_output, capture_command)
        print(json.dumps(report, sort_keys=True, ensure_ascii=True))
        return 0

    if args.command == "capture-run":
        test_command = _parse_command_json(args.test_command_json, "test command")
        report = run_capture_session(
            simulator_id=args.simulator_id,
            raw_output=args.raw_output,
            capture_command=capture_command,
            test_command=test_command,
            timeout_seconds=args.timeout_seconds,
            capture_evidence_directory=args.capture_evidence_directory,
            signpost_export_path=args.signpost_export,
            marker_event_export_path=args.marker_event_export,
            build_receipt_path=args.build_receipt,
        )
        print(json.dumps(report, sort_keys=True, ensure_ascii=True))
        return 0

    raise EvidenceError("unsupported command")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except EvidenceError as error:
        print(f"evidence error: {error}", file=sys.stderr)
        raise SystemExit(2)
