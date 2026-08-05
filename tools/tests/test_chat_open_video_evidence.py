import hashlib
import io
import json
import os
import shutil
import subprocess
import tempfile
import time
import unittest
from decimal import Decimal
from pathlib import Path
from unittest import mock

from tools import chat_open_video_evidence as evidence


class ChatOpenVideoEvidenceTests(unittest.TestCase):
    WIDTH = 180
    HEIGHT = 320
    MARKER_X = 120
    MARKER_Y = 12
    MARKER_SIZE = 48
    MARKER_BORDER = 6
    M1_SOURCE_INDEX = 2
    M2_SOURCE_INDEX = 102
    M3_SOURCE_INDEX = 202

    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory(
            prefix="chat-open-video-evidence-test-"
        )
        self.root = Path(self.temporary_directory.name)
        self.app_data_container = self.root / "app-data-container"
        self.app_artifact_directory = (
            self.app_data_container / "Library/Caches"
        )
        self.app_artifact_directory.mkdir(parents=True)

    def tearDown(self):
        self.temporary_directory.cleanup()

    @staticmethod
    def probe(frame_pts, *, duration, rate="50/1", width=180, height=320):
        return {
            "streams": [
                {
                    "index": 0,
                    "codec_type": "video",
                    "width": width,
                    "height": height,
                    "r_frame_rate": rate,
                    "avg_frame_rate": rate,
                    "time_base": "1/1000",
                    "duration": str(duration),
                    "nb_read_frames": str(len(frame_pts)),
                }
            ],
            "format": {"duration": str(duration), "start_time": "0.000000"},
            "frames": [
                {
                    "media_type": "video",
                    "best_effort_timestamp_time": str(pts),
                    "duration_time": "0.020",
                }
                for pts in frame_pts
            ],
        }

    @staticmethod
    def marker_events(*, base_uptime_ns=100_000_000_000):
        return {
            "schema_version": 1,
            "marker_manifest_sha256": evidence.MARKER_MANIFEST_SHA256,
            "events": [
                {
                    "marker_id": "M1",
                    "visual_code": "vertical_bars",
                    "uptime_ns": base_uptime_ns + 40_000_000,
                },
                {
                    "marker_id": "M2",
                    "visual_code": "checkerboard",
                    "uptime_ns": base_uptime_ns + 2_040_000_000,
                },
                {
                    "marker_id": "M3",
                    "visual_code": "concentric_rings",
                    "uptime_ns": base_uptime_ns + 4_040_000_000,
                },
            ],
        }

    @staticmethod
    def _pattern(visual_code, x, y):
        if visual_code == "vertical_bars":
            return int(min(x, 0.999999) * 6) % 2 == 0
        if visual_code == "checkerboard":
            return (
                int(min(x, 0.999999) * 6)
                + int(min(y, 0.999999) * 6)
            ) % 2 == 0
        radius = (((x - 0.5) * 2) ** 2 + ((y - 0.5) * 2) ** 2) ** 0.5
        return radius < 1 and int(min(radius, 0.999999) * 6) % 2 == 0

    def frame(self, visual_code=None, *, variant="exact"):
        rgb = bytearray([32, 36, 40] * self.WIDTH * self.HEIGHT)
        if visual_code is None:
            return bytes(rgb)
        x0 = self.MARKER_X
        y0 = self.MARKER_Y
        size = self.MARKER_SIZE
        border = self.MARKER_BORDER
        for y in range(y0, y0 + size):
            for x in range(x0, x0 + size):
                offset = (y * self.WIDTH + x) * 3
                rgb[offset : offset + 3] = bytes((255, 0, 255))
        inner_size = size - border * 2
        for y in range(y0 + border, y0 + size - border):
            normalized_y = (y - y0 - border + 0.5) / inner_size
            for x in range(x0 + border, x0 + size - border):
                normalized_x = (x - x0 - border + 0.5) / inner_size
                if variant == "near":
                    value = 96
                elif variant == "ambiguous":
                    vertical = self._pattern(
                        "vertical_bars", normalized_x, normalized_y
                    )
                    checker = self._pattern(
                        "checkerboard", normalized_x, normalized_y
                    )
                    value = 255 if vertical and checker else 0 if not vertical and not checker else 128
                else:
                    value = 255 if self._pattern(
                        visual_code, normalized_x, normalized_y
                    ) else 0
                offset = (y * self.WIDTH + x) * 3
                rgb[offset : offset + 3] = bytes((value, value, value))
        return bytes(rgb)

    def exact_marker_sequence(self):
        absent = self.frame()
        return (
            [absent, absent]
            + [self.frame("vertical_bars")] * 2
            + [absent] * (self.M2_SOURCE_INDEX - 4)
            + [self.frame("checkerboard")] * 2
            + [absent] * (self.M3_SOURCE_INDEX - self.M2_SOURCE_INDEX - 2)
            + [self.frame("concentric_rings")] * 26
        )

    def short_marker_sequence(self):
        absent = self.frame()
        return (
            [absent, absent]
            + [self.frame("vertical_bars")] * 2
            + [absent]
            + [self.frame("checkerboard")] * 2
            + [absent]
            + [self.frame("concentric_rings")] * 26
        )

    @staticmethod
    def source_pts(frame_count):
        return [Decimal(index) * Decimal("0.020") for index in range(frame_count)]

    def calibration(self):
        frames = self.exact_marker_sequence()
        phase_manifest = evidence.load_signpost_phase_manifest()
        return evidence.derive_video_calibration_from_frames(
            frames=frames,
            width=self.WIDTH,
            height=self.HEIGHT,
            source_pts=self.source_pts(len(frames)),
            raw_video_sha256="a" * 64,
            marker_events=self.marker_events(),
            marker_event_sha256="b" * 64,
            phase_manifest_sha256=phase_manifest["sha256"],
        )

    def valid_window_snapshot(
        self,
        *,
        window_id=12345,
        bounds=None,
    ):
        if bounds is None:
            bounds = {"x": 120, "y": 80, "width": 456, "height": 996}
        return {
            "booted_devices": [
                {
                    "udid": evidence.LOCKED_SIMULATOR_ID,
                    "name": evidence.LOCKED_SIMULATOR_NAME,
                    "state": "Booted",
                }
            ],
            "windows": [
                {
                    "window_id": window_id,
                    "owner_application": "Simulator",
                    "title": evidence.LOCKED_SIMULATOR_NAME,
                    "layer": 0,
                    "on_screen": True,
                    "bounds": bounds,
                }
            ],
        }

    def test_native_window_inventory_uses_swift_coregraphics_without_jxa_cfarray_bridge(self):
        devices = {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
                    {
                        "udid": evidence.LOCKED_SIMULATOR_ID,
                        "name": evidence.LOCKED_SIMULATOR_NAME,
                        "state": "Booted",
                    }
                ]
            }
        }
        windows = self.valid_window_snapshot(window_id=204)["windows"]
        commands = []

        def fake_json_command(command, label):
            commands.append((command, label))
            if label == "simulator inventory":
                return devices
            if label == "CoreGraphics window":
                return windows
            self.fail(f"unexpected command label: {label}")

        with mock.patch.object(
            evidence,
            "_run_json_command",
            side_effect=fake_json_command,
        ):
            snapshot = evidence.collect_native_window_snapshot(204)

        self.assertEqual(snapshot, self.valid_window_snapshot(window_id=204))
        self.assertEqual(
            commands[0][0],
            ["/usr/bin/xcrun", "simctl", "list", "devices", "--json"],
        )
        window_command = commands[1][0]
        self.assertEqual(window_command[:2], ["/usr/bin/swift", "-e"])
        self.assertEqual(len(window_command), 3)
        self.assertNotIn("osascript", " ".join(window_command))
        self.assertNotIn("ObjC.deepUnwrap", window_command[2])
        self.assertIn("CGWindowListCopyWindowInfo", window_command[2])
        self.assertIn("JSONSerialization", window_command[2])
        self.assertIn("CGWindowID(204)", window_command[2])
        self.assertIn("kCGWindowBounds", window_command[2])
        self.assertIn('raw["Width"]', window_command[2])
        self.assertIn('"width": width', window_command[2])

    def test_native_window_capture_rejects_tiny_exact_title_window_before_recorder(self):
        raw = self.root / "capture.mov"
        command = [
            "/usr/bin/swift",
            str(evidence.BUNDLED_WINDOW_RECORDER_SOURCE),
            "--window-id",
            "204",
            "--output",
            str(raw),
        ]
        tiny_snapshot = self.valid_window_snapshot(
            window_id=204,
            bounds={"x": 2575, "y": 730, "width": 49, "height": 143},
        )

        with self.assertRaisesRegex(
            evidence.EvidenceError,
            "native capture window geometry is below the evidence minimum",
        ):
            evidence.validate_capture_command(
                evidence.LOCKED_SIMULATOR_ID,
                raw,
                command,
                window_snapshot_provider=lambda _window_id: tiny_snapshot,
            )

    def test_native_window_geometry_is_policy_and_snapshot_hash_bound(self):
        snapshot = self.valid_window_snapshot(window_id=204)

        provenance = evidence.validate_native_window_snapshot(snapshot, 204)

        geometry = provenance["window_geometry"]
        self.assertEqual(
            geometry["bounds_points"],
            {"x": 120, "y": 80, "width": 456, "height": 996},
        )
        self.assertEqual(
            geometry["expected_h264_pixels"],
            {"width": 456, "height": 996},
        )
        self.assertEqual(
            geometry["policy"],
            {
                "schema_version": 1,
                "minimum_width_points": 400,
                "minimum_height_points": 850,
                "minimum_width_over_height_milli": 440,
                "maximum_width_over_height_milli": 480,
                "orientation": "portrait",
                "configured_output_scale_milli": 1000,
                "h264_dimension_alignment_pixels": 2,
            },
        )
        self.assertEqual(geometry["snapshot_sha256"], provenance["snapshot_sha256"])
        self.assertRegex(geometry["policy_sha256"], r"^[0-9a-f]{64}$")
        self.assertRegex(geometry["geometry_sha256"], r"^[0-9a-f]{64}$")

        changed = self.valid_window_snapshot(
            window_id=204,
            bounds={"x": 120, "y": 80, "width": 454, "height": 990},
        )
        changed_geometry = evidence.validate_native_window_snapshot(changed, 204)[
            "window_geometry"
        ]
        self.assertNotEqual(
            changed_geometry["geometry_sha256"],
            geometry["geometry_sha256"],
        )

    def test_native_window_capture_rejects_invalid_or_wrong_aspect_geometry(self):
        invalid_bounds = (
            ({"x": 0, "y": 0, "width": 900, "height": 900}, "portrait aspect ratio"),
            ({"x": 0, "y": 0, "width": -456, "height": 996}, "positive integral"),
            ({"x": 0, "y": 0, "width": 456.5, "height": 996}, "positive integral"),
            ({"x": 0, "y": 0, "width": 456, "height": True}, "positive integral"),
        )
        for bounds, expected_error in invalid_bounds:
            with self.subTest(bounds=bounds):
                with self.assertRaisesRegex(evidence.EvidenceError, expected_error):
                    evidence.validate_native_window_snapshot(
                        self.valid_window_snapshot(window_id=204, bounds=bounds),
                        204,
                    )

    def test_capture_receipt_geometry_must_match_snapshot_hash_and_raw_dimensions(self):
        provenance = evidence.validate_native_window_snapshot(
            self.valid_window_snapshot(
                window_id=204,
                bounds={"x": 120, "y": 80, "width": 455, "height": 995},
            ),
            204,
        )
        receipt = {
            "window_snapshot_sha256": provenance["snapshot_sha256"],
            "window_geometry": provenance["window_geometry"],
        }
        raw_report = {"source": {"width": 456, "height": 996}}

        validated = evidence.validate_capture_receipt_window_geometry(
            receipt,
            raw_report,
        )

        self.assertEqual(validated["expected_h264_pixels"], raw_report["source"])
        mutations = (
            (
                receipt,
                {"source": {"width": 50, "height": 144}},
                "raw video dimensions do not match",
            ),
            (
                dict(receipt, window_snapshot_sha256="f" * 64),
                raw_report,
                "snapshot hash",
            ),
            (
                dict(
                    receipt,
                    window_geometry=dict(
                        receipt["window_geometry"],
                        policy_sha256="f" * 64,
                    ),
                ),
                raw_report,
                "geometry policy",
            ),
            (
                dict(
                    receipt,
                    window_geometry=dict(
                        receipt["window_geometry"],
                        geometry_sha256="f" * 64,
                    ),
                ),
                raw_report,
                "geometry hash",
            ),
        )
        for changed_receipt, changed_raw_report, expected_error in mutations:
            with self.subTest(expected_error=expected_error):
                with self.assertRaisesRegex(evidence.EvidenceError, expected_error):
                    evidence.validate_capture_receipt_window_geometry(
                        changed_receipt,
                        changed_raw_report,
                    )

    def test_native_window_capture_rejects_screencapture_video_window_semantic_hole(self):
        raw = self.root / "capture.mov"

        with self.assertRaisesRegex(
            evidence.EvidenceError,
            "does not provide a persistent window video recorder",
        ):
            evidence.validate_capture_command(
                evidence.LOCKED_SIMULATOR_ID,
                raw,
                [
                    "/usr/sbin/screencapture",
                    "-v",
                    "-l204",
                    str(raw),
                ],
                window_snapshot_provider=lambda _window_id: self.valid_window_snapshot(
                    window_id=204
                ),
            )

    def test_native_window_capture_accepts_only_bundled_screencapturekit_grammar(self):
        raw = self.root / "capture.mov"
        command = [
            "/usr/bin/swift",
            str(evidence.BUNDLED_WINDOW_RECORDER_SOURCE),
            "--window-id",
            "204",
            "--output",
            str(raw),
        ]

        report = evidence.validate_capture_command(
            evidence.LOCKED_SIMULATOR_ID,
            raw,
            command,
            window_snapshot_provider=lambda _window_id: self.valid_window_snapshot(
                window_id=204
            ),
        )

        self.assertEqual(report["capture_backend"], "native_window")
        self.assertEqual(report["window_id"], 204)
        self.assertRegex(report["recorder_source_sha256"], r"^[0-9a-f]{64}$")
        self.assertEqual(
            report["window_provenance"]["simulator_udid"],
            evidence.LOCKED_SIMULATOR_ID,
        )
        rejected_commands = (
            command + ["--extra"],
            command[:3] + ["205"] + command[4:],
            command[:1] + [str(self.root / "other.swift")] + command[2:],
        )
        for rejected in rejected_commands:
            with self.subTest(command=rejected):
                with self.assertRaises(evidence.EvidenceError):
                    evidence.validate_capture_command(
                        evidence.LOCKED_SIMULATOR_ID,
                        raw,
                        rejected,
                        window_snapshot_provider=lambda _window_id: (
                            self.valid_window_snapshot(window_id=204)
                        ),
                    )

    def test_native_window_recorder_readiness_is_exact_and_process_remains_live(self):
        process = subprocess.Popen(
            [
                "/usr/bin/python3",
                "-c",
                (
                    "import os,time;"
                    "os.write(1,b'READY\\n');"
                    "time.sleep(30)"
                ),
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        try:
            evidence._wait_for_window_recorder_ready(process, timeout_seconds=2)
            self.assertIsNone(process.poll())
        finally:
            process.terminate()
            process.wait(timeout=5)

    def test_capture_partial_mov_keeps_recorder_extension_before_ready(self):
        raw = self.root / "capture.mov"
        runtime_raw = evidence._partial_path(raw)
        process = subprocess.Popen(
            [
                "/usr/bin/python3",
                "-c",
                (
                    "import os,pathlib,sys,time;"
                    "output=pathlib.Path(sys.argv[1]);"
                    "valid=output.suffix.lower()=='.mov';"
                    "os.write(1,b'READY\\n') if valid else None;"
                    "time.sleep(30) if valid else sys.exit(17)"
                ),
                str(runtime_raw),
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            evidence._wait_for_window_recorder_ready(process, timeout_seconds=2)
            self.assertIsNone(process.poll())
        finally:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=5)
        self.assertEqual(runtime_raw.parent, raw.parent)
        self.assertNotEqual(runtime_raw, raw)
        self.assertTrue(runtime_raw.name.startswith("."))
        self.assertEqual(runtime_raw.suffix.lower(), ".mov")
        self.assertFalse(runtime_raw.exists())

    def test_native_recorder_startup_diagnostic_is_bounded_and_allowlisted(self):
        private_payload = "forbidden-private-payload" + (
            "x" * (evidence.MAX_WINDOW_RECORDER_STARTUP_DIAGNOSTIC_BYTES + 1024)
        )
        process = subprocess.Popen(
            [
                "/usr/bin/python3",
                "-c",
                (
                    "import os,sys;"
                    "os.write(2,b'RECORDER_ERROR:invalid-output\\n');"
                    "os.write(2,sys.argv[1].encode('utf-8'));"
                    "sys.exit(23)"
                ),
                private_payload,
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        with self.assertRaises(evidence.EvidenceError) as caught:
            evidence._wait_for_window_recorder_ready(process, timeout_seconds=2)
        process.wait(timeout=5)
        message = str(caught.exception)
        self.assertIn("invalid-output", message)
        self.assertNotIn(private_payload, message)
        self.assertLess(len(message), 256)

    def valid_test_command(
        self,
        signposts,
        marker_events,
        *,
        data_container=None,
    ):
        data_container = data_container or self.app_data_container
        return [
            "/usr/bin/env",
            "-u",
            "TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT",
            "-u",
            "TEST_RUNNER_XABBER_ISOLATED_STORAGE",
            "-u",
            "XABBER_CHAT_LIVE_QA_MODE",
            "XABBER_SCHEME=Chat Performance UI Tests",
            f"XABBER_DESTINATION=platform=iOS Simulator,id={evidence.LOCKED_SIMULATOR_ID}",
            (
                f"{evidence.ARTIFACT_DATA_CONTAINER_ENVIRONMENT_KEY}="
                f"{data_container}"
            ),
            f"XABBER_CHAT_SIGNPOST_EXPORT_PATH={signposts}",
            f"XABBER_CHAT_VIDEO_CALIBRATION_EXPORT_PATH={marker_events}",
            str(evidence.APPROVED_XCODEBUILD_WRAPPER),
            "test-without-building",
            "-jobs",
            "1",
            "-parallel-testing-enabled",
            "NO",
            "-collect-test-diagnostics",
            "never",
            (
                "-only-testing:xabberChatPerformanceUITests/ChatPerformanceUITests/"
                "testChatOpenN01PreloadedLatestVideoRoute"
            ),
            "XABBER_APP_BUNDLE_IDENTIFIER=xabber.ios.codex-chat-performance",
            (
                "XABBER_PUSH_EXTENSION_BUNDLE_IDENTIFIER="
                "xabber.ios.codex-chat-performance.xabber-push-extension"
            ),
        ]

    def valid_build_for_testing_command(self):
        return [
            "/usr/bin/env",
            "-u",
            "TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT",
            "-u",
            "TEST_RUNNER_XABBER_ISOLATED_STORAGE",
            "-u",
            "XABBER_CHAT_LIVE_QA_MODE",
            "XABBER_SCHEME=Chat Performance UI Tests",
            f"XABBER_DESTINATION=platform=iOS Simulator,id={evidence.LOCKED_SIMULATOR_ID}",
            str(evidence.APPROVED_XCODEBUILD_WRAPPER),
            "build-for-testing",
            "-jobs",
            "1",
            "-parallel-testing-enabled",
            "NO",
            "-collect-test-diagnostics",
            "never",
            (
                "-only-testing:xabberChatPerformanceUITests/ChatPerformanceUITests/"
                "testChatOpenN01PreloadedLatestVideoRoute"
            ),
            "XABBER_APP_BUNDLE_IDENTIFIER=xabber.ios.codex-chat-performance",
            (
                "XABBER_PUSH_EXTENSION_BUNDLE_IDENTIFIER="
                "xabber.ios.codex-chat-performance.xabber-push-extension"
            ),
        ]

    def write_synthetic_prebuilt_products(self, products, *, label="prebuilt"):
        products.mkdir(parents=True, exist_ok=True)
        configuration = "Debug-iphonesimulator"
        app = products / configuration / "xabber.app"
        runner = (
            products
            / configuration
            / "xabberChatPerformanceUITests-Runner.app"
        )
        test_bundle = runner / "PlugIns/xabberChatPerformanceUITests.xctest"
        extension = products / configuration / "xabber-push-extension.appex"

        def write_bundle(bundle, bundle_identifier, executable_name, payload):
            bundle.mkdir(parents=True, exist_ok=True)
            (bundle / "Info.plist").write_text(
                json.dumps(
                    {
                        "CFBundleIdentifier": bundle_identifier,
                        "CFBundleExecutable": executable_name,
                        "CFBundlePackageType": "BNDL",
                    }
                ),
                encoding="utf-8",
            )
            executable = bundle / executable_name
            executable.write_bytes(payload)
            executable.chmod(0o755)
            (bundle / "sealed-resource.bin").write_bytes(
                b"resource-" + payload
            )
            return executable

        executables = {
            "app": write_bundle(
                app,
                evidence.PERFORMANCE_APP_BUNDLE_IDENTIFIER,
                "xabber",
                f"app-{label}".encode("ascii"),
            ),
            "runner": write_bundle(
                runner,
                "xabber.ios.xabberChatPerformanceUITests.xctrunner",
                "xabberChatPerformanceUITests-Runner",
                f"runner-{label}".encode("ascii"),
            ),
            "test_bundle": write_bundle(
                test_bundle,
                "xabber.ios.xabberChatPerformanceUITests",
                "xabberChatPerformanceUITests",
                f"test-bundle-{label}".encode("ascii"),
            ),
            "push_extension": write_bundle(
                extension,
                (
                    evidence.PERFORMANCE_APP_BUNDLE_IDENTIFIER
                    + ".xabber-push-extension"
                ),
                "xabber-push-extension",
                f"push-extension-{label}".encode("ascii"),
            ),
        }
        xctestrun = (
            products
            / "Chat Performance UI Tests_iphonesimulator26.0-arm64.xctestrun"
        )
        xctestrun.write_text(
            json.dumps(
                {
                    "__xctestrun_metadata__": {
                        "FormatVersion": 1,
                        "ContainerInfo": {
                            "ContainerName": "xabber",
                            "SchemeName": "Chat Performance UI Tests",
                        },
                    },
                    "xabberChatPerformanceUITests": {
                        "BlueprintName": "xabberChatPerformanceUITests",
                        "BlueprintProviderName": "xabber",
                        "BlueprintProviderRelativePath": "xabber.xcodeproj",
                        "ProductModuleName": "xabberChatPerformanceUITests",
                        "IsUITestBundle": True,
                        "IsXCTRunnerHostedTestBundle": True,
                        "TestHostBundleIdentifier": (
                            "xabber.ios.xabberChatPerformanceUITests.xctrunner"
                        ),
                        "BundleIdentifiersForCrashReportEmphasis": [
                            evidence.PERFORMANCE_APP_BUNDLE_IDENTIFIER,
                            (
                                evidence.PERFORMANCE_APP_BUNDLE_IDENTIFIER
                                + ".xabber-push-extension"
                            ),
                            "xabber.ios.xabberChatPerformanceUITests",
                        ],
                        "TestBundlePath": (
                            "__TESTHOST__/PlugIns/"
                            "xabberChatPerformanceUITests.xctest"
                        ),
                        "TestHostPath": (
                            "__TESTROOT__/Debug-iphonesimulator/"
                            "xabberChatPerformanceUITests-Runner.app"
                        ),
                        "UITargetAppPath": (
                            "__TESTROOT__/Debug-iphonesimulator/xabber.app"
                        ),
                        "DependentProductPaths": [
                            (
                                "__TESTROOT__/Debug-iphonesimulator/"
                                "xabber-push-extension.appex"
                            ),
                            "__TESTROOT__/Debug-iphonesimulator/xabber.app",
                            (
                                "__TESTROOT__/Debug-iphonesimulator/"
                                "xabberChatPerformanceUITests-Runner.app"
                            ),
                            (
                                "__TESTROOT__/Debug-iphonesimulator/"
                                "xabberChatPerformanceUITests-Runner.app/PlugIns/"
                                "xabberChatPerformanceUITests.xctest"
                            ),
                        ],
                    },
                },
            ),
            encoding="utf-8",
        )
        return {
            "xctestrun": xctestrun,
            "app": app,
            "runner": runner,
            "test_bundle": test_bundle,
            "push_extension": extension,
            "executables": executables,
        }

    def make_prebuilt_receipt(self, label="prebuilt"):
        products = self.root / f"{label}-products"
        self.write_synthetic_prebuilt_products(products, label=label)
        preflight = evidence.validate_build_for_testing_command(
            self.valid_build_for_testing_command()
        )
        receipt = {
            "schema_version": evidence.SCHEMA_VERSION,
            "status": "success",
            "build_for_testing": True,
            "build_command_sha256": preflight["command_sha256"],
            "build_compatibility_sha256": preflight[
                "build_compatibility_sha256"
            ],
            "simulator_udid": evidence.LOCKED_SIMULATOR_ID,
            "profile": preflight["profile"],
            "selector_count": 1,
            "test_selector": preflight["test_selector"],
            "matrix_route_code": preflight["matrix_route_code"],
            "fixture_scenario": preflight["fixture_scenario"],
            "worker_job_limit": 1,
            "parallel_testing_disabled": True,
            "test_diagnostics_collection_disabled": True,
            "fixture_bundle_identifier": evidence.PERFORMANCE_APP_BUNDLE_IDENTIFIER,
            "build_products": evidence.collect_prebuilt_build_products(products),
            "contains_paths": False,
        }
        receipt_path = self.root / f"{label}-receipt.json"
        receipt_path.write_text(json.dumps(receipt), encoding="utf-8")
        return receipt_path, products

    def test_prebuild_inventory_binds_all_referenced_runnable_products_without_paths(self):
        products = self.root / "closed-products"
        self.write_synthetic_prebuilt_products(products, label="closed")

        inventory = evidence.collect_prebuilt_build_products(products)

        self.assertEqual(inventory["xctestrun_count"], 1)
        self.assertEqual(inventory["destination_architecture"], "arm64")
        self.assertEqual(
            inventory["xctestrun_selection_policy"],
            "locked_simulator_sdk_arm64",
        )
        self.assertEqual(inventory["referenced_product_count"], 4)
        self.assertGreaterEqual(inventory["referenced_regular_file_count"], 12)
        self.assertEqual(inventory["runnable_executable_count"], 4)
        serialized = json.dumps(inventory, sort_keys=True)
        self.assertNotIn(str(self.root), serialized)
        self.assertNotIn("__TESTROOT__", serialized)
        self.assertNotIn("__TESTHOST__", serialized)
        self.assertNotIn("Debug-iphonesimulator", serialized)
        self.assertNotIn("/", serialized)
        self.assertFalse(inventory["contains_paths"])

    def test_prebuild_inventory_uses_exact_arm64_xctestrun_not_stale_universal_file(self):
        products = self.root / "arm64-products"
        package = self.write_synthetic_prebuilt_products(products, label="arm64")
        expected = evidence.collect_prebuilt_build_products(products)
        stale_universal = (
            products
            / "Chat Performance UI Tests_iphonesimulator26.0-arm64-x86_64.xctestrun"
        )
        stale_document = json.loads(
            package["xctestrun"].read_text(encoding="utf-8")
        )
        stale_document["xabberChatPerformanceUITests"][
            "BundleIdentifiersForCrashReportEmphasis"
        ] = [
            "xabber.ios",
            "xabber.ios.xabber-push-extension",
            "xabber.ios.xabberChatPerformanceUITests",
        ]
        stale_universal.write_text(json.dumps(stale_document), encoding="utf-8")

        actual = evidence.collect_prebuilt_build_products(products)

        self.assertEqual(actual, expected)
        self.assertEqual(actual["xctestrun_count"], 1)

        duplicate_arm64 = (
            products
            / "Chat Performance UI Tests_iphonesimulator26.1-arm64.xctestrun"
        )
        duplicate_arm64.write_bytes(package["xctestrun"].read_bytes())
        with self.assertRaises(evidence.EvidenceError):
            evidence.collect_prebuilt_build_products(products)

    def test_capture_rejects_app_binary_swap_before_recorder_or_xctest_spawn(self):
        receipt_path, products = self.make_prebuilt_receipt("binary-swap")
        package_app = products / "Debug-iphonesimulator/xabber.app/xabber"
        package_app.write_bytes(b"swapped-after-receipt")
        raw = self.root / "binary-swap.mov"
        signposts = self.app_artifact_directory / "chat-open-N01-signposts.json"
        markers = self.app_artifact_directory / "chat-open-N01-markers.json"
        capture_evidence = self.root / "binary-swap-capture"
        capture_command = [
            "/usr/bin/swift",
            str(evidence.BUNDLED_WINDOW_RECORDER_SOURCE),
            "--window-id",
            "204",
            "--output",
            str(raw),
        ]
        process_spawn = mock.Mock(side_effect=AssertionError("process spawned"))
        with self.assertRaisesRegex(evidence.EvidenceError, "changed"):
            evidence.run_capture_session(
                simulator_id=evidence.LOCKED_SIMULATOR_ID,
                raw_output=raw,
                capture_command=capture_command,
                test_command=self.valid_test_command(signposts, markers),
                timeout_seconds=5,
                capture_evidence_directory=capture_evidence,
                signpost_export_path=signposts,
                marker_event_export_path=markers,
                build_receipt_path=receipt_path,
                window_snapshot_provider=lambda _window_id: (
                    self.valid_window_snapshot(window_id=204)
                ),
                app_data_container_resolver=lambda *_args: (
                    self.app_data_container
                ),
                build_products_root=products,
                process_spawner=process_spawn,
            )
        process_spawn.assert_not_called()

    def test_stale_receipt_rejects_changed_ui_test_executable(self):
        receipt_path, products = self.make_prebuilt_receipt("stale-test-bundle")
        test_executable = (
            products
            / "Debug-iphonesimulator/xabberChatPerformanceUITests-Runner.app"
            / "PlugIns/xabberChatPerformanceUITests.xctest"
            / "xabberChatPerformanceUITests"
        )
        test_executable.write_bytes(b"new-ui-test-binary")
        signposts = self.app_artifact_directory / "signposts.json"
        markers = self.app_artifact_directory / "markers.json"
        test_preflight = evidence.validate_test_command(
            self.valid_test_command(signposts, markers),
            expected_signpost_output=signposts,
            expected_marker_event_output=markers,
            expected_data_container=self.app_data_container,
        )

        with self.assertRaisesRegex(evidence.EvidenceError, "changed"):
            evidence.validate_prebuilt_build_receipt(
                receipt_path,
                expected_test_preflight=test_preflight,
                build_products_root=products,
            )

    def test_capture_rechecks_binary_bytes_immediately_before_recorder_spawn(self):
        receipt_path, products = self.make_prebuilt_receipt("pre-spawn-swap")
        app_executable = products / "Debug-iphonesimulator/xabber.app/xabber"
        raw = self.root / "pre-spawn-swap.mov"
        signposts = self.app_artifact_directory / "chat-open-N01-signposts.json"
        markers = self.app_artifact_directory / "chat-open-N01-markers.json"
        snapshot_calls = 0

        def window_snapshot(_window_id):
            nonlocal snapshot_calls
            snapshot_calls += 1
            if snapshot_calls == 2:
                app_executable.write_bytes(b"changed-at-final-window-preflight")
            return self.valid_window_snapshot(window_id=204)

        process_spawn = mock.Mock(side_effect=AssertionError("process spawned"))
        with mock.patch.object(
            evidence,
            "CAPTURE_LOCK_PATH",
            self.root / "pre-spawn-swap-capture.lock",
        ), mock.patch.object(
            evidence,
            "PREBUILD_LOCK_PATH",
            self.root / "pre-spawn-swap-prebuild.lock",
        ):
            with self.assertRaisesRegex(evidence.EvidenceError, "changed"):
                evidence.run_capture_session(
                    simulator_id=evidence.LOCKED_SIMULATOR_ID,
                    raw_output=raw,
                    capture_command=[
                        "/usr/bin/swift",
                        str(evidence.BUNDLED_WINDOW_RECORDER_SOURCE),
                        "--window-id",
                        "204",
                        "--output",
                        str(raw),
                    ],
                    test_command=self.valid_test_command(signposts, markers),
                    timeout_seconds=5,
                    capture_evidence_directory=self.root / "pre-spawn-swap-capture",
                    signpost_export_path=signposts,
                    marker_event_export_path=markers,
                    build_receipt_path=receipt_path,
                    window_snapshot_provider=window_snapshot,
                    app_data_container_resolver=lambda *_args: self.app_data_container,
                    build_products_root=products,
                    process_spawner=process_spawn,
                )
        self.assertEqual(snapshot_calls, 2)
        process_spawn.assert_not_called()

    def test_prebuild_inventory_rejects_unsafe_or_unexpected_product_references(self):
        cases = (
            "missing",
            "symlink",
            "out-of-root",
            "unexpected",
            "bundle-metadata",
        )
        for case in cases:
            with self.subTest(case=case):
                products = self.root / f"unsafe-{case}"
                package = self.write_synthetic_prebuilt_products(
                    products,
                    label=case,
                )
                if case == "missing":
                    package["executables"]["app"].unlink()
                elif case == "symlink":
                    executable = package["executables"]["runner"]
                    executable.unlink()
                    executable.symlink_to(package["executables"]["app"])
                elif case in {"out-of-root", "unexpected"}:
                    document = json.loads(
                        package["xctestrun"].read_text(encoding="utf-8")
                    )
                    target = document["xabberChatPerformanceUITests"]
                    if case == "out-of-root":
                        target["UITargetAppPath"] = "/tmp/foreign.app"
                    else:
                        target["DependentProductPaths"].append(
                            "__TESTROOT__/Debug-iphonesimulator/foreign.app"
                        )
                    package["xctestrun"].write_text(
                        json.dumps(document),
                        encoding="utf-8",
                    )
                else:
                    info_path = package["app"] / "Info.plist"
                    info = json.loads(info_path.read_text(encoding="utf-8"))
                    info["CFBundleIdentifier"] = "invalid.foreign.application"
                    info_path.write_text(json.dumps(info), encoding="utf-8")

                with self.assertRaises(evidence.EvidenceError):
                    evidence.collect_prebuilt_build_products(products)

    def test_capture_requires_test_without_building_and_rejects_build_actions(self):
        signposts = self.app_artifact_directory / "signposts.json"
        marker_events = self.app_artifact_directory / "marker-events.json"
        command = self.valid_test_command(signposts, marker_events)

        accepted = evidence.validate_test_command(
            command,
            expected_signpost_output=signposts,
            expected_marker_event_output=marker_events,
            expected_data_container=self.app_data_container,
        )

        self.assertTrue(accepted["test_without_building"])
        action_index = command.index("test-without-building")
        for forbidden_action in ("test", "build", "build-for-testing"):
            with self.subTest(action=forbidden_action):
                mutation = list(command)
                mutation[action_index] = forbidden_action
                with self.assertRaises(evidence.EvidenceError):
                    evidence.validate_test_command(
                        mutation,
                        expected_signpost_output=signposts,
                        expected_marker_event_output=marker_events,
                        expected_data_container=self.app_data_container,
                    )

    def test_build_for_testing_receipt_binds_no_build_route_without_paths(self):
        products = self.root / "DerivedData/Build/Products"
        products.mkdir(parents=True)
        receipt_path = self.root / "prebuilt.json"
        build_command = self.valid_build_for_testing_command()
        action_index = build_command.index("build-for-testing")
        for forbidden_action in ("build", "test", "test-without-building"):
            mutation = list(build_command)
            mutation[action_index] = forbidden_action
            with self.assertRaises(evidence.EvidenceError):
                evidence.validate_build_for_testing_command(mutation)
        launches = []

        def fake_runner(command, **kwargs):
            launches.append((list(command), kwargs))
            self.write_synthetic_prebuilt_products(products, label="session")
            return subprocess.CompletedProcess(command, 0)

        with mock.patch.object(
            evidence,
            "PREBUILD_LOCK_PATH",
            self.root / "prebuild.lock",
        ), mock.patch.object(
            evidence,
            "CAPTURE_LOCK_PATH",
            self.root / "capture.lock",
        ):
            receipt = evidence.run_build_for_testing_session(
                simulator_id=evidence.LOCKED_SIMULATOR_ID,
                build_command=build_command,
                receipt_output=receipt_path,
                build_products_root=products,
                command_runner=fake_runner,
            )

        self.assertEqual(len(launches), 1)
        self.assertTrue(receipt["build_for_testing"])
        self.assertFalse(receipt["contains_paths"])
        self.assertEqual(receipt["build_products"]["xctestrun_count"], 1)
        self.assertEqual(receipt["build_products"]["referenced_product_count"], 4)
        self.assertEqual(receipt["build_products"]["runnable_executable_count"], 4)
        self.assertNotIn(str(self.root), json.dumps(receipt, sort_keys=True))
        signposts = self.app_artifact_directory / "signposts.json"
        markers = self.app_artifact_directory / "markers.json"
        test_preflight = evidence.validate_test_command(
            self.valid_test_command(signposts, markers),
            expected_signpost_output=signposts,
            expected_marker_event_output=markers,
            expected_data_container=self.app_data_container,
        )
        validated = evidence.validate_prebuilt_build_receipt(
            receipt_path,
            expected_test_preflight=test_preflight,
            build_products_root=products,
        )
        self.assertEqual(
            validated["build_compatibility_sha256"],
            test_preflight["build_compatibility_sha256"],
        )
        next(products.glob("*.xctestrun")).write_bytes(b"changed-after-build")
        with self.assertRaisesRegex(evidence.EvidenceError, "changed"):
            evidence.validate_prebuilt_build_receipt(
                receipt_path,
                expected_test_preflight=test_preflight,
                build_products_root=products,
            )

    def test_cached_wrapper_separates_build_for_testing_and_test_without_building(self):
        fixture_root = self.root / "wrapper-fixture"
        tools = fixture_root / "tools"
        fake_bin = fixture_root / "bin"
        tools.mkdir(parents=True)
        fake_bin.mkdir()
        wrapper = tools / "xcodebuild_cached.sh"
        shutil.copy2(evidence.APPROVED_XCODEBUILD_WRAPPER, wrapper)
        fake_xcodebuild = fake_bin / "xcodebuild"
        capture = fixture_root / "xcodebuild-args.txt"
        fake_xcodebuild.write_text(
            "#!/bin/sh\n"
            "for argument in \"$@\"; do printf 'arg=%s\\n' \"$argument\"; done "
            "> \"$XABBER_WRAPPER_CAPTURE\"\n",
            encoding="utf-8",
        )
        fake_xcodebuild.chmod(0o755)
        environment = os.environ.copy()
        environment.update(
            {
                "PATH": f"{fake_bin}:/usr/bin:/bin",
                "XABBER_WRAPPER_CAPTURE": str(capture),
                "XABBER_XCODE_CACHE_ROOT": str(fixture_root / "cache"),
                "XABBER_SCHEME": "Chat Performance UI Tests",
                "XABBER_DESTINATION": (
                    "platform=iOS Simulator,id=" + evidence.LOCKED_SIMULATOR_ID
                ),
            }
        )
        for action in ("build-for-testing", "test-without-building"):
            result = subprocess.run(
                [str(wrapper), action, "-jobs", "1"],
                cwd=fixture_root,
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            arguments = [
                line.split("=", 1)[1]
                for line in capture.read_text(encoding="utf-8").splitlines()
                if line.startswith("arg=")
            ]
            self.assertIn(action, arguments)
            self.assertNotIn(
                "test" if action == "test-without-building" else "build",
                arguments,
            )

    def test_test_command_accepts_realistic_distinct_app_container_uuid_only_in_verified_paths(self):
        app_container_uuid = "8C08FB23-9DF8-4C39-86DD-3A25B43955C2"
        realistic_container = (
            self.root
            / "Users/test/Library/Developer/CoreSimulator/Devices"
            / evidence.LOCKED_SIMULATOR_ID
            / "data/Containers/Data/Application"
            / app_container_uuid
        )
        export_directory = realistic_container / "Library/Caches"
        export_directory.mkdir(parents=True)
        signposts = export_directory / "n01-signposts.json"
        marker_events = export_directory / "n01-marker-events.json"
        command = self.valid_test_command(
            signposts,
            marker_events,
            data_container=realistic_container,
        )

        accepted = evidence.validate_test_command(
            command,
            expected_signpost_output=signposts,
            expected_marker_event_output=marker_events,
            expected_data_container=realistic_container,
        )

        self.assertTrue(accepted["app_data_container_verified"])
        self.assertEqual(accepted["simulator_udid"], evidence.LOCKED_SIMULATOR_ID)

    def test_test_command_rejects_uuid_outside_verified_container_assignments(self):
        app_container_uuid = "8C08FB23-9DF8-4C39-86DD-3A25B43955C2"
        foreign_uuid = "11111111-2222-3333-4444-555555555555"
        realistic_container = (
            self.root
            / "Users/test/Library/Developer/CoreSimulator/Devices"
            / evidence.LOCKED_SIMULATOR_ID
            / "data/Containers/Data/Application"
            / app_container_uuid
        )
        export_directory = realistic_container / "Library/Caches"
        export_directory.mkdir(parents=True)
        signposts = export_directory / "n01-signposts.json"
        marker_events = export_directory / "n01-marker-events.json"
        command = self.valid_test_command(
            signposts,
            marker_events,
            data_container=realistic_container,
        )
        wrapper_index = command.index(str(evidence.APPROVED_XCODEBUILD_WRAPPER))
        selector_index = next(
            index
            for index, value in enumerate(command)
            if value.startswith("-only-testing:")
        )
        destination_index = next(
            index
            for index, value in enumerate(command)
            if value.startswith("XABBER_DESTINATION=")
        )
        mutations = {
            "destination": command[:destination_index]
            + [command[destination_index].replace(evidence.LOCKED_SIMULATOR_ID, foreign_uuid)]
            + command[destination_index + 1 :],
            "wrapper": command[:wrapper_index]
            + [f"{evidence.APPROVED_XCODEBUILD_WRAPPER}-{foreign_uuid}"]
            + command[wrapper_index + 1 :],
            "selector": command[:selector_index]
            + [f"{command[selector_index]}-{foreign_uuid}"]
            + command[selector_index + 1 :],
            "extra argument": command[:selector_index]
            + [f"XABBER_FOREIGN_UUID={foreign_uuid}"]
            + command[selector_index:],
        }
        for label, mutation in mutations.items():
            with self.subTest(label=label):
                with self.assertRaises(evidence.EvidenceError):
                    evidence.validate_test_command(
                        mutation,
                        expected_signpost_output=signposts,
                        expected_marker_event_output=marker_events,
                        expected_data_container=realistic_container,
                    )

        for filename_uuid in (foreign_uuid, app_container_uuid):
            with self.subTest(filename_uuid=filename_uuid):
                uuid_named_signposts = export_directory / f"n01-{filename_uuid}.json"
                uuid_named_export_command = [
                    f"XABBER_CHAT_SIGNPOST_EXPORT_PATH={uuid_named_signposts}"
                    if value.startswith("XABBER_CHAT_SIGNPOST_EXPORT_PATH=")
                    else value
                    for value in command
                ]
                with self.assertRaisesRegex(evidence.EvidenceError, "simulator other"):
                    evidence.validate_test_command(
                        uuid_named_export_command,
                        expected_signpost_output=uuid_named_signposts,
                        expected_marker_event_output=marker_events,
                        expected_data_container=realistic_container,
                    )

        raw = self.root / "capture.mov"
        with self.assertRaisesRegex(evidence.EvidenceError, "simulator other"):
            evidence.validate_capture_command(
                evidence.LOCKED_SIMULATOR_ID,
                raw,
                [
                    "/usr/sbin/screencapture",
                    "-v",
                    "-l12345",
                    f"--foreign-uuid={foreign_uuid}",
                    str(raw),
                ],
                window_snapshot_provider=lambda _window_id: self.valid_window_snapshot(),
            )

    def test_test_command_rejects_unverified_wrong_prefix_and_sibling_uuid_paths(self):
        app_container_uuid = "8C08FB23-9DF8-4C39-86DD-3A25B43955C2"
        other_container_uuid = "4D47AC11-942E-414C-A8CD-57B222D46B87"
        application_root = (
            self.root
            / "Users/test/Library/Developer/CoreSimulator/Devices"
            / evidence.LOCKED_SIMULATOR_ID
            / "data/Containers/Data/Application"
        )
        expected_container = application_root / app_container_uuid
        expected_export_directory = expected_container / "Library/Caches"
        expected_export_directory.mkdir(parents=True)
        expected_signposts = expected_export_directory / "n01-signposts.json"
        expected_marker_events = expected_export_directory / "n01-marker-events.json"

        other_container = application_root / other_container_uuid
        other_export_directory = other_container / "Library/Caches"
        other_export_directory.mkdir(parents=True)
        other_signposts = other_export_directory / "n01-signposts.json"
        other_marker_events = other_export_directory / "n01-marker-events.json"
        with self.assertRaisesRegex(evidence.EvidenceError, "does not match"):
            evidence.validate_test_command(
                self.valid_test_command(
                    other_signposts,
                    other_marker_events,
                    data_container=other_container,
                ),
                expected_signpost_output=other_signposts,
                expected_marker_event_output=other_marker_events,
                expected_data_container=expected_container,
            )

        prefix_container = application_root / f"{app_container_uuid}-sibling"
        prefix_export_directory = prefix_container / "Library/Caches"
        prefix_export_directory.mkdir(parents=True)
        prefix_signposts = prefix_export_directory / "n01-signposts.json"
        prefix_command = self.valid_test_command(
            expected_signposts,
            expected_marker_events,
            data_container=expected_container,
        )
        prefix_command = [
            f"XABBER_CHAT_SIGNPOST_EXPORT_PATH={prefix_signposts}"
            if value.startswith("XABBER_CHAT_SIGNPOST_EXPORT_PATH=")
            else value
            for value in prefix_command
        ]
        with self.assertRaisesRegex(evidence.EvidenceError, "inside"):
            evidence.validate_test_command(
                prefix_command,
                expected_signpost_output=prefix_signposts,
                expected_marker_event_output=expected_marker_events,
                expected_data_container=expected_container,
            )

        with self.assertRaisesRegex(evidence.EvidenceError, "simulator other"):
            evidence.validate_test_command(
                self.valid_test_command(
                    expected_signposts,
                    expected_marker_events,
                    data_container=expected_container,
                ),
                expected_signpost_output=expected_signposts,
                expected_marker_event_output=expected_marker_events,
            )

    @staticmethod
    def valid_route_binding():
        return {
            "test_selector": "testChatOpenN01PreloadedLatestVideoRoute",
            "matrix_route_code": "N01",
            "fixture_scenario": "preloaded-latest",
        }

    def valid_capture_test_preflight(self, command_hash="f" * 64):
        return {
            "command_sha256": command_hash,
            "selector_count": 1,
            "test_without_building": True,
            "prebuilt_build_receipt_sha256": "a" * 64,
            "prebuilt_build_command_sha256": "b" * 64,
            "prebuilt_build_products_manifest_sha256": "c" * 64,
            "prebuilt_binary_provenance_closed": True,
            "prebuilt_destination_architecture": "arm64",
            "prebuilt_xctestrun_selection_policy": "locked_simulator_sdk_arm64",
            "prebuilt_xctestrun_count": 1,
            "prebuilt_referenced_product_count": 4,
            "prebuilt_runnable_executable_count": 4,
            "prebuilt_referenced_regular_file_count": 12,
            "prebuilt_referenced_regular_file_byte_count": 1024,
            "prebuilt_referenced_files_manifest_sha256": "d" * 64,
            **self.valid_route_binding(),
        }

    def test_capture_receipt_rejects_legacy_xctestrun_only_binary_provenance(self):
        preflight = self.valid_capture_test_preflight()
        accepted = evidence.validate_capture_receipt_prebuilt_binary_provenance(
            preflight
        )
        self.assertTrue(accepted["binary_provenance_closed"])
        self.assertFalse(accepted["contains_paths"])

        legacy = {
            key: value
            for key, value in preflight.items()
            if key
            in {
                "prebuilt_build_receipt_sha256",
                "prebuilt_build_command_sha256",
                "prebuilt_build_products_manifest_sha256",
                "prebuilt_xctestrun_count",
            }
        }
        mutations = (
            legacy,
            dict(preflight, prebuilt_binary_provenance_closed=False),
            dict(preflight, prebuilt_referenced_product_count=3),
            dict(preflight, prebuilt_runnable_executable_count=3),
            dict(preflight, prebuilt_referenced_regular_file_count=0),
            dict(preflight, prebuilt_referenced_regular_file_byte_count=0),
            dict(preflight, prebuilt_referenced_files_manifest_sha256="invalid"),
        )
        for mutation in mutations:
            with self.subTest(keys=sorted(mutation)):
                with self.assertRaises(evidence.EvidenceError):
                    evidence.validate_capture_receipt_prebuilt_binary_provenance(
                        mutation
                    )

    def numeric_signposts(self, calibration=None):
        calibration = calibration or self.calibration()
        phase_manifest = evidence.load_signpost_phase_manifest()
        base = calibration["markers"][0]["uptime_ns"]
        return {
            "schema_version": 1,
            "phase_manifest_sha256": phase_manifest["sha256"],
            "phase_count": len(phase_manifest["phases"]),
            "records": [
                {
                    "sequence": 1,
                    "record_kind_code": 1,
                    "phase_code": 1,
                    "trace_id": 10,
                    "generation": 20,
                    "operation_kind_code": 1,
                    "purpose_code": 1,
                    "terminal_code": 0,
                    "uptime_ns": base,
                    "thread_code": 1,
                    "counters": [{"code": 16, "value": 1}],
                },
                {
                    "sequence": 2,
                    "record_kind_code": 3,
                    "phase_code": 16,
                    "trace_id": 10,
                    "generation": 20,
                    "operation_kind_code": 1,
                    "purpose_code": 1,
                    "terminal_code": 1,
                    "uptime_ns": base + 120_000_000,
                    "thread_code": 1,
                    "counters": [],
                },
            ],
        }

    def test_analysis_uses_measured_pts_not_requested_fps(self):
        raw = self.root / "raw.mov"
        raw.write_bytes(b"raw-authority")
        probe = self.probe(
            [Decimal("0"), Decimal("0.020"), Decimal("0.041")],
            duration=Decimal("0.061"),
            rate="50/1",
        )
        report = evidence.analyze_probe(raw, probe, requested_fps=60)
        self.assertFalse(report["source"]["native_60_proven"])
        self.assertEqual(report["recorder_request"]["fps"], 60)
        self.assertFalse(report["recorder_request"]["accepted_as_rate_proof"])

    def test_grid_preserves_every_collision_and_duplicate(self):
        plan = evidence.build_grid_plan(
            [Decimal("0"), Decimal("0.005"), Decimal("0.010"), Decimal("0.040")],
            Decimal("0.050"),
        )
        self.assertEqual(
            [sample["target_grid_index"] for sample in plan["samples"]],
            [0, 1, 1, 3],
        )
        self.assertEqual(plan["collision_sample_count"], 2)
        self.assertEqual(plan["grid_frames"][2]["provenance"], "duplicate_of_source_sample")

    def test_normalization_ignores_unused_vfr_timestamps_without_losing_frame_provenance(self):
        ffmpeg = shutil.which("ffmpeg")
        ffprobe = shutil.which("ffprobe")
        self.assertIsNotNone(ffmpeg)
        self.assertIsNotNone(ffprobe)
        raw = self.root / "synthetic-vfr.mov"
        synthetic_filter = (
            "settb=expr=1/60000,"
            "setpts=PTS+if(eq(N\\,3)\\,600\\,"
            "if(eq(N\\,4)\\,400\\,"
            "if(eq(N\\,5)\\,800\\,"
            "if(eq(N\\,6)\\,600\\,0))))"
        )
        generated = subprocess.run(
            [
                ffmpeg,
                "-v",
                "error",
                "-f",
                "lavfi",
                "-i",
                "testsrc2=size=32x32:rate=60",
                "-vf",
                synthetic_filter,
                "-frames:v",
                "12",
                "-fps_mode",
                "vfr",
                "-enc_time_base",
                "1:60000",
                "-c:v",
                "libx264",
                "-pix_fmt",
                "yuv420p",
                "-video_track_timescale",
                "60000",
                "-movflags",
                "+faststart",
                str(raw),
            ],
            capture_output=True,
            check=False,
        )
        self.assertEqual(generated.returncode, 0, generated.stderr.decode("utf-8"))

        legacy_decode = subprocess.run(
            [
                ffmpeg,
                "-v",
                "error",
                "-i",
                str(raw),
                "-map",
                "0:v:0",
                "-fps_mode",
                "passthrough",
                "-f",
                "rawvideo",
                "-pix_fmt",
                "rgb24",
                "pipe:1",
            ],
            capture_output=True,
            check=False,
        )
        self.assertEqual(legacy_decode.returncode, 0)
        self.assertIn(
            b"non monotonically increasing dts",
            legacy_decode.stderr,
        )

        probe = evidence.run_ffprobe(raw, ffprobe_path=ffprobe)

        exact_detection = lambda marker_id, visual_code: {
            "status": "exact",
            "marker_id": marker_id,
            "visual_code": visual_code,
            "score_milli": 900,
        }
        marker_detections = (
            [exact_detection("M1", "vertical_bars")] * 2
            + [exact_detection("M2", "checkerboard")] * 2
            + [exact_detection("M3", "concentric_rings")] * 8
        )
        with mock.patch.object(
            evidence,
            "classify_video_marker_frame",
            side_effect=marker_detections,
        ) as classifier:
            marker_runs = evidence._detect_marker_runs_in_video(
                raw,
                probe,
                ffmpeg_path=ffmpeg,
            )
        self.assertEqual(classifier.call_count, 12)
        self.assertEqual(
            [run["start_index"] for run in marker_runs],
            [0, 2, 4],
        )

        derivative = self.root / "cfr60.mp4"
        sidecar_path = self.root / "source-to-grid.json"
        framemd5 = self.root / "cfr60-pre-encode.framemd5"
        collisions = self.root / "collisions"
        result = evidence.normalize_video(
            raw_path=raw,
            probe_data=probe,
            derivative_path=derivative,
            sidecar_path=sidecar_path,
            framemd5_path=framemd5,
            collision_directory=collisions,
            codec="h264",
            disk_reserve_bytes=0,
            max_bitrate_mbps=Decimal("1"),
            ffmpeg_path=ffmpeg,
            ffprobe_path=ffprobe,
        )

        sidecar = json.loads(sidecar_path.read_text(encoding="utf-8"))
        mapping = sidecar["mapping"]
        recomputed = evidence._recompute_grid_evidence(
            raw_path=raw,
            probe_data=probe,
            expected_plan=mapping,
            ffmpeg_path=ffmpeg,
        )
        mapped_source_hashes = {
            sample["source_index"]: sample["decoded_rgb_sha256"]
            for sample in mapping["samples"]
        }
        self.assertEqual(result["source_sample_count"], 12)
        self.assertEqual(mapped_source_hashes, recomputed["source_sha256"])
        self.assertEqual(
            evidence._framemd5_hashes(framemd5),
            recomputed["grid_md5"],
        )
        self.assertEqual(
            sidecar["raw_integrity"]["sha256_before"],
            sidecar["raw_integrity"]["sha256_after"],
        )

    def test_exact_reader_reassembles_partial_pipe_reads(self):
        class PartialReadStream(io.BytesIO):
            def read(self, size=-1):
                return super().read(min(size, 7) if size >= 0 else 7)

        expected = bytes(range(64))
        stream = PartialReadStream(expected)

        self.assertEqual(evidence._read_exact(stream, len(expected)), expected)
        self.assertEqual(stream.read(1), b"")

    def test_rgb_decoder_requires_a_positive_ffmpeg_bounded_source_time_base(self):
        valid_probe = self.probe(
            [Decimal("0"), Decimal("0.020")],
            duration=Decimal("0.040"),
        )
        valid_probe["streams"][0]["time_base"] = "1/600"
        command = evidence._raw_rgb_decoder_command(
            "ffmpeg",
            self.root / "raw.mov",
            valid_probe,
        )
        self.assertIn("-fps_mode", command)
        self.assertEqual(command[command.index("-enc_time_base") + 1], "1:600")

        for invalid_time_base in (None, "0/1", "1/2147483648"):
            invalid_probe = json.loads(json.dumps(valid_probe))
            invalid_probe["streams"][0]["time_base"] = invalid_time_base
            with self.subTest(time_base=invalid_time_base):
                with self.assertRaisesRegex(evidence.EvidenceError, "time_base"):
                    evidence._raw_rgb_decoder_command(
                        "ffmpeg",
                        self.root / "raw.mov",
                        invalid_probe,
                    )

    def test_exact_three_markers_derive_only_offline_indices_pts_and_hashes(self):
        calibration = self.calibration()
        self.assertEqual(
            [marker["source_index"] for marker in calibration["markers"]],
            [self.M1_SOURCE_INDEX, self.M2_SOURCE_INDEX, self.M3_SOURCE_INDEX],
        )
        self.assertEqual(
            [marker["source_pts_seconds"] for marker in calibration["markers"]],
            ["0.040000000", "2.040000000", "4.040000000"],
        )
        self.assertEqual(calibration["raw_video_sha256"], "a" * 64)
        self.assertEqual(calibration["marker_event_sha256"], "b" * 64)
        self.assertEqual(
            calibration["marker_manifest_sha256"],
            hashlib.sha256(b"M1:vertical_bars\nM2:checkerboard\nM3:concentric_rings").hexdigest(),
        )
        self.assertTrue(all(marker["run_frame_count"] >= 2 for marker in calibration["markers"]))
        self.assertTrue(all(marker["detection_score_milli"] >= 740 for marker in calibration["markers"]))

    def test_derivation_rejects_lucky_short_span_that_cannot_prove_drift_bound(self):
        frames = self.short_marker_sequence()
        with self.assertRaisesRegex(
            evidence.EvidenceError,
            "marker span cannot prove the closed drift bound",
        ):
            evidence.derive_video_calibration_from_frames(
                frames=frames,
                width=self.WIDTH,
                height=self.HEIGHT,
                source_pts=self.source_pts(len(frames)),
                raw_video_sha256="a" * 64,
                marker_events=self.marker_events(),
                marker_event_sha256="b" * 64,
                phase_manifest_sha256=evidence.load_signpost_phase_manifest()["sha256"],
            )

    def test_derivation_applies_the_same_drift_gate_as_final_validation(self):
        frames = self.short_marker_sequence()
        source_pts = self.source_pts(len(frames))
        source_pts[5] = Decimal("0.141666")
        source_pts[6] = Decimal("0.180000")
        source_pts[7] = Decimal("0.220000")
        source_pts[8] = Decimal("0.263333")
        for index in range(9, len(source_pts)):
            source_pts[index] = source_pts[8] + Decimal(index - 8) * Decimal("0.020")
        marker_events = self.marker_events()
        marker_events["events"][0]["uptime_ns"] = 100_000_000_000
        marker_events["events"][1]["uptime_ns"] = 100_100_000_000
        marker_events["events"][2]["uptime_ns"] = 100_216_666_667

        with self.assertRaises(evidence.EvidenceError):
            evidence.derive_video_calibration_from_frames(
                frames=frames,
                width=self.WIDTH,
                height=self.HEIGHT,
                source_pts=source_pts,
                raw_video_sha256="a" * 64,
                marker_events=marker_events,
                marker_event_sha256="b" * 64,
                phase_manifest_sha256=evidence.load_signpost_phase_manifest()["sha256"],
            )

    def test_exact_n01_fit_numbers_are_frozen_before_fail_closed_span_gate(self):
        fit = evidence._least_squares_affine_fit(
            [
                Decimal("18.451667"),
                Decimal("18.553333"),
                Decimal("18.675000"),
            ],
            [
                Decimal("21252.033333333"),
                Decimal("21252.133333333"),
                Decimal("21252.250000000"),
            ],
        )
        self.assertEqual(
            evidence._seconds(fit["slope"]),
            "0.969785789",
        )
        self.assertEqual(
            evidence._seconds(fit["drift_ppm"]),
            "30214.210564799",
        )
        self.assertEqual(
            [evidence._seconds(value) for value in fit["residuals"]],
            ["-0.000495752", "0.000910006", "-0.000414254"],
        )
        self.assertEqual(
            evidence._seconds(fit["maximum_residual"]),
            "0.000910006",
        )

    def test_production_marker_dwell_spans_the_closed_rate_proof_window(self):
        source = (
            evidence.REPOSITORY_ROOT
            / "xabber/controllers/chats/chat/ChatPerformanceIntegrationGate.swift"
        ).read_text(encoding="utf-8")

        def duration(named):
            match = __import__("re").search(
                rf"static let {named}: TimeInterval = ([0-9]+(?:\\.[0-9]+)?)",
                source,
            )
            self.assertIsNotNone(match, named)
            return Decimal(match.group(1))

        measured_span = duration("m1MinimumVisibleDuration") + duration(
            "m2MinimumVisibleDuration"
        )
        self.assertGreaterEqual(
            measured_span,
            evidence.MIN_CLOCK_CALIBRATION_PROVABLE_SPAN,
        )

    def test_marker_event_export_cannot_author_source_index_or_pts(self):
        marker_events = self.marker_events()
        marker_events["events"][0]["source_index"] = 2
        with self.assertRaisesRegex(evidence.EvidenceError, "closed three-field"):
            evidence.validate_marker_events(marker_events)

    def test_near_and_ambiguous_marker_patterns_fail_closed(self):
        for variant, expected in (("near", "near_pattern"), ("ambiguous", "ambiguous_pattern")):
            frames = self.exact_marker_sequence()
            frames[self.M2_SOURCE_INDEX] = self.frame(
                "checkerboard", variant=variant
            )
            frames[self.M2_SOURCE_INDEX + 1] = self.frame(
                "checkerboard", variant=variant
            )
            with self.subTest(variant=variant):
                with self.assertRaisesRegex(evidence.EvidenceError, expected):
                    evidence.derive_video_calibration_from_frames(
                        frames=frames,
                        width=self.WIDTH,
                        height=self.HEIGHT,
                        source_pts=self.source_pts(len(frames)),
                        raw_video_sha256="a" * 64,
                        marker_events=self.marker_events(),
                        marker_event_sha256="b" * 64,
                        phase_manifest_sha256=evidence.load_signpost_phase_manifest()["sha256"],
                    )

    def test_marker_pattern_score_boundaries_are_mutually_exclusive(self):
        near = evidence.classify_video_marker_frame(
            self.frame("checkerboard", variant="near"),
            self.WIDTH,
            self.HEIGHT,
        )
        self.assertEqual(near["status"], "near_pattern")
        self.assertLess(
            max(near["pattern_scores_milli"].values()),
            evidence.MIN_MARKER_PATTERN_SCORE_MILLI,
        )

        ambiguous = evidence.classify_video_marker_frame(
            self.frame("checkerboard", variant="ambiguous"),
            self.WIDTH,
            self.HEIGHT,
        )
        self.assertEqual(ambiguous["status"], "ambiguous_pattern")
        ranked = sorted(ambiguous["pattern_scores_milli"].values(), reverse=True)
        self.assertGreaterEqual(
            ranked[0], evidence.MIN_MARKER_PATTERN_SCORE_MILLI
        )
        self.assertLess(
            ranked[0] - ranked[1],
            evidence.MIN_MARKER_PATTERN_MARGIN_MILLI,
        )

    def test_missing_unstable_duplicate_and_out_of_order_runs_fail_closed(self):
        absent = self.frame()
        cases = {
            "missing marker M2": (
                [absent, absent]
                + [self.frame("vertical_bars")] * 2
                + [absent] * 4
                + [self.frame("concentric_rings")] * 26
            ),
            "not stable": (
                [absent, absent]
                + [self.frame("vertical_bars")]
                + [absent]
                + [self.frame("checkerboard")] * 2
                + [absent]
                + [self.frame("concentric_rings")] * 26
            ),
            "disjoint duplicate": (
                [absent]
                + [self.frame("vertical_bars")] * 2
                + [absent]
                + [self.frame("vertical_bars")] * 2
                + [self.frame("checkerboard")] * 2
                + [self.frame("concentric_rings")] * 26
            ),
            "onset order": (
                [absent]
                + [self.frame("checkerboard")] * 2
                + [absent]
                + [self.frame("vertical_bars")] * 2
                + [absent]
                + [self.frame("concentric_rings")] * 26
            ),
        }
        for expected, frames in cases.items():
            with self.subTest(expected=expected):
                with self.assertRaisesRegex(evidence.EvidenceError, expected):
                    evidence.derive_video_calibration_from_frames(
                        frames=frames,
                        width=self.WIDTH,
                        height=self.HEIGHT,
                        source_pts=self.source_pts(len(frames)),
                        raw_video_sha256="a" * 64,
                        marker_events=self.marker_events(),
                        marker_event_sha256="b" * 64,
                        phase_manifest_sha256=evidence.load_signpost_phase_manifest()["sha256"],
                    )

    def test_post_m3_tail_must_span_at_least_500_milliseconds(self):
        frames = self.exact_marker_sequence()[:227]
        with self.assertRaisesRegex(evidence.EvidenceError, "500 ms post-M3"):
            evidence.derive_video_calibration_from_frames(
                frames=frames,
                width=self.WIDTH,
                height=self.HEIGHT,
                source_pts=self.source_pts(len(frames)),
                raw_video_sha256="a" * 64,
                marker_events=self.marker_events(),
                marker_event_sha256="b" * 64,
                phase_manifest_sha256=evidence.load_signpost_phase_manifest()["sha256"],
            )

    def test_clock_fit_is_bound_to_raw_pts_and_one_compositor_frame_residual(self):
        calibration = self.calibration()
        pts = self.source_pts(len(self.exact_marker_sequence()))
        mapping = evidence.derive_clock_mapping(calibration, pts)
        self.assertEqual(mapping["marker_count"], 3)
        self.assertLessEqual(
            Decimal(mapping["maximum_residual_seconds"]),
            evidence.GRID_INTERVAL + evidence.GRID_EPSILON,
        )
        self.assertEqual(mapping["source_marker_span_seconds"], "4.000000000")
        self.assertEqual(mapping["uptime_marker_span_seconds"], "4.000000000")
        self.assertEqual(
            mapping["minimum_provable_marker_span_seconds"],
            evidence._seconds(evidence.MIN_CLOCK_CALIBRATION_PROVABLE_SPAN),
        )
        self.assertTrue(mapping["source_indices_authored_offline_from_raw_video"])

        tampered = json.loads(json.dumps(calibration))
        tampered["markers"][1]["uptime_ns"] += 100_000_000
        with self.assertRaises(evidence.EvidenceError):
            evidence.derive_clock_mapping(tampered, pts)
        tampered = json.loads(json.dumps(calibration))
        tampered["markers"][0]["source_pts_seconds"] = "0.000000000"
        with self.assertRaisesRegex(evidence.EvidenceError, "raw ffprobe PTS"):
            evidence.derive_clock_mapping(tampered, pts)

    def test_calibration_hash_binding_rejects_raw_event_phase_or_marker_tampering(self):
        calibration = self.calibration()
        phase_hash = evidence.load_signpost_phase_manifest()["sha256"]
        evidence.validate_calibration_bindings(
            calibration,
            raw_video_sha256="a" * 64,
            marker_event_sha256="b" * 64,
            phase_manifest_sha256=phase_hash,
        )
        mutations = (
            {"raw_video_sha256": "c" * 64},
            {"marker_event_sha256": "c" * 64},
            {"phase_manifest_sha256": "c" * 64},
            {"marker_manifest_sha256": "c" * 64},
        )
        for mutation in mutations:
            changed = dict(calibration)
            changed.update(mutation)
            with self.subTest(mutation=mutation):
                with self.assertRaisesRegex(evidence.EvidenceError, "hash binding"):
                    evidence.validate_calibration_bindings(
                        changed,
                        raw_video_sha256="a" * 64,
                        marker_event_sha256="b" * 64,
                        phase_manifest_sha256=phase_hash,
                    )

    def test_numeric_signposts_are_accepted_and_legacy_strings_rejected(self):
        calibration = self.calibration()
        phase_manifest = evidence.load_signpost_phase_manifest()
        correlated = evidence.correlate_signposts(
            self.numeric_signposts(calibration),
            calibration=calibration,
            phase_manifest=phase_manifest,
            source_pts=self.source_pts(len(self.exact_marker_sequence())),
        )
        self.assertEqual([record["sequence"] for record in correlated], [1, 2])
        self.assertEqual(correlated[0]["phase"], "chat.open_request")
        self.assertEqual(correlated[0]["counters"], [{"code": 16, "value": 1}])

        legacy = {
            "schema_version": 1,
            "phase_manifest_sha256": phase_manifest["sha256"],
            "events": [
                {"phase": "chat.open_request", "monotonic_nanoseconds": 1}
            ],
        }
        with self.assertRaisesRegex(evidence.EvidenceError, "closed numeric"):
            evidence.correlate_signposts(
                legacy,
                calibration=calibration,
                phase_manifest=phase_manifest,
                source_pts=self.source_pts(len(self.exact_marker_sequence())),
            )

    def test_numeric_signpost_schema_rejects_code_order_and_terminal_mutations(self):
        calibration = self.calibration()
        phase_manifest = evidence.load_signpost_phase_manifest()
        mutations = []
        duplicate_sequence = self.numeric_signposts(calibration)
        duplicate_sequence["records"][1]["sequence"] = 1
        mutations.append(duplicate_sequence)
        bad_phase = self.numeric_signposts(calibration)
        bad_phase["records"][0]["phase_code"] = 0
        mutations.append(bad_phase)
        bad_terminal = self.numeric_signposts(calibration)
        bad_terminal["records"][0]["terminal_code"] = 1
        mutations.append(bad_terminal)
        duplicate_counter = self.numeric_signposts(calibration)
        duplicate_counter["records"][0]["counters"] = [
            {"code": 16, "value": 1},
            {"code": 16, "value": 2},
        ]
        mutations.append(duplicate_counter)
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                with self.assertRaises(evidence.EvidenceError):
                    evidence.correlate_signposts(
                        mutation,
                        calibration=calibration,
                        phase_manifest=phase_manifest,
                        source_pts=self.source_pts(len(self.exact_marker_sequence())),
                    )

    def test_test_command_uses_legacy_environment_key_only_for_marker_event_path(self):
        signposts = self.app_artifact_directory / "signposts.json"
        marker_events = self.app_artifact_directory / "marker-events.json"
        command = self.valid_test_command(signposts, marker_events)
        accepted = evidence.validate_test_command(
            command,
            expected_signpost_output=signposts,
            expected_marker_event_output=marker_events,
            expected_data_container=self.app_data_container,
        )
        self.assertEqual(accepted["selector_count"], 1)
        self.assertEqual(
            accepted["test_selector"],
            "testChatOpenN01PreloadedLatestVideoRoute",
        )
        self.assertEqual(accepted["matrix_route_code"], "N01")
        self.assertEqual(accepted["fixture_scenario"], "preloaded-latest")
        self.assertTrue(accepted["app_data_container_verified"])
        shared = [
            f"XABBER_CHAT_VIDEO_CALIBRATION_EXPORT_PATH={signposts}"
            if value.startswith("XABBER_CHAT_VIDEO_CALIBRATION_EXPORT_PATH=")
            else value
            for value in command
        ]
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate_test_command(
                shared,
                expected_signpost_output=signposts,
                expected_marker_event_output=marker_events,
                expected_data_container=self.app_data_container,
            )

    def test_test_command_requires_exact_single_worker_and_no_diagnostics_flags(self):
        signposts = self.app_artifact_directory / "signposts.json"
        marker_events = self.app_artifact_directory / "marker-events.json"
        command = self.valid_test_command(signposts, marker_events)

        accepted = evidence.validate_test_command(
            command,
            expected_signpost_output=signposts,
            expected_marker_event_output=marker_events,
            expected_data_container=self.app_data_container,
        )
        self.assertEqual(accepted["worker_job_limit"], 1)
        self.assertTrue(accepted["test_diagnostics_collection_disabled"])

        jobs_index = command.index("-jobs")
        diagnostics_index = command.index("-collect-test-diagnostics")
        selector_index = next(
            index
            for index, value in enumerate(command)
            if value.startswith("-only-testing:")
        )
        mutations = {
            "missing jobs": command[:jobs_index] + command[jobs_index + 2 :],
            "multiple jobs": (
                command[: jobs_index + 1]
                + ["2"]
                + command[jobs_index + 2 :]
            ),
            "duplicate jobs": (
                command[:diagnostics_index]
                + ["-jobs", "1"]
                + command[diagnostics_index:]
            ),
            "missing diagnostics policy": (
                command[:diagnostics_index] + command[diagnostics_index + 2 :]
            ),
            "on-failure diagnostics": (
                command[: diagnostics_index + 1]
                + ["on-failure"]
                + command[diagnostics_index + 2 :]
            ),
            "unapproved argument": (
                command[:diagnostics_index]
                + ["-quiet"]
                + command[diagnostics_index:]
            ),
            "unsafe action": [
                "clean" if value == "test-without-building" else value
                for value in command
            ],
            "booted destination": [
                value.replace(evidence.LOCKED_SIMULATOR_ID, "booted")
                for value in command
            ],
            "other simulator": [
                value.replace(
                    evidence.LOCKED_SIMULATOR_ID,
                    "11111111-2222-3333-4444-555555555555",
                )
                for value in command
            ],
            "second destination": (
                command[:selector_index]
                + [
                    "XABBER_DESTINATION=platform=iOS Simulator,id="
                    f"{evidence.LOCKED_SIMULATOR_ID}"
                ]
                + command[selector_index:]
            ),
        }
        for label, mutation in mutations.items():
            with self.subTest(label=label):
                with self.assertRaises(evidence.EvidenceError):
                    evidence.validate_test_command(
                        mutation,
                        expected_signpost_output=signposts,
                        expected_marker_event_output=marker_events,
                        expected_data_container=self.app_data_container,
                    )

    def test_goal_runner_defaults_to_debug_and_forwards_exact_test_safety_arguments(self):
        fixture_root = self.root / "goal-runner-fixture"
        fixture_tools = fixture_root / "tools"
        fixture_bin = fixture_root / "bin"
        fixture_tools.mkdir(parents=True)
        fixture_bin.mkdir()
        repository_root = Path(__file__).resolve().parents[2]
        runner = fixture_tools / "run_chat_goal_tests.sh"
        manifest = fixture_tools / "chat_goal_test_manifest.sh"
        wrapper = fixture_tools / "xcodebuild_cached.sh"
        fake_git = fixture_bin / "git"
        fake_xcrun = fixture_bin / "xcrun"
        capture = fixture_root / "captured-command.txt"
        shutil.copy2(repository_root / "tools/run_chat_goal_tests.sh", runner)
        shutil.copy2(repository_root / "tools/chat_goal_test_manifest.sh", manifest)
        wrapper.write_text(
            "#!/bin/sh\n"
            "{\n"
            "  printf 'scheme=%s\\n' \"$XABBER_SCHEME\"\n"
            "  printf 'destination=%s\\n' \"$XABBER_DESTINATION\"\n"
            "  for argument in \"$@\"; do printf 'arg=%s\\n' \"$argument\"; done\n"
            "} > \"$CHAT_GOAL_RUNNER_CAPTURE\"\n",
            encoding="utf-8",
        )
        fake_git.write_text("#!/bin/sh\nprintf '%s\\n' deadbeef\n", encoding="utf-8")
        fake_xcrun.write_text(
            "#!/bin/sh\n"
            "[ \"$1 $2 $3 $4\" = \"simctl list devices booted\" ] || exit 64\n"
            "printf '%s\\n' '== Devices ==' '-- iOS 26.0 --' "
            f"'    Locked iPhone ({evidence.LOCKED_SIMULATOR_ID}) (Booted)'\n",
            encoding="utf-8",
        )
        wrapper.chmod(0o755)
        fake_git.chmod(0o755)
        fake_xcrun.chmod(0o755)

        environment = os.environ.copy()
        environment.update(
            {
                "PATH": f"{fixture_bin}:/usr/bin:/bin",
                "CHAT_GOAL_RUNNER_CAPTURE": str(capture),
                "XABBER_XCODE_CACHE_ROOT": str(fixture_root / "cache"),
                "XABBER_DESTINATION": (
                    "platform=iOS Simulator,id="
                    f"{evidence.LOCKED_SIMULATOR_ID}"
                ),
                "TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT": "1",
                "TEST_RUNNER_XABBER_ISOLATED_STORAGE": "1",
            }
        )
        environment.pop("XABBER_SCHEME", None)
        result = subprocess.run(
            [str(runner), "focused", "G06"],
            cwd=fixture_root,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        captured_lines = capture.read_text(encoding="utf-8").splitlines()
        self.assertIn("scheme=Debug", captured_lines)
        self.assertIn(
            f"destination=platform=iOS Simulator,id={evidence.LOCKED_SIMULATOR_ID}",
            captured_lines,
        )
        arguments = [
            line.removeprefix("arg=")
            for line in captured_lines
            if line.startswith("arg=")
        ]
        self.assertEqual(
            arguments[:7],
            [
                "test",
                "-jobs",
                "1",
                "-parallel-testing-enabled",
                "NO",
                "-collect-test-diagnostics",
                "never",
            ],
        )
        self.assertTrue(
            all(
                selector.startswith("-only-testing:xabberTests/")
                for selector in arguments[7:]
            )
        )

        runner_source = runner.read_text(encoding="utf-8")
        self.assertNotIn("Debug (xabber Workspace)", runner_source)
        self.assertEqual(
            runner_source.count('${chat_test_safety_arguments[@]}'),
            3,
        )

    def testClosedVideoRouteManifestAcceptsE04UnsyncedStaleLocalOnlyUnderItsCanonicalBinding(self):
        selector = "testChatOpenE04UnsyncedStaleLocalRowsVideoRoute"
        canonical = {
            "test_selector": selector,
            "matrix_route_code": "E04",
            "fixture_scenario": "bootstrap-stale-local-to-content",
        }

        self.assertEqual(
            evidence.CHAT_OPEN_VIDEO_ROUTE_MANIFEST.get(selector),
            {
                "matrix_route_code": "E04",
                "fixture_scenario": "bootstrap-stale-local-to-content",
            },
        )
        self.assertEqual(evidence._closed_route_binding(canonical), canonical)

        rejected_aliases = [
            dict(canonical, test_selector="testChatOpenE02ContentVideoRoute"),
            dict(canonical, matrix_route_code="E02-content"),
            dict(canonical, fixture_scenario="bootstrap-empty-to-content"),
            dict(canonical, test_selector="testChatOpenArbitraryE04VideoRoute"),
        ]
        for alias in rejected_aliases:
            with self.subTest(alias=alias):
                with self.assertRaises(evidence.EvidenceError):
                    evidence._closed_route_binding(alias)

    def testClosedVideoRouteManifestAcceptsCanonicalX01SelectorAndRejectsLegacyAlias(self):
        selector = "testChatOpenX01SearchExactLocalVideoRoute"
        canonical = {
            "test_selector": selector,
            "matrix_route_code": "X01",
            "fixture_scenario": "search-exact-local",
        }

        self.assertEqual(
            evidence.CHAT_OPEN_VIDEO_ROUTE_MANIFEST.get(selector),
            {
                "matrix_route_code": "X01",
                "fixture_scenario": "search-exact-local",
            },
        )
        self.assertEqual(evidence._closed_route_binding(canonical), canonical)

        rejected_aliases = [
            dict(
                canonical,
                test_selector=(
                    "testChatOpenSearchExactLocalStartsOnAnchorWithoutLatestFrame"
                ),
            ),
            dict(
                canonical,
                test_selector="testChatOpenX02SearchExactLocalOutsideWindowVideoRoute",
            ),
            dict(canonical, matrix_route_code="X02"),
            dict(canonical, matrix_route_code="P01"),
            dict(canonical, fixture_scenario="search-exact-local-outside-window"),
            dict(canonical, test_selector="testChatOpenArbitraryX01VideoRoute"),
        ]
        for alias in rejected_aliases:
            with self.subTest(alias=alias):
                with self.assertRaises(evidence.EvidenceError):
                    evidence._closed_route_binding(alias)

        signposts = self.app_artifact_directory / "x01-signposts.json"
        marker_events = self.app_artifact_directory / "x01-marker-events.json"
        command = self.valid_test_command(signposts, marker_events)
        command = [
            value.replace(
                "testChatOpenN01PreloadedLatestVideoRoute",
                selector,
            )
            for value in command
        ]
        accepted = evidence.validate_test_command(
            command,
            expected_signpost_output=signposts,
            expected_marker_event_output=marker_events,
            expected_data_container=self.app_data_container,
        )
        self.assertEqual(accepted["test_selector"], selector)
        self.assertEqual(accepted["matrix_route_code"], "X01")
        self.assertEqual(accepted["fixture_scenario"], "search-exact-local")

        wrong_simulator = [
            value.replace(evidence.LOCKED_SIMULATOR_ID, "DEAD-BEEF-C302")
            for value in command
        ]
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate_test_command(
                wrong_simulator,
                expected_signpost_output=signposts,
                expected_marker_event_output=marker_events,
                expected_data_container=self.app_data_container,
            )

    def testClosedVideoRouteManifestBindsMentionSelectorsToP11P13P14WithoutPushAliases(self):
        canonical_routes = {
            "testChatOpenP13DeletedMentionAdvancesVideoRoute": {
                "matrix_route_code": "P13",
                "fixture_scenario": "mention-deleted-advance",
            },
            "testChatOpenP14LastChatsSeededMentionVideoRoute": {
                "matrix_route_code": "P14",
                "fixture_scenario": "last-chats-seeded-mention-exact",
            },
        }

        self.assertEqual(len(evidence.CHAT_OPEN_VIDEO_ROUTE_MANIFEST), 25)
        for selector, binding in canonical_routes.items():
            self.assertEqual(
                evidence.CHAT_OPEN_VIDEO_ROUTE_MANIFEST.get(selector),
                binding,
            )
            canonical = {"test_selector": selector, **binding}
            self.assertEqual(evidence._closed_route_binding(canonical), canonical)
        self.assertNotIn(
            "testChatOpenP11MentionNotificationExactRemoteVideoRoute",
            evidence.CHAT_OPEN_VIDEO_ROUTE_MANIFEST,
        )

        canonical = {
            "test_selector": "testChatOpenP14LastChatsSeededMentionVideoRoute",
            "matrix_route_code": "P14",
            "fixture_scenario": "last-chats-seeded-mention-exact",
        }
        rejected_aliases = [
            dict(canonical, test_selector="testChatOpenV01LastChatsAnimatedPushVideoRoute"),
            dict(canonical, test_selector="testChatOpenP01NotificationExactLocalVideoRoute"),
            dict(canonical, test_selector="testChatOpenP02NotificationExactRemoteVideoRoute"),
            dict(canonical, test_selector="testChatOpenP11MentionNotificationExactRemoteVideoRoute"),
            dict(canonical, test_selector="testChatOpenP13DeletedMentionAdvancesVideoRoute"),
            dict(canonical, test_selector="testChatOpenArbitraryP14VideoRoute"),
            dict(canonical, matrix_route_code="V01"),
            dict(canonical, matrix_route_code="P01"),
            dict(canonical, matrix_route_code="P02"),
            dict(canonical, matrix_route_code="P11"),
            dict(canonical, matrix_route_code="P13"),
            dict(canonical, fixture_scenario="last-chats-animated-push"),
            dict(canonical, fixture_scenario="notification-exact-local"),
        ]
        for alias in rejected_aliases:
            with self.subTest(alias=alias):
                with self.assertRaises(evidence.EvidenceError):
                    evidence._closed_route_binding(alias)

    def test_test_command_rejects_multiple_unknown_and_legacy_selectors(self):
        signposts = self.app_artifact_directory / "signposts.json"
        marker_events = self.app_artifact_directory / "marker-events.json"
        command = self.valid_test_command(signposts, marker_events)
        selector_index = next(
            index
            for index, value in enumerate(command)
            if value.startswith("-only-testing:")
        )
        invalid_commands = [
            ("exactly one", command[: selector_index + 1]
            + [
                (
                    "-only-testing:xabberChatPerformanceUITests/"
                    "ChatPerformanceUITests/"
                    "testChatOpenE01ConfirmedEmptyVideoRoute"
                )
            ]
            + command[selector_index + 1 :]),
            ("closed video-route manifest", command[:selector_index]
            + [
                (
                    "-only-testing:xabberChatPerformanceUITests/"
                    "ChatPerformanceUITests/"
                    "testChatOpenUnknownVideoRoute"
                )
            ]
            + command[selector_index + 1 :]),
            ("closed video-route manifest", command[:selector_index]
            + [
                (
                    "-only-testing:xabberChatPerformanceUITests/"
                    "ChatPerformanceUITests/"
                    "testChatOpenSearchExactLocalStartsOnAnchorWithoutLatestFrame"
                )
            ]
            + command[selector_index + 1 :]),
        ]
        for expected_error, invalid in invalid_commands:
            with self.subTest(expected_error=expected_error):
                with self.assertRaisesRegex(
                    evidence.EvidenceError, expected_error
                ):
                    evidence.validate_test_command(
                        invalid,
                        expected_signpost_output=signposts,
                        expected_marker_event_output=marker_events,
                        expected_data_container=self.app_data_container,
                    )

    def test_exported_fixture_scenario_must_match_selected_video_route(self):
        signposts = self.app_artifact_directory / "signposts.json"
        marker_events = self.app_artifact_directory / "marker-events.json"
        accepted = evidence.validate_test_command(
            self.valid_test_command(signposts, marker_events),
            expected_signpost_output=signposts,
            expected_marker_event_output=marker_events,
            expected_data_container=self.app_data_container,
        )
        matching = self.numeric_signposts()
        matching.update(
            matrix_route_code="N01",
            fixture_scenario="preloaded-latest",
        )
        self.assertTrue(
            evidence.validate_exported_route_binding(
                matching,
                expected_test_preflight=accepted,
            )
        )
        mismatched = dict(matching, fixture_scenario="confirmed-empty")
        with self.assertRaisesRegex(evidence.EvidenceError, "route binding"):
            evidence.validate_exported_route_binding(
                mismatched,
                expected_test_preflight=accepted,
            )

    def test_test_command_rejects_outputs_outside_or_wrong_app_data_container(self):
        signposts = self.app_artifact_directory / "signposts.json"
        marker_events = self.app_artifact_directory / "marker-events.json"
        command = self.valid_test_command(signposts, marker_events)

        outside_directory = self.root / "outside"
        outside_directory.mkdir()
        outside_signposts = outside_directory / "signposts.json"
        outside_command = [
            f"XABBER_CHAT_SIGNPOST_EXPORT_PATH={outside_signposts}"
            if value.startswith("XABBER_CHAT_SIGNPOST_EXPORT_PATH=")
            else value
            for value in command
        ]
        with self.assertRaisesRegex(evidence.EvidenceError, "inside"):
            evidence.validate_test_command(
                outside_command,
                expected_signpost_output=outside_signposts,
                expected_marker_event_output=marker_events,
                expected_data_container=self.app_data_container,
            )

        other_container = self.root / "other-app-data-container"
        other_container.mkdir()
        with self.assertRaisesRegex(evidence.EvidenceError, "does not match"):
            evidence.validate_test_command(
                command,
                expected_signpost_output=signposts,
                expected_marker_event_output=marker_events,
                expected_data_container=other_container,
            )

    def test_capture_and_final_manifest_roles_are_exact_two_pass_sets(self):
        phase_hash = evidence.load_signpost_phase_manifest()["sha256"]
        capture_roles = {
            "raw",
            "test_log",
            "signposts",
            "marker_events",
            "capture_receipt",
        }
        final_roles = capture_roles | {
            "derivative",
            "sidecar",
            "framemd5",
            "classifications",
            "calibration",
        }
        paths = {}
        for role in final_roles:
            path = self.root / role
            path.write_bytes(f"safe-{role}".encode("ascii"))
            paths[role] = path
        capture = evidence.build_artifact_manifest(
            {role: paths[role] for role in capture_roles},
            collision_files=[],
            phase_manifest_sha256=phase_hash,
            route_binding=self.valid_route_binding(),
        )
        final = evidence.build_artifact_manifest(
            paths,
            collision_files=[],
            phase_manifest_sha256=phase_hash,
            route_binding=self.valid_route_binding(),
        )
        self.assertEqual(capture["stage"], "capture")
        self.assertEqual(set(capture["authorities"]), capture_roles)
        self.assertEqual(final["stage"], "final")
        self.assertEqual(set(final["authorities"]), final_roles)
        with self.assertRaisesRegex(evidence.EvidenceError, "roles"):
            evidence.build_artifact_manifest(
                {"raw": paths["raw"]},
                collision_files=[],
                phase_manifest_sha256=phase_hash,
                route_binding=self.valid_route_binding(),
            )

    def test_capture_finalization_copies_marker_events_not_derived_calibration(self):
        raw = self.root / "raw.mov"
        raw.write_bytes(b"safe-raw")
        signposts = self.root / "signposts-export.json"
        marker_events = self.root / "marker-events-export.json"
        signpost_payload = self.numeric_signposts()
        signpost_payload.update(
            matrix_route_code="N01",
            fixture_scenario="preloaded-latest",
        )
        signposts.write_text(json.dumps(signpost_payload), encoding="utf-8")
        marker_events.write_text(
            json.dumps(self.marker_events()), encoding="utf-8"
        )
        output = self.root / "capture"
        private_capture_value = b"synthetic-finalization-owner-private"
        private_capture_log = b"owner=" + private_capture_value + b"\n"
        with mock.patch.object(
            evidence,
            "_validate_privacy_safe_capture_log",
            wraps=evidence._validate_privacy_safe_capture_log,
        ) as privacy_validator:
            result = evidence.finalize_capture_evidence(
                output_directory=output,
                raw_path=raw,
                test_log=private_capture_log,
                total_test_log_bytes=len(private_capture_log),
                signpost_export_path=signposts,
                marker_event_export_path=marker_events,
                terminal="success",
                capture_preflight={"command_sha256": "e" * 64},
                test_preflight=self.valid_capture_test_preflight(),
            )
        self.assertEqual(result["terminal"], "success")
        self.assertTrue((output / "marker-events.json").is_file())
        self.assertFalse((output / "calibration.json").exists())
        self.assertNotIn(private_capture_value, (output / "test.log").read_bytes())
        self.assertNotIn(
            private_capture_value.decode("utf-8"),
            (output / "capture-receipt.json").read_text(encoding="utf-8"),
        )
        self.assertNotIn(
            private_capture_value.decode("utf-8"),
            json.dumps(result, sort_keys=True),
        )
        receipt = json.loads(
            (output / "capture-receipt.json").read_text(encoding="utf-8")
        )
        self.assertTrue(receipt["test_without_building"])
        self.assertEqual(
            receipt["no_build_test_command_sha256"],
            receipt["test_command_sha256"],
        )
        self.assertEqual(receipt["prebuilt_build_receipt_sha256"], "a" * 64)
        self.assertEqual(receipt["prebuilt_build_command_sha256"], "b" * 64)
        self.assertEqual(
            receipt["prebuilt_build_products_manifest_sha256"], "c" * 64
        )
        self.assertTrue(receipt["prebuilt_binary_provenance_closed"])
        self.assertEqual(receipt["prebuilt_destination_architecture"], "arm64")
        self.assertEqual(
            receipt["prebuilt_xctestrun_selection_policy"],
            "locked_simulator_sdk_arm64",
        )
        self.assertEqual(receipt["prebuilt_xctestrun_count"], 1)
        self.assertEqual(receipt["prebuilt_referenced_product_count"], 4)
        self.assertEqual(receipt["prebuilt_runnable_executable_count"], 4)
        self.assertEqual(receipt["prebuilt_referenced_regular_file_count"], 12)
        self.assertEqual(
            receipt["prebuilt_referenced_regular_file_byte_count"], 1024
        )
        self.assertEqual(
            receipt["prebuilt_referenced_files_manifest_sha256"], "d" * 64
        )
        self.assertEqual(
            set(receipt["test_log"]),
            {
                "published_byte_count",
                "collected_raw_byte_count",
                "observed_raw_byte_count",
                "bounded_at_bytes",
                "raw_collection_truncated",
                "published_log_bounded",
                "truncated",
                "published_log_sha256",
                "privacy_redaction_applied",
            },
        )
        self.assertNotIn("full_stream_sha256", receipt["test_log"])
        self.assertEqual(
            receipt["test_log"]["published_log_sha256"],
            hashlib.sha256((output / "test.log").read_bytes()).hexdigest(),
        )
        self.assertNotEqual(
            receipt["test_log"]["published_log_sha256"],
            hashlib.sha256(private_capture_log).hexdigest(),
        )
        self.assertFalse(receipt["test_log"]["truncated"])
        self.assertFalse(receipt["test_log"]["raw_collection_truncated"])
        self.assertFalse(receipt["test_log"]["published_log_bounded"])
        self.assertEqual(
            receipt["test_log"]["collected_raw_byte_count"],
            len(private_capture_log),
        )
        self.assertEqual(
            receipt["test_log"]["observed_raw_byte_count"],
            len(private_capture_log),
        )
        self.assertEqual(
            receipt["test_log"]["published_byte_count"],
            (output / "test.log").stat().st_size,
        )
        privacy_validator.assert_called_once_with((output / "test.log").read_bytes())
        manifest = json.loads(
            (output / "artifact-manifest.json").read_text(encoding="utf-8")
        )
        self.assertEqual(manifest["stage"], "capture")

    def test_capture_receipt_separates_redaction_expansion_from_collection_loss(self):
        raw = self.root / "raw-expanded-log.mov"
        raw.write_bytes(b"safe-raw")
        signposts = self.root / "signposts-expanded-log.json"
        signpost_payload = self.numeric_signposts()
        signpost_payload.update(
            matrix_route_code="N01",
            fixture_scenario="preloaded-latest",
        )
        signposts.write_text(json.dumps(signpost_payload), encoding="utf-8")
        marker_events = self.root / "marker-events-expanded-log.json"
        marker_events.write_text(json.dumps(self.marker_events()), encoding="utf-8")
        private_log = (
            b"a" * (evidence.MAX_CAPTURE_LOG_BYTES - 12) + b"\nowner=x"
        )
        output = self.root / "capture-expanded-log"

        evidence.finalize_capture_evidence(
            output_directory=output,
            raw_path=raw,
            test_log=private_log,
            total_test_log_bytes=len(private_log),
            signpost_export_path=signposts,
            marker_event_export_path=marker_events,
            terminal="success",
            capture_preflight={"command_sha256": "e" * 64},
            test_preflight=self.valid_capture_test_preflight(),
        )

        receipt = json.loads(
            (output / "capture-receipt.json").read_text(encoding="utf-8")
        )["test_log"]
        published_log = (output / "test.log").read_bytes()
        self.assertFalse(receipt["raw_collection_truncated"])
        self.assertTrue(receipt["published_log_bounded"])
        self.assertTrue(receipt["truncated"])
        self.assertEqual(receipt["collected_raw_byte_count"], len(private_log))
        self.assertEqual(receipt["observed_raw_byte_count"], len(private_log))
        self.assertEqual(receipt["published_byte_count"], len(published_log))
        self.assertEqual(
            receipt["published_log_sha256"],
            hashlib.sha256(published_log).hexdigest(),
        )
        self.assertTrue(published_log.endswith(b"\n"))
        self.assertNotIn(b"owner=x", published_log)

    def test_capture_finalization_independently_rejects_identity_sanitizer_miss(self):
        raw = self.root / "raw-identity-miss.mov"
        raw.write_bytes(b"safe-raw")
        signposts = self.root / "signposts-identity-miss.json"
        signpost_payload = self.numeric_signposts()
        signpost_payload.update(
            matrix_route_code="N01",
            fixture_scenario="preloaded-latest",
        )
        signposts.write_text(json.dumps(signpost_payload), encoding="utf-8")
        marker_events = self.root / "marker-events-identity-miss.json"
        marker_events.write_text(
            json.dumps(self.marker_events()),
            encoding="utf-8",
        )
        output = self.root / "capture-identity-miss"
        private_value = b"synthetic-finalizer-identity-private"

        with mock.patch.object(
            evidence,
            "_privacy_safe_capture_log",
            side_effect=lambda value: value,
        ):
            with self.assertRaises(evidence.EvidenceError) as caught:
                evidence.finalize_capture_evidence(
                    output_directory=output,
                    raw_path=raw,
                    test_log=b"owner=" + private_value + b"\n",
                    total_test_log_bytes=len(private_value) + 7,
                    signpost_export_path=signposts,
                    marker_event_export_path=marker_events,
                    terminal="success",
                    capture_preflight={"command_sha256": "e" * 64},
                    test_preflight=self.valid_capture_test_preflight(),
                )

        self.assertIn("private data", str(caught.exception))
        self.assertNotIn(private_value.decode("utf-8"), str(caught.exception))
        self.assertFalse(output.exists())
        self.assertEqual(list(self.root.glob("capture-identity-miss.partial-*")), [])

    def test_failed_capture_replaces_nonclosed_private_exports_with_placeholders(self):
        raw = self.root / "raw-failed-private-export.mov"
        raw.write_bytes(b"safe-raw")
        private_value = "synthetic-failed-export-private"
        signposts = self.root / "signposts-failed-private.json"
        marker_events = self.root / "marker-events-failed-private.json"
        signposts.write_text(json.dumps({"owner": private_value}), encoding="utf-8")
        marker_events.write_text(json.dumps({"owner": private_value}), encoding="utf-8")
        output = self.root / "capture-failed-private-export"

        evidence.finalize_capture_evidence(
            output_directory=output,
            raw_path=raw,
            test_log=b"safe failed XCTest output\n",
            total_test_log_bytes=27,
            signpost_export_path=signposts,
            marker_event_export_path=marker_events,
            terminal="failure",
            capture_preflight={"command_sha256": "e" * 64},
            test_preflight=self.valid_capture_test_preflight(),
        )

        for artifact in output.iterdir():
            if artifact.is_file():
                self.assertNotIn(
                    private_value.encode("utf-8"),
                    artifact.read_bytes(),
                )
        preserved_signposts = json.loads(
            (output / "signposts.json").read_text(encoding="utf-8")
        )
        preserved_markers = json.loads(
            (output / "marker-events.json").read_text(encoding="utf-8")
        )
        self.assertFalse(preserved_signposts["available"])
        self.assertFalse(preserved_markers["available"])
        self.assertEqual(preserved_signposts["capture_terminal"], "failure")
        self.assertEqual(preserved_markers["capture_terminal"], "failure")

    def test_successful_capture_rejects_nonclosed_private_signpost_record(self):
        raw = self.root / "raw-success-private-export.mov"
        raw.write_bytes(b"safe-raw")
        private_value = "synthetic-success-export-private"
        signposts = self.root / "signposts-success-private.json"
        signpost_payload = self.numeric_signposts()
        signpost_payload.update(
            records=[{"owner": private_value}],
            matrix_route_code="N01",
            fixture_scenario="preloaded-latest",
        )
        signposts.write_text(json.dumps(signpost_payload), encoding="utf-8")
        marker_events = self.root / "marker-events-success-private.json"
        marker_events.write_text(
            json.dumps(self.marker_events()),
            encoding="utf-8",
        )
        output = self.root / "capture-success-private-export"

        with self.assertRaises(evidence.EvidenceError) as caught:
            evidence.finalize_capture_evidence(
                output_directory=output,
                raw_path=raw,
                test_log=b"safe successful XCTest output\n",
                total_test_log_bytes=30,
                signpost_export_path=signposts,
                marker_event_export_path=marker_events,
                terminal="success",
                capture_preflight={"command_sha256": "e" * 64},
                test_preflight=self.valid_capture_test_preflight(),
            )

        self.assertIn("numeric signpost", str(caught.exception))
        self.assertNotIn(private_value, str(caught.exception))
        self.assertFalse(output.exists())

    def test_capture_log_privacy_redacts_stable_identity_forms_and_keeps_closed_numbers(self):
        forbidden_keys = (
            "account",
            "accountJid",
            "messagePrimary",
            "queryId",
            "primary",
            "archiveId",
            "owner",
            "stableIdentifier",
            "password",
            "authorizationToken",
            "body",
        )
        private_lines = []
        forbidden_values = []
        for key_index, key in enumerate(forbidden_keys):
            forms = (
                f"{key}=synthetic-{key_index}-assignment-private",
                f"{key}: synthetic-{key_index}-colon-private",
                json.dumps({key: f"synthetic-{key_index}-json-private"}),
                json.dumps(
                    {
                        "outer": {
                            key: f"synthetic-{key_index}-nested-private"
                        }
                    }
                ),
                json.dumps(
                    {
                        "outer": {
                            key: [f"synthetic-{key_index}-array-private"]
                        }
                    }
                ),
                json.dumps(
                    {
                        "outer": {
                            key: [f"synthetic-{key_index}-multiline-private"]
                        }
                    },
                    indent=2,
                ),
            )
            private_lines.extend(forms)
            forbidden_values.extend(
                (
                    f"synthetic-{key_index}-assignment-private",
                    f"synthetic-{key_index}-colon-private",
                    f"synthetic-{key_index}-json-private",
                    f"synthetic-{key_index}-nested-private",
                    f"synthetic-{key_index}-array-private",
                    f"synthetic-{key_index}-multiline-private",
                )
            )
        private_lines.append(
            "body: synthetic-body-line-one-private\n"
            "synthetic-body-line-two-private\n"
            "phase_code=16"
        )
        forbidden_values.extend(
            (
                "synthetic-body-line-one-private",
                "synthetic-body-line-two-private",
            )
        )
        direct_private_lines = (
            "synthetic.person@privacy.invalid",
            "/Users/synthetic/private-chat-open-artifact",
            "https://privacy.invalid/private-chat-open-artifact",
        )
        private_lines.extend(direct_private_lines)
        forbidden_values.extend(direct_private_lines)
        private_log = "\n".join(private_lines).encode("utf-8")
        safe_numeric_log = b"\n".join(
            (
                b"phase_code=16",
                b"record_kind_code: 3",
                b"trace_id=10",
                b"generation:20",
                b"message_count=320",
                b"queryCount:2",
                b"archive_counter=4",
                b'{"counters":[{"code":16,"value":1}],"terminal_code":1}',
                b'{"outer":{"messageCount":320,"query_count":2,"archiveOrdinal":4}}',
            )
        )

        sanitized = evidence._privacy_safe_capture_log(
            private_log + b"\n" + safe_numeric_log
        )

        for private_line in private_lines:
            self.assertTrue(
                evidence._capture_log_contains_forbidden_private_data(
                    private_line.encode("utf-8")
                )
            )
        for private_value in forbidden_values:
            self.assertNotIn(private_value.encode("utf-8"), sanitized)
        self.assertIn(b"<redacted", sanitized)
        self.assertFalse(
            evidence._capture_log_contains_forbidden_private_data(safe_numeric_log)
        )
        escaped_embedded_json = (
            b'diagnostic={"message\\u0050rimary":"synthetic-escaped-private"}'
        )
        self.assertTrue(
            evidence._capture_log_contains_forbidden_private_data(
                escaped_embedded_json
            )
        )
        with self.assertRaisesRegex(evidence.EvidenceError, "private data"):
            evidence._validate_privacy_safe_capture_log(escaped_embedded_json)
        escaped_json_string = (
            b'diagnostic="{\\"owner\\":\\"synthetic-escaped-string-private\\"}"'
        )
        self.assertTrue(
            evidence._capture_log_contains_forbidden_private_data(
                escaped_json_string
            )
        )
        with self.assertRaisesRegex(evidence.EvidenceError, "private data") as caught:
            evidence._validate_privacy_safe_capture_log(
                evidence._privacy_safe_capture_log(escaped_json_string)
            )
        self.assertNotIn("synthetic-escaped-string-private", str(caught.exception))
        adversarial_private_logs = (
            b'{"diagnostic":"{\\"owner\\":\\"synthetic-object-string-private\\"}"}',
            b'{"diagnostic":["{\\"owner\\":\\"synthetic-array-string-private\\"}"]}',
            b'{"diagnostic":"synthetic.person\\u0040privacy.invalid"}',
            b'{"diagnostic":"https:\\/\\/privacy.invalid\\/private"}',
            b'{"diagnostic":"\\/Users\\/synthetic\\/private"}',
            b"message id: synthetic-spaced-message-private",
            b"query id: synthetic-spaced-query-private",
            b"stable id: synthetic-spaced-stable-private",
            b"account id: synthetic-spaced-account-private",
            b"synthetic@localhost",
            "пользователь@пример".encode("utf-8"),
            b"file:///opt/synthetic/private-artifact",
            b"/opt/synthetic/private-artifact",
            b'authorization_code="123456"',
            b"password_code='1234'",
            b'message_count="320"',
            b"api_key=synthetic-api-key-private",
            b"x-api-key: synthetic-x-api-key-private",
            b"auth: Bearer synthetic-auth-private",
            b"owner[id]=synthetic-bracket-owner-private",
            b"owner [ id ]=synthetic-spaced-bracket-owner-private",
            b"owner[]=synthetic-empty-bracket-owner-private",
            b"owner/id=synthetic-slash-owner-private",
            b'{"message\\u0050rimary":"synthetic-truncated-private',
            b'diagnostic="{\\"owner\\":\\"synthetic-truncated-private',
            b'diagnostic="synthetic.person\\u0040localhost',
            b'diagnostic="https:\\/\\/privacy.invalid\\/truncated',
        )
        for raw_private_log in adversarial_private_logs:
            with self.subTest(raw_private_log=raw_private_log):
                self.assertTrue(
                    evidence._capture_log_contains_forbidden_private_data(
                        raw_private_log
                    )
                )
                candidate = evidence._privacy_safe_capture_log(raw_private_log)
                if evidence._capture_log_contains_forbidden_private_data(candidate):
                    with self.assertRaisesRegex(
                        evidence.EvidenceError,
                        "private data",
                    ) as candidate_error:
                        evidence._validate_privacy_safe_capture_log(candidate)
                    self.assertNotIn(
                        "synthetic-object-string-private",
                        str(candidate_error.exception),
                    )
                else:
                    evidence._validate_privacy_safe_capture_log(candidate)
        for safe_line in safe_numeric_log.splitlines():
            self.assertIn(safe_line, sanitized)

    def test_published_log_bound_never_splits_redaction_token(self):
        private_value = b"synthetic-boundary-private"
        raw_log = (
            b"a" * (evidence.MAX_CAPTURE_LOG_BYTES - 12)
            + b"\nowner="
            + private_value
        )
        sanitized = evidence._privacy_safe_capture_log(raw_log)
        self.assertGreater(len(sanitized), evidence.MAX_CAPTURE_LOG_BYTES)

        bounded, was_bounded = evidence._bounded_privacy_safe_capture_log(sanitized)

        self.assertTrue(was_bounded)
        self.assertLessEqual(len(bounded), evidence.MAX_CAPTURE_LOG_BYTES)
        self.assertNotIn(private_value, bounded)
        self.assertNotIn(b"<redact", bounded)
        evidence._validate_privacy_safe_capture_log(bounded)

        fully_collected = b"owner=x"
        expanded = evidence._privacy_safe_capture_log(fully_collected)
        self.assertGreater(len(expanded), len(fully_collected))

    def test_capture_log_privacy_scan_is_bounded_for_megabyte_lines(self):
        no_delimiter = b"x" * evidence.MAX_CAPTURE_LOG_BYTES
        private_long_value = (
            b"owner=" + b"x" * (evidence.MAX_CAPTURE_LOG_BYTES - 6)
        )

        started = time.monotonic()
        sanitized_plain = evidence._privacy_safe_capture_log(no_delimiter)
        self.assertFalse(
            evidence._capture_log_contains_forbidden_private_data(sanitized_plain)
        )
        plain_elapsed = time.monotonic() - started

        started = time.monotonic()
        sanitized_private = evidence._privacy_safe_capture_log(private_long_value)
        evidence._validate_privacy_safe_capture_log(sanitized_private)
        private_elapsed = time.monotonic() - started

        self.assertLess(plain_elapsed, 3.0)
        self.assertLess(private_elapsed, 3.0)

    def test_package_validation_rejects_raw_private_fields_independently_of_sanitizer(self):
        private_value = b"synthetic-owner-validation-private"
        raw_log = b'{"outer":{"owner":"' + private_value + b'"}}\n'
        json_paths = {}
        for name in (
            "sidecar",
            "classifications",
            "signposts",
            "marker-events",
            "calibration",
            "capture-receipt",
        ):
            path = self.root / f"{name}.json"
            path.write_text("{}", encoding="utf-8")
            json_paths[name] = path
        test_log = self.root / "test.log"
        test_log.write_bytes(raw_log)

        with mock.patch.object(
            evidence,
            "_privacy_safe_capture_log",
            side_effect=lambda value: value,
        ):
            with self.assertRaises(evidence.EvidenceError) as caught:
                evidence.validate_evidence_package(
                    raw_path=self.root / "raw.mov",
                    raw_probe_data={},
                    derivative_path=self.root / "derivative.mov",
                    derivative_probe_data={},
                    sidecar_path=json_paths["sidecar"],
                    framemd5_path=self.root / "frames.framemd5",
                    collision_directory=self.root / "collisions",
                    classifications_path=json_paths["classifications"],
                    signposts_path=json_paths["signposts"],
                    marker_events_path=json_paths["marker-events"],
                    calibration_path=json_paths["calibration"],
                    test_log_path=test_log,
                    capture_receipt_path=json_paths["capture-receipt"],
                )

        self.assertIn("private data", str(caught.exception))
        self.assertNotIn(private_value.decode("utf-8"), str(caught.exception))

    def test_successful_capture_without_export_fails_and_preserves_diagnostics(self):
        raw = self.root / "capture.mov"
        signposts = self.app_artifact_directory / "chat-open-N01-signposts.json"
        marker_events = self.app_artifact_directory / "chat-open-N01-markers.json"
        artifacts = self.root / "capture-artifacts"
        lock = self.root / "capture.lock"
        capture_command = [
            "/usr/bin/swift",
            str(evidence.BUNDLED_WINDOW_RECORDER_SOURCE),
            "--window-id",
            "12345",
            "--output",
            str(raw),
        ]
        test_command = self.valid_test_command(signposts, marker_events)
        build_receipt, build_products = self.make_prebuilt_receipt(
            "missing-exports"
        )
        launches = []

        class FakeProcess:
            def __init__(self, command, is_capture):
                self.command = command
                self.is_capture = is_capture
                self.returncode = None if is_capture else 0
                self.stdout = None if is_capture else io.BytesIO(b"safe test\n")

            def poll(self):
                return self.returncode

            def send_signal(self, _signal):
                if self.is_capture:
                    Path(self.command[-1]).write_bytes(b"safe-finalized-raw")
                self.returncode = 0

            def wait(self, timeout=None):
                del timeout
                return self.returncode

            def terminate(self):
                self.returncode = 0

            def kill(self):
                self.returncode = 0

        def fake_popen(command, **_kwargs):
            launches.append(command)
            return FakeProcess(command, len(launches) == 1)

        with (
            mock.patch.object(evidence, "CAPTURE_LOCK_PATH", lock),
            mock.patch.object(
                evidence, "PREBUILD_LOCK_PATH", self.root / "missing-exports-prebuild.lock"
            ),
            mock.patch.object(evidence.time, "sleep", return_value=None),
        ):
            with self.assertRaisesRegex(evidence.EvidenceError, "required signpost and marker-event"):
                evidence.run_capture_session(
                    simulator_id=evidence.LOCKED_SIMULATOR_ID,
                    raw_output=raw,
                    capture_command=capture_command,
                    test_command=test_command,
                    timeout_seconds=1,
                    capture_evidence_directory=artifacts,
                    signpost_export_path=signposts,
                    marker_event_export_path=marker_events,
                    build_receipt_path=build_receipt,
                    build_products_root=build_products,
                    window_snapshot_provider=lambda _window_id: self.valid_window_snapshot(),
                    app_data_container_resolver=lambda _udid, _bundle: self.app_data_container,
                    recorder_ready_waiter=lambda process, _timeout: self.assertIsNone(
                        process.poll()
                    ),
                    process_spawner=fake_popen,
                )
        self.assertTrue(raw.is_file())
        self.assertTrue((artifacts / "marker-events.json").is_file())
        receipt = json.loads(
            (artifacts / "capture-receipt.json").read_text(encoding="utf-8")
        )
        self.assertEqual(receipt["terminal"], "failure")

    def test_capture_reresolves_reinstalled_app_container_and_stages_relative_exports(self):
        raw = self.root / "reinstalled-container.mov"
        old_container = self.root / "Application/8C08FB23-9DF8-4C39-86DD-3A25B43955C2"
        new_container = self.root / "Application/7AD4ED7B-1111-2222-3333-444444444444"
        relative_signposts = Path(
            "Library/Caches/chat-open-N01-signposts.json"
        )
        relative_markers = Path(
            "Library/Caches/chat-open-N01-markers.json"
        )
        for container in (old_container, new_container):
            (container / relative_signposts.parent).mkdir(parents=True)
        declared_signposts = old_container / relative_signposts
        declared_markers = old_container / relative_markers
        runtime_signposts = new_container / relative_signposts
        runtime_markers = new_container / relative_markers
        artifacts = self.root / "reinstalled-container-capture"
        lock = self.root / "reinstalled-container.lock"
        capture_command = [
            "/usr/bin/swift",
            str(evidence.BUNDLED_WINDOW_RECORDER_SOURCE),
            "--window-id",
            "12345",
            "--output",
            str(raw),
        ]
        test_command = self.valid_test_command(
            declared_signposts,
            declared_markers,
            data_container=old_container,
        )
        build_receipt, build_products = self.make_prebuilt_receipt(
            "reinstalled-container"
        )
        resolver_results = iter((old_container, new_container))
        resolver_calls = []
        launches = []

        def resolve_container(udid, bundle):
            resolver_calls.append((udid, bundle))
            return next(resolver_results)

        class FakeProcess:
            def __init__(self, command, is_capture):
                self.command = command
                self.is_capture = is_capture
                self.returncode = None if is_capture else 0
                self.stdout = None if is_capture else io.BytesIO(b"safe test\n")
                if not is_capture:
                    signpost_payload = self_test.numeric_signposts()
                    signpost_payload.update(
                        matrix_route_code="N01",
                        fixture_scenario="preloaded-latest",
                    )
                    runtime_signposts.write_text(
                        json.dumps(signpost_payload), encoding="utf-8"
                    )
                    runtime_markers.write_text(
                        json.dumps(self_test.marker_events()), encoding="utf-8"
                    )

            def poll(self):
                return self.returncode

            def send_signal(self, _signal):
                if self.is_capture:
                    Path(self.command[-1]).write_bytes(b"safe-finalized-raw")
                self.returncode = 0

            def wait(self, timeout=None):
                del timeout
                return self.returncode

            def terminate(self):
                self.returncode = 0

            def kill(self):
                self.returncode = 0

        self_test = self

        def fake_popen(command, **_kwargs):
            launches.append(command)
            return FakeProcess(command, len(launches) == 1)

        with (
            mock.patch.object(evidence, "CAPTURE_LOCK_PATH", lock),
            mock.patch.object(
                evidence, "PREBUILD_LOCK_PATH", self.root / "reinstalled-prebuild.lock"
            ),
            mock.patch.object(evidence.time, "sleep", return_value=None),
        ):
            result = evidence.run_capture_session(
                simulator_id=evidence.LOCKED_SIMULATOR_ID,
                raw_output=raw,
                capture_command=capture_command,
                test_command=test_command,
                timeout_seconds=1,
                capture_evidence_directory=artifacts,
                signpost_export_path=declared_signposts,
                marker_event_export_path=declared_markers,
                build_receipt_path=build_receipt,
                build_products_root=build_products,
                window_snapshot_provider=lambda _window_id: self.valid_window_snapshot(),
                app_data_container_resolver=resolve_container,
                recorder_ready_waiter=lambda process, _timeout: self.assertIsNone(
                    process.poll()
                ),
                process_spawner=fake_popen,
            )

        self.assertEqual(result["test_exit_status"], "success")
        self.assertEqual(len(resolver_calls), 2)
        self.assertTrue((artifacts / "signposts.json").is_file())
        self.assertTrue((artifacts / "marker-events.json").is_file())
        self.assertFalse(runtime_signposts.exists())
        self.assertFalse(runtime_markers.exists())

    def test_runtime_export_staging_rejects_and_preserves_pre_xctest_file(self):
        source = self.app_artifact_directory / "stale-signposts.json"
        destination = self.root / "staged-signposts.json"
        source.write_text("{}\n", encoding="utf-8")
        spawn_boundary = time.time_ns() + 1

        with self.assertRaisesRegex(evidence.EvidenceError, "bounded owned"):
            evidence._stage_owned_runtime_export(
                source,
                destination,
                not_created_before_epoch_nanoseconds=spawn_boundary,
            )

        self.assertTrue(source.is_file())
        self.assertFalse(destination.exists())

    def test_runtime_exports_use_exact_route_bound_names(self):
        expected = evidence._route_bound_runtime_export_paths("N01")
        self.assertEqual(
            expected,
            (
                Path("Library/Caches/chat-open-N01-signposts.json"),
                Path("Library/Caches/chat-open-N01-markers.json"),
            ),
        )
        with self.assertRaises(evidence.EvidenceError):
            evidence._route_bound_runtime_export_paths("N01-r5")

    def test_capture_rejects_fresh_but_unbound_route_export_names_before_spawn(self):
        raw = self.root / "unbound-route.mov"
        signposts = self.app_artifact_directory / "chat-open-N01-r5-signposts.json"
        markers = self.app_artifact_directory / "chat-open-N01-r5-markers.json"
        build_receipt, build_products = self.make_prebuilt_receipt("unbound-route")
        popen = mock.Mock(side_effect=AssertionError("process spawned"))
        with self.assertRaisesRegex(evidence.EvidenceError, "selected video route"):
            evidence.run_capture_session(
                simulator_id=evidence.LOCKED_SIMULATOR_ID,
                raw_output=raw,
                capture_command=[
                    "/usr/bin/swift",
                    str(evidence.BUNDLED_WINDOW_RECORDER_SOURCE),
                    "--window-id",
                    "12345",
                    "--output",
                    str(raw),
                ],
                test_command=self.valid_test_command(signposts, markers),
                timeout_seconds=1,
                capture_evidence_directory=self.root / "unbound-capture",
                signpost_export_path=signposts,
                marker_event_export_path=markers,
                build_receipt_path=build_receipt,
                build_products_root=build_products,
                window_snapshot_provider=lambda _window_id: self.valid_window_snapshot(),
                app_data_container_resolver=lambda _udid, _bundle: self.app_data_container,
                process_spawner=popen,
            )
        popen.assert_not_called()

    def test_test_command_allows_route_cache_pair_to_be_refreshed_by_app(self):
        signposts = self.app_artifact_directory / "chat-open-N01-signposts.json"
        markers = self.app_artifact_directory / "chat-open-N01-markers.json"
        signposts.write_text("stale\n", encoding="utf-8")
        markers.write_text("stale\n", encoding="utf-8")

        accepted = evidence.validate_test_command(
            self.valid_test_command(signposts, markers),
            expected_signpost_output=signposts,
            expected_marker_event_output=markers,
            expected_data_container=self.app_data_container,
        )

        self.assertEqual(accepted["matrix_route_code"], "N01")

    def test_video_route_ui_launch_environment_is_internal_and_manifest_bound(self):
        source_path = (
            Path(__file__).resolve().parents[2]
            / "xabberChatPerformanceUITests/ChatPerformanceUITests.swift"
        )
        source = source_path.read_text(encoding="utf-8")
        launch_start = source.index(
            "    private func launch(\n        openScenario: String,"
        )
        launch_end = source.index("\n    @discardableResult", launch_start)
        launch_source = source[launch_start:launch_end]
        self.assertNotIn("ProcessInfo.processInfo.environment", launch_source)
        self.assertIn("matrixRouteCode: String", launch_source)
        self.assertIn("routeBoundValues(\n                    matrixRouteCode:", launch_source)

        for selector, binding in evidence.CHAT_OPEN_VIDEO_ROUTE_MANIFEST.items():
            method_start = source.index(f"    func {selector}()")
            next_method = source.find("\n    func ", method_start + 1)
            private_boundary = source.find("\n    private ", method_start + 1)
            candidates = [
                boundary
                for boundary in (next_method, private_boundary)
                if boundary != -1
            ]
            method_end = min(candidates) if candidates else len(source)
            method_source = source[method_start:method_end]
            self.assertIn(
                f'matrixRouteCode: "{binding["matrix_route_code"]}"',
                method_source,
                selector,
            )

    def test_app_surfaces_closed_video_tail_and_export_failure_codes(self):
        source_root = Path(__file__).resolve().parents[2]
        exporter = (
            source_root
            / "xabber/controllers/chats/chat/ChatPerformanceArtifactExporter.swift"
        ).read_text(encoding="utf-8")
        integration_gate = (
            source_root
            / "xabber/controllers/chats/chat/ChatPerformanceIntegrationGate.swift"
        ).read_text(encoding="utf-8")
        fixture = (
            source_root
            / "xabber/controllers/chats/chat/ChatPerformanceFixtureViewController.swift"
        ).read_text(encoding="utf-8")
        normalized_fixture = " ".join(fixture.split())

        self.assertIn(
            "enum ChatPerformanceArtifactExportFailureCode: String, CaseIterable",
            exporter,
        )
        for code in (
            "incomplete-marker-sequence",
            "incomplete-trace-contract",
            "invalid-record-order",
            "artifact-write-failed",
        ):
            self.assertIn(f'= "{code}"', exporter)
        self.assertIn("var diagnosticFailureCode:", exporter)
        self.assertIn(
            "enum ChatPerformanceArtifactTraceContractFailureCode: String, CaseIterable",
            exporter,
        )
        for code in (
            "none",
            "required-record-missing",
            "required-record-duplicate",
            "required-record-order",
            "forbidden-phase",
            "interval-count-mismatch",
            "interval-terminal-invalid",
        ):
            self.assertIn(f'= "{code}"', exporter)
        self.assertIn("diagnosticTraceContractFailureCode", exporter)

        self.assertIn(
            "enum ChatOpenVideoEvidenceTerminalFailureCode: String, CaseIterable",
            integration_gate,
        )
        for code in (
            "none",
            "stable-frame-rejected",
            "marker-rejected",
            "terminal-evidence-invalidated",
            "artifact-finalization-failed",
        ):
            self.assertIn(f'= "{code}"', integration_gate)
        self.assertIn(
            '"videoEvidenceFailure=\\(videoEvidenceFailureCode.rawValue)"',
            integration_gate,
        )
        self.assertIn(
            '"artifactExportFailure=\\(artifactExportFailureCode.rawValue)"',
            integration_gate,
        )
        self.assertIn(
            '"artifactTraceFailure=\\(artifactTraceFailure.code.rawValue)"',
            integration_gate,
        )

        self.assertIn(
            "openScenarioVideoEvidenceFailureCode = .stableFrameRejected",
            normalized_fixture,
        )
        self.assertIn(
            "openScenarioVideoEvidenceFailureCode = .markerRejected",
            normalized_fixture,
        )
        self.assertIn(
            "openScenarioVideoEvidenceFailureCode = .terminalEvidenceInvalidated",
            normalized_fixture,
        )
        self.assertIn(
            "openScenarioVideoEvidenceFailureCode = .artifactFinalizationFailed",
            normalized_fixture,
        )
        self.assertIn("error.diagnosticFailureCode", normalized_fixture)
        self.assertIn(
            "exportSession.diagnosticTraceContractFailureDetails",
            normalized_fixture,
        )

    def test_fixture_seals_primary_stable_frame_before_video_markers(self):
        source_root = Path(__file__).resolve().parents[2]
        fixture = (
            source_root
            / "xabber/controllers/chats/chat/ChatPerformanceFixtureViewController.swift"
        ).read_text(encoding="utf-8")
        gate = (
            source_root
            / "xabber/controllers/chats/chat/ChatPerformanceIntegrationGate.swift"
        ).read_text(encoding="utf-8")
        controller = (
            source_root
            / "xabber/controllers/chats/chat/ChatViewController.swift"
        ).read_text(encoding="utf-8")

        begin_start = fixture.index(
            "    private func beginOpenScenarioStableVideoTail("
        )
        begin_end = fixture.index(
            "\n    private func advanceOpenScenarioVideoMarker(", begin_start
        )
        begin_tail = fixture[begin_start:begin_end]
        seal_index = begin_tail.index(
            "sealOpenScenarioStableFrameForArtifactExport("
        )
        pending_index = begin_tail.index("openScenarioPendingStablePlan = plan")
        self.assertLess(seal_index, pending_index)

        awaiting_start = gate.index("        case .awaitingM1:")
        awaiting_end = gate.index("        case .showingM1:", awaiting_start)
        awaiting = gate[awaiting_start:awaiting_end]
        self.assertIn("guard hasStableTerminalEvidence", awaiting)
        self.assertIn("terminalEvidenceIsFrozen", awaiting)

        self.assertIn(
            "internal func sealChatOpenPerformanceStableFrameForArtifactExport(",
            controller,
        )
        normalized_controller = " ".join(controller.split())
        self.assertIn("hasEmittedStableFrame( context:", normalized_controller)

    def test_stable_frame_seal_retries_receipt_race_with_closed_subreason(self):
        source_root = Path(__file__).resolve().parents[2]
        fixture = (
            source_root
            / "xabber/controllers/chats/chat/ChatPerformanceFixtureViewController.swift"
        ).read_text(encoding="utf-8")
        gate = (
            source_root
            / "xabber/controllers/chats/chat/ChatPerformanceIntegrationGate.swift"
        ).read_text(encoding="utf-8")
        lifecycle = (
            source_root
            / "xabber/controllers/chats/chat/ChatPerformanceSignposts.swift"
        ).read_text(encoding="utf-8")
        controller = (
            source_root
            / "xabber/controllers/chats/chat/ChatViewController.swift"
        ).read_text(encoding="utf-8")
        normalized_fixture = " ".join(fixture.split())
        normalized_gate = " ".join(gate.split())
        normalized_lifecycle = " ".join(lifecycle.split())
        normalized_controller = " ".join(controller.split())

        self.assertIn(
            "enum ChatOpenPerformanceStableFrameSealFailureCode: String, CaseIterable",
            gate,
        )
        for code in (
            "none",
            "bound-primary-context-unavailable",
            "current-primary-context-unavailable",
            "primary-context-mismatch",
            "lifecycle-context-mismatch",
            "semantic-target-unavailable",
            "presentation-receipt-pending",
            "stable-frame-not-scheduled",
            "stable-frame-consume-rejected",
        ):
            self.assertIn(f'= "{code}"', normalized_gate)
        self.assertIn(
            '"stableFrameFailure=\\(failureCode.rawValue)"',
            gate,
        )
        for field in (
            "stableFrameAttempted",
            "stableFrameBoundPrimary",
            "stableFrameCurrentPrimary",
            "stableFramePrimaryMatch",
            "stableFrameLifecycleCurrent",
            "stableFrameSemanticTarget",
            "stableFrameReceipt",
            "stableFrameScheduled",
            "stableFrameAlreadyEmitted",
            "stableFrameConsumed",
        ):
            self.assertIn(f'"{field}=\\(', gate)

        self.assertIn(
            "struct ChatOpenPerformanceStableFrameLifecycleSnapshot: Equatable",
            lifecycle,
        )
        for field in (
            "isCurrentContext",
            "hasRequiredPresentationReceipt",
            "hasPendingStableFrame",
            "hasEmittedStableFrame",
        ):
            self.assertIn(f"let {field}: Bool", lifecycle)
        self.assertIn(
            "func stableFrameLifecycleSnapshot(",
            lifecycle,
        )

        self.assertIn(
            "case .retry(let diagnostics):",
            fixture,
        )
        self.assertIn(
            "openScenarioStableFrameSealDiagnostics = diagnostics",
            normalized_fixture,
        )
        self.assertIn(
            "openScenarioVideoEvidenceFailureCode = .stableFrameRejected",
            normalized_fixture,
        )
        self.assertIn(
            "stableFramePresentationReceipt",
            normalized_gate,
        )
        self.assertIn(
            "stableFrameLifecycleSnapshot( context: context, requiredReceipt: requiredReceipt",
            normalized_controller,
        )

    def test_accessibility_summary_appends_diagnostic_segments_incrementally(self):
        source_root = Path(__file__).resolve().parents[2]
        gate = (
            source_root
            / "xabber/controllers/chats/chat/ChatPerformanceIntegrationGate.swift"
        ).read_text(encoding="utf-8")
        summary_start = gate.index("    var accessibilitySummary: String {")
        summary_end = gate.index(
            "\n}\n\nenum ChatOpenRealPipelineFixtureDiagnosticsPolicy",
            summary_start,
        )
        summary = gate[summary_start:summary_end]
        normalized_summary = " ".join(summary.split())

        self.assertIn("var accessibilityFields: [String] = [", summary)
        ordered_appends = (
            "accessibilityFields.append(contentsOf: "
            "stableFrameSealDiagnostics.accessibilityFields)",
            "accessibilityFields.append(contentsOf: p14Mention.accessibilityFields)",
            "accessibilityFields.append(contentsOf: storage.accessibilityFields)",
            "accessibilityFields.append(contentsOf: routeHost.accessibilityFields)",
            'return accessibilityFields.joined(separator: " ")',
        )
        positions = [
            normalized_summary.index(fragment) for fragment in ordered_appends
        ]
        self.assertEqual(positions, sorted(positions))
        self.assertNotIn("] + stableFrameSealDiagnostics.accessibilityFields", summary)

    def test_artifact_manifest_detects_tampering_of_every_final_authority(self):
        roles = {
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
        authorities = {}
        for role in roles:
            path = self.root / role
            path.write_bytes(f"safe-{role}".encode("ascii"))
            authorities[role] = path
        manifest = evidence.build_artifact_manifest(
            authorities,
            collision_files=[],
            phase_manifest_sha256="d" * 64,
            route_binding=self.valid_route_binding(),
        )
        for role, path in authorities.items():
            original = path.read_bytes()
            path.write_bytes(original + b"-tampered")
            with self.subTest(role=role):
                with self.assertRaisesRegex(evidence.EvidenceError, "artifact manifest"):
                    evidence.verify_artifact_manifest(
                        manifest,
                        authorities,
                        collision_files=[],
                        phase_manifest_sha256="d" * 64,
                        route_binding=self.valid_route_binding(),
                    )
            path.write_bytes(original)

    def test_cli_requires_explicit_marker_events_for_derivation_and_validation(self):
        parser = evidence._parser()
        subcommands = next(
            action for action in parser._actions if action.dest == "command"
        ).choices
        self.assertIn("derive-calibration", subcommands)
        derive_options = {
            option
            for action in subcommands["derive-calibration"]._actions
            for option in action.option_strings
        }
        validate_options = {
            option
            for action in subcommands["validate"]._actions
            for option in action.option_strings
        }
        capture_options = {
            option
            for action in subcommands["capture-run"]._actions
            for option in action.option_strings
        }
        self.assertIn("--marker-events", derive_options)
        self.assertIn("--calibration-out", derive_options)
        self.assertIn("--marker-events", validate_options)
        self.assertIn("--marker-event-export", capture_options)
        self.assertNotIn("--calibration-export", capture_options)


if __name__ == "__main__":
    unittest.main()
