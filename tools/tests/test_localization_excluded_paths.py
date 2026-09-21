import json
import sys
import unittest
from pathlib import Path


TOOLS_ROOT = Path(__file__).resolve().parents[1]
REPOSITORY_ROOT = TOOLS_ROOT.parent
if str(TOOLS_ROOT) not in sys.path:
    sys.path.insert(0, str(TOOLS_ROOT))

import localization_manifest as manifest
import localization_ui_migration as migration


MAPPING_PATH = TOOLS_ROOT / "localization_migrations" / "excluded_paths_ui.json"
CATALOG_PATH = REPOSITORY_ROOT / "xabber" / "translations" / "Localizable.xcstrings"


class ExcludedPathLocalizationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.entries, _ = migration.load_mapping_files([MAPPING_PATH])
        cls.paths = sorted({entry["path"] for entry in cls.entries})
        cls.config = json.loads(
            (TOOLS_ROOT / "localization_manifest_config.json").read_text(
                encoding="utf-8"
            )
        )

    def test_every_reviewed_lookup_and_six_locale_translation_remains_present(self):
        result = migration.check_applied_migrations(
            REPOSITORY_ROOT,
            CATALOG_PATH,
            self.entries,
        )

        self.assertEqual(result["files"], 8)
        self.assertEqual(result["catalogKeys"], 39)

    def test_reviewed_sources_have_no_unresolved_or_unclassified_visible_copy(self):
        allowed_technical_candidates = {
            (
                "xabber/xmpp/omemo/OmemoManagerTest.swift",
                "message",
                "Test crypto message",
            )
        }

        for relative_path in self.paths:
            with self.subTest(path=relative_path):
                source = (REPOSITORY_ROOT / relative_path).read_text(encoding="utf-8")
                result = manifest.scan_swift_source(
                    source,
                    relative_path,
                    self.config,
                )

                self.assertEqual(result["unresolved"], [])
                self.assertEqual(result["directLookups"], [])
                unexpected = [
                    candidate
                    for candidate in result["hardcodedCandidates"]
                    if (
                        candidate["path"],
                        candidate["sink"],
                        candidate["value"],
                    )
                    not in allowed_technical_candidates
                ]
                self.assertEqual(unexpected, [])


if __name__ == "__main__":
    unittest.main()
