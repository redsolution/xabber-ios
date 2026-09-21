import json
import sys
import tempfile
import unittest
from pathlib import Path


TOOLS_ROOT = Path(__file__).resolve().parents[1]
if str(TOOLS_ROOT) not in sys.path:
    sys.path.insert(0, str(TOOLS_ROOT))

import localization_ui_migration as migration


def translations(english: str) -> dict[str, str]:
    return {
        "en": english,
        "ru": f"ru:{english}",
        "fr": f"fr:{english}",
        "es": f"es:{english}",
        "ar": f"ar:{english}",
        "zh-Hans": f"zh:{english}",
    }


def mapping_entry(
    *,
    path: str = "xabber/Screen.swift",
    sink: str = "text",
    value: str,
    key: str,
    fallback: str | None = None,
) -> dict:
    result = {
        "path": path,
        "sink": sink,
        "value": value,
        "key": key,
        "comment": "Visible test copy.",
        "translations": translations(fallback or value),
    }
    if fallback is not None:
        result["fallback"] = fallback
    return result


class SwiftRewriteTests(unittest.TestCase):
    def test_rewrites_plain_literal_to_text_lookup(self):
        source = 'label.text = "Hello"\n'
        entries = [mapping_entry(value="Hello", key="screen__label__hello")]

        rewritten, matched = migration.rewrite_swift_source(
            source,
            "xabber/Screen.swift",
            entries,
        )

        self.assertEqual(
            rewritten,
            'label.text = L10n.text("screen__label__hello", fallback: "Hello")\n',
        )
        self.assertEqual(matched, {0})

    def test_rewrites_interpolation_to_typed_format_and_preserves_nested_expression(self):
        source = (
            'field.placeholder = "john.doe@\\(domain.isEmpty ? '
            '"example.com" : domain)"\n'
        )
        entries = [
            mapping_entry(
                sink="placeholder",
                value="john.doe@%@",
                key="contact__field__jid_placeholder",
            )
        ]

        rewritten, matched = migration.rewrite_swift_source(
            source,
            "xabber/Screen.swift",
            entries,
        )

        self.assertEqual(
            rewritten,
            'field.placeholder = L10n.format('
            '"contact__field__jid_placeholder", fallback: "john.doe@%@", '
            'arguments: [String(describing: domain.isEmpty ? "example.com" : domain)])\n',
        )
        self.assertEqual(matched, {0})

    def test_rewrite_uses_canonical_fallback_and_escapes_literal_percent(self):
        source = 'label.text = "Free up \\(percent)% of space"\n'
        entries = [
            mapping_entry(
                value="Free up %@% of space",
                key="storage__action__free_up_format",
                fallback="Free up %@%% of space",
            )
        ]

        rewritten, _ = migration.rewrite_swift_source(
            source,
            "xabber/Screen.swift",
            entries,
        )

        self.assertIn('fallback: "Free up %@%% of space"', rewritten)
        self.assertIn('arguments: [String(describing: percent)]', rewritten)

    def test_rewrite_matches_unique_path_and_value_when_sink_is_conservatively_mislabeled(self):
        source = 'let row = Row(title: "Settings")\n'
        entries = [
            mapping_entry(
                sink="title",
                value="Settings",
                key="settings__screen__title",
            )
        ]

        rewritten, matched = migration.rewrite_swift_source(
            source,
            "xabber/Screen.swift",
            entries,
        )

        self.assertIn('L10n.text("settings__screen__title"', rewritten)
        self.assertEqual(matched, {0})

    def test_rewrite_rejects_ambiguous_path_value_fallback(self):
        source = 'let row = Row(title: "Open")\n'
        entries = [
            mapping_entry(value="Open", key="one__action__open"),
            mapping_entry(sink="message", value="Open", key="two__state__open"),
        ]

        with self.assertRaisesRegex(migration.MigrationError, "ambiguous"):
            migration.rewrite_swift_source(
                source,
                "xabber/Screen.swift",
                entries,
            )


class MappingValidationTests(unittest.TestCase):
    def test_requires_all_six_nonempty_locales(self):
        entry = mapping_entry(value="Hello", key="screen__label__hello")
        entry["translations"]["ar"] = " "

        with self.assertRaisesRegex(migration.MigrationError, "six non-empty"):
            migration.validate_migrations([entry])

    def test_rejects_one_key_with_conflicting_canonical_values(self):
        entries = [
            mapping_entry(value="Title", key="screen__title__main"),
            mapping_entry(
                value="TITLE",
                key="screen__title__main",
                fallback="Different title",
            ),
        ]

        with self.assertRaisesRegex(migration.MigrationError, "conflicting"):
            migration.validate_migrations(entries)


class CatalogMergeTests(unittest.TestCase):
    def test_adds_new_key_with_comment_and_six_translations(self):
        document = {"sourceLanguage": "en", "strings": {}, "version": "1.0"}
        entries = [mapping_entry(value="Hello", key="screen__label__hello")]

        merged = migration.merge_catalog(document, entries)

        entry = merged["strings"]["screen__label__hello"]
        self.assertEqual(entry["comment"], "Visible test copy.")
        self.assertEqual(set(entry["localizations"]), set(migration.LOCALES))
        self.assertEqual(
            entry["localizations"]["en"]["stringUnit"]["value"],
            "Hello",
        )

    def test_preserves_existing_nonempty_translation(self):
        document = {
            "sourceLanguage": "en",
            "strings": {
                "screen__label__hello": {
                    "extractionState": "manual",
                    "localizations": {
                        "ru": {
                            "stringUnit": {
                                "state": "translated",
                                "value": "Existing Russian",
                            }
                        }
                    },
                }
            },
            "version": "1.0",
        }
        entries = [mapping_entry(value="Hello", key="screen__label__hello")]

        merged = migration.merge_catalog(document, entries)

        self.assertEqual(
            merged["strings"]["screen__label__hello"]["localizations"]["ru"]
            ["stringUnit"]["value"],
            "Existing Russian",
        )

    def test_catalog_render_is_deterministic(self):
        document = {"sourceLanguage": "en", "strings": {}, "version": "1.0"}
        entries = [mapping_entry(value="Hello", key="screen__label__hello")]

        first = migration.render_catalog(migration.merge_catalog(document, entries))
        second = migration.render_catalog(migration.merge_catalog(document, entries))

        self.assertEqual(first, second)
        self.assertEqual(json.loads(first)["sourceLanguage"], "en")


class ApplyTests(unittest.TestCase):
    def test_apply_requires_every_migration_to_match_source(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source_path = root / "xabber" / "Screen.swift"
            source_path.parent.mkdir(parents=True)
            source_path.write_text('label.text = "Different"\n', encoding="utf-8")
            catalog_path = root / "Localizable.xcstrings"
            catalog_path.write_text(
                json.dumps(
                    {"sourceLanguage": "en", "strings": {}, "version": "1.0"}
                ),
                encoding="utf-8",
            )

            with self.assertRaisesRegex(migration.MigrationError, "matched no source"):
                migration.apply_migrations(
                    root,
                    catalog_path,
                    [mapping_entry(value="Hello", key="screen__label__hello")],
                    write=False,
                )

    def test_check_accepts_an_already_applied_migration(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source_path = root / "xabber" / "Screen.swift"
            source_path.parent.mkdir(parents=True)
            source_path.write_text(
                'label.text = L10n.text("screen__label__hello", fallback: "Hello")\n',
                encoding="utf-8",
            )
            catalog_path = root / "Localizable.xcstrings"
            entry = mapping_entry(value="Hello", key="screen__label__hello")
            catalog_path.write_text(
                migration.render_catalog(
                    migration.merge_catalog(
                        {"sourceLanguage": "en", "strings": {}, "version": "1.0"},
                        [entry],
                    )
                ),
                encoding="utf-8",
            )

            result = migration.check_applied_migrations(
                root,
                catalog_path,
                [entry],
            )

        self.assertEqual(result["migrations"], 1)

    def test_check_accepts_localizing_instance_lookup_with_labeled_key(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source_path = root / "xabber" / "Screen.swift"
            source_path.parent.mkdir(parents=True)
            source_path.write_text(
                'return localizer.text(key: "screen__label__hello", fallback: "Hello")\n',
                encoding="utf-8",
            )
            catalog_path = root / "Localizable.xcstrings"
            entry = mapping_entry(value="Hello", key="screen__label__hello")
            catalog_path.write_text(
                migration.render_catalog(
                    migration.merge_catalog(
                        {"sourceLanguage": "en", "strings": {}, "version": "1.0"},
                        [entry],
                    )
                ),
                encoding="utf-8",
            )

            result = migration.check_applied_migrations(
                root,
                catalog_path,
                [entry],
            )

            self.assertEqual(result["migrations"], 1)

    def test_check_rejects_a_mapping_key_missing_from_its_source_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source_path = root / "xabber" / "Screen.swift"
            source_path.parent.mkdir(parents=True)
            source_path.write_text('label.text = "Different"\n', encoding="utf-8")
            catalog_path = root / "Localizable.xcstrings"
            entry = mapping_entry(value="Hello", key="screen__label__hello")
            catalog_path.write_text(
                migration.render_catalog(
                    migration.merge_catalog(
                        {"sourceLanguage": "en", "strings": {}, "version": "1.0"},
                        [entry],
                    )
                ),
                encoding="utf-8",
            )

            with self.assertRaisesRegex(migration.MigrationError, "lookup is missing"):
                migration.check_applied_migrations(root, catalog_path, [entry])


class RepositoryMigrationTests(unittest.TestCase):
    def test_reviewed_migration_keys_have_all_six_catalog_localizations(self):
        repository_root = TOOLS_ROOT.parent
        mapping_paths = sorted(
            (TOOLS_ROOT / "localization_migrations").glob("*.json")
        )
        entries, _ = migration.load_mapping_files(mapping_paths)
        catalog = json.loads(
            (repository_root / "xabber/translations/Localizable.xcstrings")
            .read_text(encoding="utf-8")
        )["strings"]

        for key in sorted({entry["key"] for entry in entries}):
            self.assertIn(key, catalog)
            localizations = catalog[key].get("localizations", {})
            self.assertEqual(set(localizations), set(migration.LOCALES), key)
            for locale in migration.LOCALES:
                self.assertTrue(
                    migration._existing_value(localizations.get(locale)),
                    f"{locale}/{key}",
                )


if __name__ == "__main__":
    unittest.main()
