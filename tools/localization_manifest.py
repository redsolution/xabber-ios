#!/usr/bin/env python3
"""Build and verify Xabber's deterministic active-localization manifest.

The scanner is intentionally dependency-free. It is not a complete Swift parser;
it is a small lexical scanner for the localization APIs used by this repository.
Unknown/dynamic expressions are reported instead of being guessed, and bounded
dynamic domains must be declared explicitly in the checked-in configuration.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import re
import subprocess
import sys
import textwrap
from collections import defaultdict
from pathlib import Path
from typing import Any, Iterable

from localization_catalog import (
    CatalogError,
    format_argument_count,
    load_catalog,
    localization_signature_map,
    parse_format_signature,
)


SCHEMA_VERSION = 1
REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONFIG_PATH = REPO_ROOT / "tools/localization_manifest_config.json"
DEFAULT_CATALOG_PATH = "xabber/translations/Localizable.xcstrings"
DEFAULT_MANIFEST_PATH = "docs/localization/active-keys.json"
LOCALIZATION_APIS = ("text", "format", "plural", "attributedMarkdown")
SYMBOL_PATTERN = re.compile(
    r"^\s*(?:(?:public|private|fileprivate|internal|open|final|static|class|override|"
    r"mutating|nonmutating|convenience|required)\s+)*"
    r"(?P<kind>func|class|struct|enum|extension|init|subscript)\s*"
    r"(?P<name>[A-Za-z_][A-Za-z0-9_.]*)?",
    re.MULTILINE,
)
LEGACY_PLURAL_PATTERN = re.compile(
    r"^plurals\..+\.item_(?:\d+)(?:_counted)?$"
)
HTML_PATTERN = re.compile(
    r"</?(?:b|i|u|strong|em)(?:\s[^>]*)?>", re.IGNORECASE
)
VISIBLE_INTERFACE_ATTRIBUTES = {
    "accessibilityHint",
    "accessibilityLabel",
    "accessibilityValue",
    "placeholder",
    "text",
    "title",
}
INFO_PLIST_VISIBLE_KEYS = {
    "CFBundleDisplayName",
    "CFBundleName",
    "NSUserTrackingUsageDescription",
    "NSSiriUsageDescription",
}


class ManifestError(RuntimeError):
    pass


def _string_start(source: str, index: int) -> tuple[int, bool] | None:
    """Return (hash count, multiline) when a Swift string starts at index."""

    cursor = index
    while cursor < len(source) and source[cursor] == "#":
        cursor += 1
    hashes = cursor - index
    if cursor >= len(source) or source[cursor] != '"':
        return None
    multiline = source.startswith('"""', cursor)
    return hashes, multiline


def _string_end(source: str, start: int) -> int:
    descriptor = _string_start(source, start)
    if descriptor is None:
        raise ManifestError(f"Expected Swift string at offset {start}")
    hashes, multiline = descriptor
    quote_start = start + hashes
    opening = '"""' if multiline else '"'
    closing = opening + ("#" * hashes)
    cursor = quote_start + len(opening)
    interpolation_escape = "\\" + ("#" * hashes)
    while cursor < len(source):
        if source.startswith(interpolation_escape + "(", cursor):
            cursor = _interpolation_end(
                source, cursor + len(interpolation_escape)
            )
            continue
        if source.startswith(closing, cursor):
            return cursor + len(closing)
        if source.startswith(interpolation_escape, cursor):
            # An escaped quote cannot terminate a non-raw string. In a raw string
            # only a backslash followed by the exact hash count is an escape.
            escaped_index = cursor + len(interpolation_escape)
            if escaped_index < len(source) and source[escaped_index] == '"':
                cursor = escaped_index + 1
                continue
        cursor += 1
    raise ManifestError(f"Unterminated Swift string at offset {start}")


def _interpolation_end(source: str, opening_index: int) -> int:
    depth = 1
    cursor = opening_index + 1
    while cursor < len(source):
        descriptor = _string_start(source, cursor)
        if descriptor is not None:
            cursor = _string_end(source, cursor)
            continue
        if source.startswith("//", cursor):
            end = source.find("\n", cursor)
            cursor = len(source) if end < 0 else end
            continue
        if source.startswith("/*", cursor):
            comment_depth = 1
            cursor += 2
            while cursor < len(source) and comment_depth:
                if source.startswith("/*", cursor):
                    comment_depth += 1
                    cursor += 2
                elif source.startswith("*/", cursor):
                    comment_depth -= 1
                    cursor += 2
                else:
                    cursor += 1
            continue
        if source[cursor] == "(":
            depth += 1
        elif source[cursor] == ")":
            depth -= 1
            if depth == 0:
                return cursor + 1
        cursor += 1
    raise ManifestError(f"Unterminated Swift interpolation at offset {opening_index}")


def mask_swift_comments(source: str) -> str:
    """Mask Swift comments with spaces while preserving strings and offsets."""

    output = list(source)
    cursor = 0
    while cursor < len(source):
        descriptor = _string_start(source, cursor)
        if descriptor is not None:
            cursor = _string_end(source, cursor)
            continue
        if source.startswith("//", cursor):
            end = source.find("\n", cursor)
            end = len(source) if end < 0 else end
            for index in range(cursor, end):
                output[index] = " "
            cursor = end
            continue
        if source.startswith("/*", cursor):
            depth = 1
            end = cursor + 2
            while end < len(source) and depth:
                if source.startswith("/*", end):
                    depth += 1
                    end += 2
                elif source.startswith("*/", end):
                    depth -= 1
                    end += 2
                else:
                    end += 1
            if depth:
                raise ManifestError(f"Unterminated Swift block comment at offset {cursor}")
            for index in range(cursor, end):
                if output[index] != "\n":
                    output[index] = " "
            cursor = end
            continue
        cursor += 1
    return "".join(output)


def _mask_strings(source_without_comments: str) -> str:
    output = list(source_without_comments)
    cursor = 0
    while cursor < len(source_without_comments):
        descriptor = _string_start(source_without_comments, cursor)
        if descriptor is None:
            cursor += 1
            continue
        hashes, multiline = descriptor
        end = _string_end(source_without_comments, cursor)
        opening_length = hashes + (3 if multiline else 1)
        closing_length = (3 if multiline else 1) + hashes
        content_start = cursor + opening_length
        content_end = end - closing_length
        interpolation_prefix = "\\" + ("#" * hashes) + "("

        for index in range(cursor, content_start):
            if output[index] != "\n":
                output[index] = " "
        content_cursor = content_start
        while content_cursor < content_end:
            if source_without_comments.startswith(
                interpolation_prefix, content_cursor
            ):
                expression_start = content_cursor + len(interpolation_prefix)
                interpolation_end = _interpolation_end(
                    source_without_comments,
                    expression_start - 1,
                )
                expression_end = interpolation_end - 1
                for index in range(content_cursor, expression_start):
                    if output[index] != "\n":
                        output[index] = " "
                expression = source_without_comments[expression_start:expression_end]
                masked_expression = _mask_strings(mask_swift_comments(expression))
                output[expression_start:expression_end] = masked_expression
                if output[expression_end] != "\n":
                    output[expression_end] = " "
                content_cursor = interpolation_end
                continue
            if output[content_cursor] != "\n":
                output[content_cursor] = " "
            content_cursor += 1
        for index in range(content_end, end):
            if output[index] != "\n":
                output[index] = " "
        cursor = end
    return "".join(output)


def _swift_string_tokens(source_without_comments: str) -> list[dict[str, Any]]:
    tokens: list[dict[str, Any]] = []
    cursor = 0
    while cursor < len(source_without_comments):
        descriptor = _string_start(source_without_comments, cursor)
        if descriptor is None:
            cursor += 1
            continue
        end = _string_end(source_without_comments, cursor)
        literal = source_without_comments[cursor:end]
        tokens.append(
            {
                "start": cursor,
                "end": end,
                "literal": literal,
                "value": decode_swift_string_literal(literal),
            }
        )
        cursor = end
    return tokens


def decode_swift_string_literal(literal: str) -> str:
    descriptor = _string_start(literal, 0)
    if descriptor is None or _string_end(literal, 0) != len(literal):
        raise ManifestError(f"Not a standalone Swift string literal: {literal!r}")
    hashes, multiline = descriptor
    opening_length = hashes + (3 if multiline else 1)
    closing_length = (3 if multiline else 1) + hashes
    value = literal[opening_length:-closing_length]
    if multiline:
        if value.startswith("\n"):
            value = value[1:]
        value = re.sub(r"\n[ \t]*$", "", value)
        value = textwrap.dedent(value)

    escape = "\\" + ("#" * hashes)
    output: list[str] = []
    cursor = 0
    while cursor < len(value):
        if value.startswith(escape + "(", cursor):
            end = _interpolation_end(value, cursor + len(escape))
            output.append("%@")
            cursor = end
            continue
        if hashes == 0 and value.startswith("\\", cursor) and cursor + 1 < len(value):
            escaped = value[cursor + 1]
            replacements = {
                "0": "\0",
                "n": "\n",
                "r": "\r",
                "t": "\t",
                '"': '"',
                "'": "'",
                "\\": "\\",
            }
            if escaped in replacements:
                output.append(replacements[escaped])
                cursor += 2
                continue
        output.append(value[cursor])
        cursor += 1
    return "".join(output)


def parse_swift_string_expression(expression: str) -> str | None:
    expression = expression.strip()
    if not expression:
        return None
    try:
        end = _string_end(expression, 0)
    except ManifestError:
        return None
    if end != len(expression):
        return None
    return decode_swift_string_literal(expression)


def _matching_delimiter(source: str, opening_index: int) -> int:
    pairs = {"(": ")", "[": "]", "{": "}"}
    opening = source[opening_index]
    if opening not in pairs:
        raise ManifestError(f"Expected delimiter at offset {opening_index}")
    stack = [pairs[opening]]
    cursor = opening_index + 1
    while cursor < len(source):
        descriptor = _string_start(source, cursor)
        if descriptor is not None:
            cursor = _string_end(source, cursor)
            continue
        character = source[cursor]
        if character in pairs:
            stack.append(pairs[character])
        elif stack and character == stack[-1]:
            stack.pop()
            if not stack:
                return cursor
        cursor += 1
    raise ManifestError(f"Unterminated delimiter at offset {opening_index}")


def _split_top_level(source: str, separator: str = ",") -> list[str]:
    parts: list[str] = []
    start = 0
    cursor = 0
    stack: list[str] = []
    pairs = {"(": ")", "[": "]", "{": "}"}
    while cursor < len(source):
        descriptor = _string_start(source, cursor)
        if descriptor is not None:
            cursor = _string_end(source, cursor)
            continue
        character = source[cursor]
        if character in pairs:
            stack.append(pairs[character])
        elif character == "<" and _looks_like_generic_open(source, cursor):
            stack.append(">")
        elif stack and character == stack[-1]:
            stack.pop()
        elif not stack and character == separator:
            parts.append(source[start:cursor].strip())
            start = cursor + 1
        cursor += 1
    tail = source[start:].strip()
    if tail or parts:
        parts.append(tail)
    return parts


def _looks_like_generic_open(source: str, index: int) -> bool:
    if index <= 0 or source[index - 1].isspace():
        return False
    if not (source[index - 1].isalnum() or source[index - 1] in "_.)]>"):
        return False
    cursor = index + 1
    while cursor < len(source) and source[cursor].isspace():
        cursor += 1
    if cursor >= len(source) or not (
        source[cursor].isalpha() or source[cursor] in "_[("
    ):
        return False
    return ">" in source[cursor:]


def _split_argument(argument: str) -> tuple[str | None, str]:
    cursor = 0
    stack: list[str] = []
    pairs = {"(": ")", "[": "]", "{": "}"}
    while cursor < len(argument):
        descriptor = _string_start(argument, cursor)
        if descriptor is not None:
            cursor = _string_end(argument, cursor)
            continue
        character = argument[cursor]
        if character in pairs:
            stack.append(pairs[character])
        elif character == "<" and _looks_like_generic_open(argument, cursor):
            stack.append(">")
        elif stack and character == stack[-1]:
            stack.pop()
        elif character == ":" and not stack:
            candidate = argument[:cursor].strip()
            if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", candidate):
                return candidate, argument[cursor + 1 :].strip()
        cursor += 1
    return None, argument.strip()


def _parse_arguments(source: str) -> list[tuple[str | None, str]]:
    return [_split_argument(part) for part in _split_top_level(source) if part]


def _argument(arguments: list[tuple[str | None, str]], label: str) -> str | None:
    for current_label, value in arguments:
        if current_label == label:
            return value
    return None


def _unlabeled_argument(
    arguments: list[tuple[str | None, str]], index: int = 0
) -> str | None:
    values = [value for label, value in arguments if label is None]
    return values[index] if index < len(values) else None


def _array_argument_count(expression: str | None) -> int | None:
    if expression is None:
        return 0
    expression = expression.strip()
    if len(expression) < 2 or expression[0] != "[" or expression[-1] != "]":
        return None
    body = expression[1:-1].strip()
    if not body:
        return 0
    return len([part for part in _split_top_level(body) if part])


def _line_number(source: str, offset: int) -> int:
    return source.count("\n", 0, offset) + 1


def _nearest_symbol(source: str, offset: int) -> str | None:
    match: re.Match[str] | None = None
    for candidate in SYMBOL_PATTERN.finditer(source, 0, offset):
        match = candidate
    if match is None:
        return None
    name = match.group("name") or match.group("kind")
    return name


def _surfaces(path: str, config: dict[str, Any]) -> list[str]:
    result = ["push"] if path.startswith("xabber-push-extension/") else ["app"]
    for override in config.get("surfaceOverrides", []):
        if fnmatch.fnmatch(path, override.get("path", "")):
            result = list(override.get("surfaces", result))
    return sorted(set(result))


def _bounded_domain(
    path: str,
    api: str,
    key_expression: str,
    config: dict[str, Any],
) -> tuple[dict[str, Any], list[str]] | None:
    matches: dict[str, tuple[dict[str, Any], list[str]]] = {}
    domains = [
        ("bounded", domain)
        for domain in config.get("boundedDynamicDomains", [])
    ]
    domains.extend(
        ("typed", domain)
        for domain in config.get("typedDomains", [])
        if isinstance(domain.get("callsite"), dict)
    )
    for kind, domain in domains:
        declared_patterns = domain.get("patterns")
        if declared_patterns is None:
            callsite = domain.get("callsite")
            declared_patterns = [callsite if isinstance(callsite, dict) else domain]
        domain_name = domain.get("name", "unnamed")
        for pattern_index, declared_pattern in enumerate(declared_patterns):
            path_patterns = (
                declared_pattern.get("paths")
                or ([declared_pattern["path"]] if declared_pattern.get("path") else None)
                or domain.get("paths")
                or ([domain["path"]] if domain.get("path") else None)
                or ([domain["source"]] if domain.get("source") else [])
            )
            if not any(fnmatch.fnmatch(path, pattern) for pattern in path_patterns):
                continue
            expected_api = declared_pattern.get("api", domain.get("api"))
            if expected_api and expected_api != api:
                continue
            expected_expression = declared_pattern.get(
                "keyExpression", domain.get("keyExpression")
            )
            if expected_expression and expected_expression != key_expression.strip():
                continue
            match = matches.setdefault(domain_name, (domain, []))
            match[1].append(f"{kind}:{domain_name}:pattern:{pattern_index}")
    if len(matches) > 1:
        names = sorted(matches)
        raise ManifestError(
            f"Dynamic localization call in {path} matches multiple domains: {names}"
        )
    if not matches:
        return None
    domain, markers = next(iter(matches.values()))
    return domain, sorted(set(markers))


def _callsite(
    *,
    source: str,
    path: str,
    offset: int,
    api: str,
    key: str,
    fallback: str | None,
    argument_count: int | None,
    origin: str,
    config: dict[str, Any],
    domain: str | None = None,
    type_safety: str | None = None,
) -> dict[str, Any]:
    try:
        signature = parse_format_signature(fallback or "")
    except CatalogError as error:
        raise ManifestError(f"{path}:{_line_number(source, offset)}: {error}") from error
    callsite: dict[str, Any] = {
        "api": api,
        "argumentCount": argument_count,
        "fallback": fallback,
        "formatSignature": signature,
        "key": key,
        "line": _line_number(source, offset),
        "origin": origin,
        "path": path,
        "surfaces": _surfaces(path, config),
        "symbol": _nearest_symbol(source, offset),
        "typeSafety": type_safety or (
            "typeUnchecked" if api == "legacy" else "typed"
        ),
    }
    if api == "plural":
        callsite["pluralCountArgument"] = True
    if domain:
        callsite["domain"] = domain
    return callsite


HARDCODED_UI_PROPERTY_SINKS = (
    "accessibilityHint",
    "accessibilityLabel",
    "accessibilityValue",
    "backButtonTitle",
    "body",
    "localizedCancelTitle",
    "placeholder",
    "prompt",
    "secondaryText",
    "subtitle",
    "text",
    "title",
)
HARDCODED_UI_ARGUMENT_SINKS = (
    "accessibilityHint",
    "accessibilityLabel",
    "accessibilityValue",
    "actionTitle",
    "body",
    "buttonTitle",
    "cancel",
    "cancelTitle",
    "confirmTitle",
    "description",
    "destructiveActionTitle",
    "discoverabilityTitle",
    "displayName",
    "error",
    "errorMessage",
    "fileName",
    "filename",
    "footer",
    "footerLabel",
    "header",
    "localizedReason",
    "message",
    "noText",
    "placeholder",
    "primaryActionTitle",
    "prompt",
    "secondaryActionTitle",
    "senderName",
    "subtitle",
    "text",
    "title",
    "yesText",
    "warningMessage",
)
HARDCODED_UI_PRODUCER_SINKS = {
    "aboutText",
    "alertMessage",
    "contactStatus",
    "controlAccessibilityLabel",
    "currentPlayingSubtitle",
    "descriptionText",
    "detailText",
    "displayName",
    "durationText",
    "errorMessage",
    "footer",
    "genericAuthenticationFailureMessage",
    "incorrectPasswordMessage",
    "inviteErrorMessage",
    "message",
    "nfcScanAlertMessage",
    "offlineStatus",
    "prompt",
    "quota",
    "reason",
    "secondaryText",
    "statusText",
    "stepsText",
    "subtitle",
    "title",
    "titleText",
    "userMessage",
}
HARDCODED_UI_PRESENTATION_CALLS = (
    "buildInlineMessageCard",
    "buildSectionHeader",
    "presentChatAttachmentError",
    "presentError",
    "showBotSelectionError",
    "showError",
    "showMessageState",
    "state",
)
HARDCODED_UI_SEMANTIC_PRODUCER_SUFFIXES = (
    "Description",
    "Hint",
    "Label",
    "Message",
    "Nickname",
    "Placeholder",
    "Prompt",
    "Subtitle",
    "Text",
    "Title",
)
HARDCODED_UI_RETURN_PRODUCER_EXCLUSIONS = {
    # These are development fallbacks that are passed through their dedicated
    # localization facades before presentation, not hard-coded UI output.
    "defaultValue",
    "developmentFallback",
    "fallbackTemplate",
}
HARDCODED_UI_FORMAT_TOKEN_PATTERN = re.compile(
    r"%(?:[1-9]\d*\$)?#@[A-Za-z_][A-Za-z0-9_]*@"
    r"|%(?:[1-9]\d*\$)?[-+ #0']*"
    r"(?:(?:\d+)|(?:\*(?:[1-9]\d*\$)?))?"
    r"(?:\.(?:(?:\d+)|(?:\*(?:[1-9]\d*\$)?)))?"
    r"(?:hh|h|ll|l|q|z|t|j|L)?[@diuoxXfFeEgGaAcCsSp]"
)
LOCALIZING_INSTANCE_APIS = (
    "text",
    "format",
    "plural",
    "attributedMarkdown",
)


def _localizing_receiver_names(code_without_strings: str) -> list[str]:
    """Return identifiers whose declaration explicitly conforms to Localizing.

    Instance localization lookups intentionally require a visible type
    annotation.  Matching every ``receiver.text(...)`` call would turn common
    presenter/model APIs into localization lookups and could hide their UI
    literals from the hard-coded-copy audit.
    """

    return sorted(
        {
            match.group("name")
            for match in re.finditer(
                r"\b(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*:\s*"
                r"(?:\(\s*)?(?:(?:any|some)\s+)?Localizing\b",
                code_without_strings,
            )
        }
    )


def _has_localizable_literal_text(value: str) -> bool:
    """Return whether a UI string contains words beyond dynamic values.

    Swift interpolation is normalized to ``%@`` by the tokenizer. A value made
    only from interpolations, numbers, whitespace, or punctuation is runtime
    data rather than untranslated copy, so it must not create a localization
    key. Any Unicode letter outside a printf/plural token keeps the candidate.
    """

    literal_text = HARDCODED_UI_FORMAT_TOKEN_PATTERN.sub("", value)
    return any(character.isalpha() for character in literal_text)


def _last_assignment_sink(prefix: str) -> str | None:
    property_pattern = "|".join(map(re.escape, HARDCODED_UI_PROPERTY_SINKS))
    property_matches = list(
        re.finditer(rf"\.(?P<sink>{property_pattern})\s*=", prefix)
    )
    # UIKit subclasses frequently assign inherited properties without an
    # explicit receiver (`accessibilityLabel = ...`).  Treat those exactly like
    # `view.accessibilityLabel = ...`; otherwise a whole class of VoiceOver copy
    # silently escapes the audit.
    exact_producer_pattern = "|".join(
        map(
            re.escape,
            sorted(
                HARDCODED_UI_PRODUCER_SINKS
                | set(HARDCODED_UI_PROPERTY_SINKS),
                key=lambda value: (-len(value), value),
            ),
        )
    )
    producer_matches = list(
        re.finditer(rf"\b(?P<sink>{exact_producer_pattern})\s*=", prefix)
    )
    matches = property_matches + producer_matches
    if not matches:
        return None
    match = max(matches, key=lambda item: item.start())
    tail = prefix[match.end() :]
    masked_tail = _mask_strings(tail)
    delimiter_stack: list[str] = []
    delimiter_pairs = {"(": ")", "[": "]", "{": "}"}
    for character in masked_tail:
        if character in delimiter_pairs:
            delimiter_stack.append(delimiter_pairs[character])
        elif character in delimiter_pairs.values():
            if delimiter_stack and character == delimiter_stack[-1]:
                delimiter_stack.pop()
            else:
                return None
        elif not delimiter_stack and character in (",", ";"):
            return None
    if re.search(
        r"\n\s*(?:(?:private|fileprivate|internal|public|open|final|lazy|"
        r"override|static|class|required|convenience)\s+)*"
        r"(?:let|var|func|class|struct|enum|extension|case|return|"
        r"if|guard|switch|for|while|do|catch|defer)\b",
        masked_tail,
    ):
        return None
    if re.search(
        r"\n\s*(?:[A-Za-z_][A-Za-z0-9_?.]*\.)?"
        r"[A-Za-z_][A-Za-z0-9_]*\s*=",
        masked_tail,
    ):
        return None
    if re.search(
        r"\n\s*[A-Za-z_][A-Za-z0-9_]*"
        r"(?:[?.]+[A-Za-z_][A-Za-z0-9_]*)+\s*\(",
        masked_tail,
    ):
        return None
    if re.search(r"\b(?:forName|withName)\s*:\s*$", masked_tail):
        return None
    return match.group("sink")


def _last_argument_sink(prefix: str) -> str | None:
    argument_pattern = "|".join(map(re.escape, HARDCODED_UI_ARGUMENT_SINKS))
    matches = list(
        re.finditer(rf"\b(?P<sink>{argument_pattern})\s*:", prefix)
    )
    if not matches:
        return None
    match = matches[-1]
    tail = prefix[match.end() :]
    masked_tail = _mask_strings(tail)
    delimiter_stack: list[str] = []
    delimiter_pairs = {"(": ")", "[": "]", "{": "}"}
    crosses_argument_boundary = False
    for character in masked_tail:
        if character in delimiter_pairs:
            delimiter_stack.append(delimiter_pairs[character])
        elif character in delimiter_pairs.values():
            if delimiter_stack and character == delimiter_stack[-1]:
                delimiter_stack.pop()
            else:
                crosses_argument_boundary = True
                break
        elif not delimiter_stack and character in (",", ";"):
            crosses_argument_boundary = True
            break
    if crosses_argument_boundary:
        return None
    if re.search(
        r"\n\s*(?:let|var|func|class|struct|enum|extension|case|return|"
        r"if|guard|switch|for|while|do|catch|defer)\b",
        masked_tail,
    ):
        return None
    return match.group("sink")


def _unmatched_opening_delimiters(
    code_without_strings: str,
    token_start: int,
    *,
    maximum_lookback: int = 4000,
) -> list[tuple[str, int]]:
    """Return lexical delimiters enclosing a token, nearest first."""

    start = max(0, token_start - maximum_lookback)
    expected_openings: list[str] = []
    opening_for_closing = {")": "(", "]": "[", "}": "{"}
    result: list[tuple[str, int]] = []
    for index in range(token_start - 1, start - 1, -1):
        character = code_without_strings[index]
        if character in opening_for_closing:
            expected_openings.append(opening_for_closing[character])
        elif character in "([{":
            if expected_openings and character == expected_openings[-1]:
                expected_openings.pop()
            elif not expected_openings:
                result.append((character, index))
    return result


def _top_level_argument_prefix(
    code_without_strings: str,
    opening: int,
    token_start: int,
) -> str:
    """Return the current call-argument prefix before a string token."""

    argument_start = opening + 1
    delimiter_stack: list[str] = []
    delimiter_pairs = {"(": ")", "[": "]", "{": "}"}
    for index in range(opening + 1, token_start):
        character = code_without_strings[index]
        if character in delimiter_pairs:
            delimiter_stack.append(delimiter_pairs[character])
        elif delimiter_stack and character == delimiter_stack[-1]:
            delimiter_stack.pop()
        elif character == "," and not delimiter_stack:
            argument_start = index + 1
    return code_without_strings[argument_start:token_start]


def _enclosing_call_sink(
    code_without_strings: str,
    token_start: int,
) -> str | None:
    """Recognize UI calls whose visible string is not a direct first token."""

    for delimiter, opening in _unmatched_opening_delimiters(
        code_without_strings,
        token_start,
    ):
        if delimiter != "(":
            continue
        call_prefix = code_without_strings[max(0, opening - 160) : opening]
        call_match = re.search(
            r"(?P<call>[A-Za-z_][A-Za-z0-9_]*)\s*$",
            call_prefix,
        )
        if call_match is None:
            continue
        call = call_match.group("call")
        argument_prefix = _top_level_argument_prefix(
            code_without_strings,
            opening,
            token_start,
        )
        argument_label_match = re.match(
            r"\s*(?P<label>[A-Za-z_][A-Za-z0-9_]*)\s*:",
            argument_prefix,
        )
        argument_label = (
            argument_label_match.group("label")
            if argument_label_match is not None
            else None
        )

        # Several UIKit table-cell types in this codebase use overloaded
        # `cell.configure(...)` methods whose external labels do not reveal
        # which arguments are rendered. Keep these signatures deliberately
        # bounded: treating every custom `configure` argument as UI copy would
        # classify identifiers, image names, and wire values throughout the
        # app as translatable text.
        if call == "configure" and re.search(
            r"\bcell\s*\.\s*configure\s*$", call_prefix
        ):
            closing = _matching_delimiter(code_without_strings, opening)
            call_arguments = code_without_strings[opening + 1 : closing]
            if (
                argument_label is None
                and re.search(r"\bvalue\s*:", call_arguments)
                and re.search(r"\bkey\s*:", call_arguments)
            ):
                return "placeholder"
            if (
                argument_label == "with"
                and re.search(r"\bcolor\s*:", call_arguments)
            ):
                return "cellText"
            if (
                argument_label == "for"
                and re.search(r"\bkey\s*:", call_arguments)
                and re.search(r"\bactive\s*:", call_arguments)
            ):
                return "title"

        if (
            call == "post"
            and argument_label == "argument"
            and re.search(r"\bUIAccessibility\s*\.\s*post\s*$", call_prefix)
        ):
            return "accessibilityAnnouncement"

        if call == "Datasource":
            if argument_label == "name":
                return "datasourceName"
            if argument_label == "value":
                return "datasourceValue"

        # The visible copy is the first, unlabeled argument for these APIs. It
        # may be wrapped in String(format:), a ternary, or another expression.
        if argument_label is None:
            first_argument_prefix = code_without_strings[opening + 1 : token_start]
            if _top_level_argument_prefix(
                code_without_strings,
                opening,
                token_start,
            ) == first_argument_prefix:
                if call == "setTitle":
                    return "setTitle"
                if call == "makeToast":
                    return "makeToast"
                if call in HARDCODED_UI_PRESENTATION_CALLS:
                    return "presentationCall"
    return None


HARDCODED_UI_TUPLE_FIELDS = {
    "accessibilityHint": "accessibilityHint",
    "accessibilityLabel": "accessibilityLabel",
    "accessibilityValue": "accessibilityValue",
    "body": "body",
    "buttonTitle": "buttonTitle",
    "desc": "description",
    "description": "description",
    "footer": "footer",
    "header": "header",
    "hint": "hint",
    "label": "label",
    "message": "message",
    "placeholder": "placeholder",
    "prompt": "prompt",
    "subtitle": "subtitle",
    "text": "text",
    "title": "title",
}
HARDCODED_UI_STRING_COLLECTIONS = {
    "labels": "labelCollection",
    "messages": "messageCollection",
    "placeholders": "placeholder",
    "prompts": "promptCollection",
    "sections": "sectionTitle",
    "subtitles": "subtitleCollection",
}


def _top_level_argument_index(
    code_without_strings: str,
    opening: int,
    token_start: int,
) -> int:
    index = 0
    delimiter_stack: list[str] = []
    delimiter_pairs = {"(": ")", "[": "]", "{": "}"}
    for character in code_without_strings[opening + 1 : token_start]:
        if character in delimiter_pairs:
            delimiter_stack.append(delimiter_pairs[character])
        elif delimiter_stack and character == delimiter_stack[-1]:
            delimiter_stack.pop()
        elif character == "," and not delimiter_stack:
            index += 1
    return index


def _enclosing_semantic_tuple_sink(
    code_without_strings: str,
    token_start: int,
) -> str | None:
    """Recognize visible fields in typed tuple-backed UI data arrays."""

    delimiters = _unmatched_opening_delimiters(code_without_strings, token_start)
    tuple_opening = next(
        (opening for delimiter, opening in delimiters if delimiter == "("),
        None,
    )
    if tuple_opening is None:
        return None
    array_opening = next(
        (
            opening
            for delimiter, opening in delimiters
            if delimiter == "[" and opening < tuple_opening
        ),
        None,
    )
    if array_opening is None:
        return None
    declaration_prefix = code_without_strings[
        max(0, array_opening - 2400) : array_opening
    ]
    declaration = re.search(
        r"\b(?:let|var)\s+[A-Za-z_][A-Za-z0-9_]*\s*:\s*"
        r"\[\s*\((?P<fields>[^()]*)\)\s*\]\s*=\s*$",
        declaration_prefix,
        re.DOTALL,
    )
    if declaration is None:
        return None
    fields = re.findall(
        r"(?:^|,)\s*([A-Za-z_][A-Za-z0-9_]*)\s*:",
        declaration.group("fields"),
    )
    field_index = _top_level_argument_index(
        code_without_strings,
        tuple_opening,
        token_start,
    )
    if field_index >= len(fields):
        return None
    return HARDCODED_UI_TUPLE_FIELDS.get(fields[field_index])


def _enclosing_semantic_string_collection_sink(
    code_without_strings: str,
    token_start: int,
) -> str | None:
    """Recognize direct literals in explicitly named UI string arrays."""

    delimiters = _unmatched_opening_delimiters(code_without_strings, token_start)
    if not delimiters or delimiters[0][0] != "[":
        return None
    array_opening = delimiters[0][1]
    declaration_prefix = code_without_strings[
        max(0, array_opening - 2400) : array_opening
    ]
    names_pattern = "|".join(
        map(
            re.escape,
            sorted(
                HARDCODED_UI_STRING_COLLECTIONS,
                key=lambda value: (-len(value), value),
            ),
        )
    )
    declaration = re.search(
        rf"\b(?:let|var)\s+(?P<name>{names_pattern})\b"
        r"(?:\s*:\s*\[\s*String\s*\??\s*\])?\s*=\s*$",
        declaration_prefix,
        re.DOTALL,
    )
    if declaration is None:
        return None
    return HARDCODED_UI_STRING_COLLECTIONS[declaration.group("name")]


def _enclosing_accessibility_builder_sink(
    code_without_strings: str,
    token_start: int,
) -> str | None:
    """Recognize literal components composed into VoiceOver output."""

    enclosing_functions: list[tuple[int, str]] = []
    for match in re.finditer(
        r"\bfunc\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)\b[^{};]*\{",
        code_without_strings,
    ):
        if match.start() >= token_start:
            break
        opening = match.end() - 1
        try:
            closing = _matching_delimiter(code_without_strings, opening)
        except ManifestError:
            continue
        if opening < token_start < closing:
            enclosing_functions.append((opening, match.group("name")))
    if not enclosing_functions:
        return None
    _, function_name = max(enclosing_functions)
    normalized_name = function_name.lower()
    if "accessibilitylabel" in normalized_name:
        sink = "accessibilityLabel"
    elif "accessibilityhint" in normalized_name:
        sink = "accessibilityHint"
    elif "accessibilityvalue" in normalized_name:
        sink = "accessibilityValue"
    else:
        return None

    delimiters = _unmatched_opening_delimiters(code_without_strings, token_start)
    for delimiter, opening in delimiters:
        if delimiter == "(":
            call_prefix = code_without_strings[max(0, opening - 80) : opening]
            if re.search(r"\.\s*append\s*$", call_prefix):
                return sink
        if delimiter == "[":
            declaration_prefix = code_without_strings[
                max(0, opening - 400) : opening
            ]
            if re.search(
                r"\b(?:let|var)\s+[A-Za-z_][A-Za-z0-9_]*\s*"
                r":\s*\[\s*String\s*\]\s*=\s*$",
                declaration_prefix,
                re.DOTALL,
            ):
                return sink
    return None


def _enclosing_return_sink(
    source: str,
    code_without_strings: str,
    token_start: int,
    prefix: str,
) -> str | None:
    if re.search(
        r"\breturn\b(?:(?![;{}]|\bcase\b|\bdefault\b).)*$",
        prefix,
        re.DOTALL,
    ) is None:
        return None
    declarations: list[tuple[int, int, str, str, str]] = []
    patterns = (
        (
            "func",
            re.compile(
                r"\bfunc\s+(?P<label>[A-Za-z_][A-Za-z0-9_]*)\b"
                r"(?P<header>[^{};]*?)\{",
                re.DOTALL,
            ),
        ),
        (
            "var",
            re.compile(
                r"\bvar\s+(?P<label>[A-Za-z_][A-Za-z0-9_]*)\b"
                r"(?P<header>[^\n{}=]*?)\{"
            ),
        ),
    )
    for kind, pattern in patterns:
        for match in pattern.finditer(code_without_strings, 0, token_start):
            opening = match.end() - 1
            try:
                closing = _matching_delimiter(code_without_strings, opening)
            except ManifestError:
                continue
            if opening < token_start < closing:
                declarations.append(
                    (
                        opening,
                        closing,
                        match.group("label"),
                        match.group("header"),
                        kind,
                    )
                )
    if not declarations:
        return None

    _, _, label, header, kind = max(declarations, key=lambda item: item[0])
    if label in {"tableView", "pickerView"}:
        delegate_match = re.search(
            r"\b(titleForHeaderInSection|titleForFooterInSection|titleForRow)\b",
            header,
        )
        if delegate_match is not None:
            delegate_label = delegate_match.group(1)
            return (
                "pickerRowTitle"
                if delegate_label == "titleForRow"
                else "tableSectionTitle"
            )

    localized_error_sinks = {
        "errorDescription": "localizedErrorDescription",
        "failureReason": "failureReason",
        "recoverySuggestion": "recoverySuggestion",
        "userMessage": "userMessage",
    }
    if label in localized_error_sinks:
        return localized_error_sinks[label]
    if (
        kind == "func"
        and label == "value"
        and re.search(r"\bfor\s+[A-Za-z_][A-Za-z0-9_]*\s*:\s*Row\b", header)
    ):
        return "rowValue"

    named_sinks = HARDCODED_UI_PRODUCER_SINKS | {
        "body",
        "description",
        "header",
        "placeholder",
    }
    if label in HARDCODED_UI_RETURN_PRODUCER_EXCLUSIONS:
        return None
    # `var description` is overwhelmingly a diagnostics/protocol surface
    # (`CustomStringConvertible` and NSObject debugging), not UI copy.  A
    # named producer such as `secondaryDescription` remains auditable, and the
    # legacy Settings row API uses `func description()` so it is preserved.
    if label == "description" and kind == "var":
        return None
    if label in named_sinks:
        return label
    if label.endswith(HARDCODED_UI_SEMANTIC_PRODUCER_SUFFIXES):
        return label
    return None


def _hardcoded_candidate_tokens(
    source: str, source_without_comments: str, path: str
) -> list[dict[str, Any]]:
    """Return UI candidates plus lexical offsets for rewrite tooling.

    The checked-in manifest intentionally strips ``start``, ``end`` and
    ``literal``. Keeping detection and rewriting on this one lexical contract
    prevents a bulk migration tool from growing a second set of sink regexes.
    """

    candidates: list[dict[str, Any]] = []
    code_without_strings = _mask_strings(source_without_comments)
    localization_ranges: list[tuple[int, int]] = []
    localization_patterns = [
        r"\.localizeString\s*\(",
        r"\bL10n\.(?:text|format|plural|attributedMarkdown)\s*\(",
        r"\bPushNotificationLocalization\.string\s*\(",
    ]
    instance_api_pattern = "|".join(map(re.escape, LOCALIZING_INSTANCE_APIS))
    localization_patterns.extend(
        rf"\b{re.escape(receiver)}\s*\.\s*(?:{instance_api_pattern})\s*\("
        for receiver in _localizing_receiver_names(code_without_strings)
    )
    for pattern in localization_patterns:
        for match in re.finditer(pattern, code_without_strings):
            opening = code_without_strings.find("(", match.start(), match.end())
            localization_ranges.append(
                (opening, _matching_delimiter(source_without_comments, opening))
            )
    for token in _swift_string_tokens(source_without_comments):
        if any(start < token["start"] < end for start, end in localization_ranges):
            continue
        prefix = code_without_strings[max(0, token["start"] - 2400) : token["start"]]
        suffix = source_without_comments[token["end"] : token["end"] + 4096]
        if re.match(r"\s*\.localizeString\s*\(", suffix):
            continue
        # Prefer the innermost rendering primitive over a surrounding generic
        # argument such as ``title: NSAttributedString(string: ...)``.  This
        # keeps the candidate classification stable and gives rewrite tooling
        # the precise literal-bearing construct.
        sink = None
        if re.search(
            r"\b(?:NSAttributedString|NSMutableAttributedString|AttributedString)\s*\(\s*"
            r"(?:string\s*:\s*)?$",
            prefix,
        ):
            sink = "attributedString"
        if sink is None:
            sink = _last_argument_sink(prefix)
        if sink is None:
            sink = _last_assignment_sink(prefix)
        if sink is None:
            sink = _enclosing_call_sink(code_without_strings, token["start"])
        if sink is None:
            sink = _enclosing_semantic_tuple_sink(
                code_without_strings,
                token["start"],
            )
        if sink is None:
            sink = _enclosing_semantic_string_collection_sink(
                code_without_strings,
                token["start"],
            )
        if sink is None:
            sink = _enclosing_accessibility_builder_sink(
                code_without_strings,
                token["start"],
            )
        if sink is None and re.search(
            r"\bUIAccessibilityCustomAction\s*\([^)]*\bname\s*:\s*$",
            prefix,
            re.DOTALL,
        ):
            sink = "uiAccessibilityCustomAction"
        if sink is None and re.search(
            r"\bUISegmentedControl\s*\([^)]*\bitems\s*:\s*\[[^\]]*$",
            prefix,
            re.DOTALL,
        ):
            sink = "uiSegmentedControlItem"
        if sink is None and re.search(
            r"\blet\s+items\s*=\s*\[[^\]]*$",
            prefix,
            re.DOTALL,
        ):
            sink = "uiActionItem"
        if sink is None and re.search(
            r"\bstatusMessage\s*\.\s*accept\s*\([^)]*$",
            prefix,
            re.DOTALL,
        ):
            sink = "statusMessage"
        if sink is None and re.search(
            r"\bchangeNewUserState\s*\([^)]*\.failure\s*\([^)]*$",
            prefix,
            re.DOTALL,
        ):
            sink = "userVisibleFailure"
        if sink is None:
            sink = _enclosing_return_sink(
                source_without_comments,
                code_without_strings,
                token["start"],
                prefix,
            )
        if sink is None:
            continue
        if re.search(r"\b(?:logger|log|NSLog|os_log)\w*\s*\([^)]*$", prefix, re.I):
            continue
        value = token["value"]
        if not value.strip() or not _has_localizable_literal_text(value):
            continue
        if sink == "datasourceValue" and not re.search(r"[\s.!?]", value):
            continue
        candidates.append(
            {
                "end": token["end"],
                "line": _line_number(source, token["start"]),
                "literal": token["literal"],
                "path": path,
                "sink": sink,
                "start": token["start"],
                "value": value,
            }
        )
    return sorted(
        candidates,
        key=lambda item: (item["sink"], item["value"], item["line"], item["start"]),
    )


def _hardcoded_candidates(
    source: str, source_without_comments: str, path: str
) -> list[dict[str, Any]]:
    return [
        {
            "line": candidate["line"],
            "path": candidate["path"],
            "sink": candidate["sink"],
            "value": candidate["value"],
        }
        for candidate in _hardcoded_candidate_tokens(
            source,
            source_without_comments,
            path,
        )
    ]


def _frozen_localization_declarations(source: str) -> list[dict[str, Any]]:
    """Find process-lifetime constants that capture the current language."""

    source_without_comments = mask_swift_comments(source)
    code_without_strings = _mask_strings(source_without_comments)
    result: list[dict[str, Any]] = []
    declaration = re.compile(
        r"\bstatic\s+let\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)"
        r"(?:\s*:[^=\n]+)?\s*="
    )
    for match in declaration.finditer(code_without_strings):
        line_start = code_without_strings.rfind("\n", 0, match.start()) + 1
        indentation = code_without_strings[line_start:match.start()]
        if indentation.strip():
            indentation = re.match(r"\s*", indentation).group(0)
        next_declaration = re.search(
            rf"\n{re.escape(indentation)}"
            r"(?:(?:private|fileprivate|internal|public|open|final|lazy|override|"
            r"required|convenience)\s+)*"
            r"(?:static\s+|class\s+)?"
            r"(?:let|var|func|class|struct|enum|extension|init|deinit|subscript)\b",
            code_without_strings[match.end() :],
        )
        relative_boundaries = (
            [next_declaration.start()] if next_declaration is not None else []
        )
        if indentation:
            enclosing_scope_end = re.search(
                rf"\n[ \t]{{0,{len(indentation) - 1}}}\}}",
                code_without_strings[match.end() :],
            )
            if enclosing_scope_end is not None:
                relative_boundaries.append(enclosing_scope_end.start())
        end = (
            match.end() + min(relative_boundaries)
            if relative_boundaries
            else len(code_without_strings)
        )
        if re.search(r"\bL10n\s*\.", source_without_comments[match.end() : end]):
            result.append(
                {
                    "line": _line_number(source, match.start()),
                    "name": match.group("name"),
                }
            )
    return result


def scan_swift_source(
    source: str, path: str, config: dict[str, Any]
) -> dict[str, Any]:
    source_without_comments = mask_swift_comments(source)
    code = _mask_strings(source_without_comments)
    string_tokens = _swift_string_tokens(source_without_comments)
    calls: list[dict[str, Any]] = []
    dynamic_matches: list[str] = []
    unresolved: list[dict[str, Any]] = []
    direct_lookups: list[dict[str, Any]] = []

    occurrences: list[tuple[int, str, re.Match[str]]] = []
    for match in re.finditer(r"\.localizeString\s*\(", code):
        occurrences.append((match.start(), "legacy", match))
    l10n_pattern = r"\bL10n\.(text|format|plural|attributedMarkdown)\s*\("
    for match in re.finditer(l10n_pattern, code):
        occurrences.append((match.start(), match.group(1), match))
    instance_api_pattern = "|".join(map(re.escape, LOCALIZING_INSTANCE_APIS))
    for receiver in _localizing_receiver_names(code):
        pattern = rf"\b{re.escape(receiver)}\s*\.\s*({instance_api_pattern})\s*\("
        for match in re.finditer(pattern, code):
            occurrences.append((match.start(), match.group(1), match))
    for match in re.finditer(r"\bPushNotificationLocalization\.string\s*\(", code):
        occurrences.append((match.start(), "pushFacade", match))

    for offset, api, match in sorted(occurrences):
        opening = code.find("(", match.start(), match.end())
        closing = _matching_delimiter(source_without_comments, opening)
        arguments = _parse_arguments(source_without_comments[opening + 1 : closing])
        if api == "legacy":
            key_expression = _argument(arguments, "id") or ""
            arguments_expression = _argument(arguments, "arguments")
            receiver_end = match.start()
            while receiver_end > 0 and source_without_comments[receiver_end - 1].isspace():
                receiver_end -= 1
            fallback = None
            for token in reversed(string_tokens):
                if token["end"] == receiver_end:
                    fallback = token["value"]
                    break
            argument_count = _array_argument_count(arguments_expression)
        elif api == "pushFacade":
            key_expression = _unlabeled_argument(arguments) or ""
            fallback = parse_swift_string_expression(_argument(arguments, "fallback") or "")
            variadic_arguments = [
                value
                for index, (label, value) in enumerate(arguments)
                if label is None and index > 0
            ]
            argument_count = len(variadic_arguments)
            api = "format" if argument_count else "text"
        else:
            key_expression = _unlabeled_argument(arguments) or _argument(arguments, "key") or ""
            fallback = parse_swift_string_expression(_argument(arguments, "fallback") or "")
            argument_count = _array_argument_count(_argument(arguments, "arguments"))

        key = parse_swift_string_expression(key_expression)
        if key is not None:
            calls.append(
                _callsite(
                    source=source,
                    path=path,
                    offset=offset,
                    api=api,
                    key=key,
                    fallback=fallback,
                    argument_count=argument_count,
                    origin="sourceLiteral",
                    config=config,
                )
            )
            continue

        domain_match = _bounded_domain(path, api, key_expression, config)
        if domain_match is None:
            unresolved.append(
                {
                    "api": api,
                    "expression": key_expression.strip(),
                    "line": _line_number(source, offset),
                    "path": path,
                    "symbol": _nearest_symbol(source, offset),
                }
            )
            continue
        domain, matched_markers = domain_match
        dynamic_matches.extend(matched_markers)
        if isinstance(domain.get("enum"), str):
            # This is the implementation lookup inside a typed facade. Runtime
            # activity is derived from the facade's observed literal calls and
            # explicitly bounded dynamic cases below, not from every enum case.
            continue
        for item in sorted(domain.get("keys", []), key=lambda entry: entry["key"]):
            if item.get("api") and item["api"] != api:
                continue
            domain_api = item.get("api", domain.get("resolvedAPI", api))
            calls.append(
                _callsite(
                    source=source,
                    path=path,
                    offset=offset,
                    api=domain_api,
                    key=item["key"],
                    fallback=item.get("fallback"),
                    argument_count=item.get("argumentCount"),
                    origin="generatedPattern",
                    config=config,
                    domain=domain.get("name"),
                )
            )

    allowed_direct_paths = config.get("allowedDirectLookupPaths", [])
    direct_patterns = (
        ("NSLocalizedString", r"\bNSLocalizedString\s*\("),
        ("Bundle.localizedString", r"\.localizedString\s*\(\s*forKey\s*:"),
        ("String(localized:)", r"\bString\s*(?:\.init\s*)?\(\s*localized\s*:"),
        (
            "LocalizedStringResource",
            r"\bLocalizedStringResource\s*(?:\.init\s*)?\(",
        ),
    )
    if not any(fnmatch.fnmatch(path, pattern) for pattern in allowed_direct_paths):
        for api, pattern in direct_patterns:
            for match in re.finditer(pattern, code):
                direct_lookups.append(
                    {
                        "api": api,
                        "line": _line_number(source, match.start()),
                        "path": path,
                        "symbol": _nearest_symbol(source, match.start()),
                    }
                )

    allowed_legacy_format_paths = config.get("allowedLegacyFormatPaths", [])
    if not any(
        fnmatch.fnmatch(path, pattern) for pattern in allowed_legacy_format_paths
    ):
        for match in re.finditer(r"\bL10n\.legacyFormat\s*\(", code):
            direct_lookups.append(
                {
                    "api": "L10n.legacyFormat",
                    "line": _line_number(source, match.start()),
                    "path": path,
                    "symbol": _nearest_symbol(source, match.start()),
                }
            )

    calls.sort(key=lambda item: (item["key"], item["path"], item["line"], item["api"]))
    unresolved.sort(key=lambda item: (item["path"], item["line"], item["api"]))
    direct_lookups.sort(key=lambda item: (item["path"], item["line"], item["api"]))
    return {
        "calls": calls,
        "directLookups": direct_lookups,
        "dynamicMatches": sorted(set(dynamic_matches)),
        "hardcodedCandidates": _hardcoded_candidates(
            source, source_without_comments, path
        ),
        "unresolved": unresolved,
    }


def _enum_block(source: str, enum_name: str) -> tuple[int, int]:
    match = re.search(rf"\benum\s+{re.escape(enum_name)}\b[^{{]*{{", source)
    if match is None:
        raise ManifestError(f"Could not find typed localization enum {enum_name!r}")
    opening = source.find("{", match.start(), match.end())
    return opening + 1, _matching_delimiter(mask_swift_comments(source), opening)


def _typed_domain_definition(
    root: Path, domain: dict[str, Any]
) -> tuple[str, str, dict[str, tuple[str, int]], dict[str, str]]:
    relative_path = domain["source"]
    source = (root / relative_path).read_text(encoding="utf-8")
    start, end = _enum_block(source, domain["enum"])
    source_without_comments = mask_swift_comments(source)
    body = source_without_comments[start:end]
    body_code = _mask_strings(body)
    cases: dict[str, tuple[str, int]] = {}
    brace_depth = 0
    cursor = 0
    while cursor < len(body_code):
        character = body_code[cursor]
        if character == "{":
            brace_depth += 1
            cursor += 1
            continue
        if character == "}":
            brace_depth -= 1
            cursor += 1
            continue
        case_match = None
        if brace_depth == 0:
            case_match = re.match(
                r"\bcase\s+([A-Za-z_][A-Za-z0-9_]*)\b",
                body_code[cursor:],
            )
        if case_match is None:
            cursor += 1
            continue

        case_name = case_match.group(1)
        declaration_start = start + cursor
        value_cursor = declaration_start + case_match.end()
        while value_cursor < end and source_without_comments[value_cursor].isspace():
            value_cursor += 1
        if value_cursor >= end or source_without_comments[value_cursor] != "=":
            raise ManifestError(
                f"Typed localization enum {domain['enum']!r} has an implicit or "
                f"unsupported case declaration for {case_name!r}"
            )
        literal_start = value_cursor + 1
        while literal_start < end and source_without_comments[literal_start].isspace():
            literal_start += 1
        if _string_start(source_without_comments, literal_start) is None:
            raise ManifestError(
                f"Typed localization enum {domain['enum']!r} case {case_name!r} "
                "must have an explicit string raw value"
            )
        literal_end = _string_end(source, literal_start)
        terminator = literal_end
        while (
            terminator < end
            and source_without_comments[terminator] not in "\n;"
        ):
            if not source_without_comments[terminator].isspace():
                raise ManifestError(
                    f"Typed localization enum {domain['enum']!r} case {case_name!r} "
                    "must be declared alone with one explicit raw value"
                )
            terminator += 1
        key = decode_swift_string_literal(source[literal_start:literal_end])
        if case_name in cases or any(existing[0] == key for existing in cases.values()):
            raise ManifestError(
                f"Typed localization enum {domain['enum']!r} has duplicate case or "
                f"raw value for {case_name!r}"
            )
        cases[case_name] = (key, literal_start)
        cursor = max(cursor + 1, terminator - start)

    if not cases:
        raise ManifestError(
            f"Typed localization enum {domain['enum']!r} has no explicit cases"
        )

    fallback_property = domain.get("fallbackProperty", "developmentFallback")
    property_match = re.search(
        rf"\bvar\s+{re.escape(fallback_property)}\s*:\s*String\s*{{",
        source[start:end],
    )
    fallbacks: dict[str, str] = {}
    if property_match:
        property_opening = start + property_match.end() - 1
        property_end = _matching_delimiter(mask_swift_comments(source), property_opening)
        property_body = source[property_opening + 1 : property_end]
        for match in re.finditer(
            r"\bcase\s+((?:\.[A-Za-z_][A-Za-z0-9_]*\s*,\s*)*"
            r"\.[A-Za-z_][A-Za-z0-9_]*)\s*:\s*return\s*",
            mask_swift_comments(property_body),
        ):
            literal_start = property_opening + 1 + match.end()
            while literal_start < len(source) and source[literal_start].isspace():
                literal_start += 1
            try:
                literal_end = _string_end(source, literal_start)
            except ManifestError:
                continue
            fallback = decode_swift_string_literal(source[literal_start:literal_end])
            for case_name in re.findall(
                r"\.([A-Za-z_][A-Za-z0-9_]*)", match.group(1)
            ):
                fallbacks[case_name] = fallback

    if domain.get("casePolicy") == "allCasesRequired":
        missing_fallbacks = sorted(set(cases) - set(fallbacks))
        unknown_fallbacks = sorted(set(fallbacks) - set(cases))
        if missing_fallbacks or unknown_fallbacks:
            details = (
                f"missing {missing_fallbacks}"
                if missing_fallbacks
                else f"unknown {unknown_fallbacks}"
            )
            raise ManifestError(
                f"Typed localization enum {domain['enum']!r} fallback coverage is "
                f"incomplete: {details}"
            )

    return relative_path, source, cases, fallbacks


def _typed_domain_calls(
    root: Path, domain: dict[str, Any], config: dict[str, Any]
) -> list[dict[str, Any]]:
    relative_path, source, cases, fallbacks = _typed_domain_definition(root, domain)

    calls = []
    for case_name, (key, offset) in sorted(cases.items(), key=lambda item: item[1][0]):
        fallback = fallbacks.get(case_name)
        argument_count = format_argument_count(
            parse_format_signature(fallback or "")
        )
        calls.append(
            _callsite(
                source=source,
                path=relative_path,
                offset=offset,
                api=_typed_api(domain, argument_count),
                key=key,
                fallback=fallback,
                argument_count=argument_count,
                origin="typedResolved",
                config=config,
                domain=domain.get("name", domain["enum"]),
            )
        )
    return calls


def _typed_api(domain: dict[str, Any], argument_count: int | None) -> str:
    api = domain.get("api", "legacy")
    if domain.get("formatWhenArgumentsPresent") and (argument_count or 0) > 0:
        return "format"
    return api


def _typed_facade_callsite_calls(
    root: Path,
    domain: dict[str, Any],
    config: dict[str, Any],
    source_paths: Iterable[str],
) -> tuple[list[dict[str, Any]], list[str]]:
    """Resolve literal enum cases passed to a configured typed facade.

    Literal invocations become observed active keys. Enum-valued expressions are
    accepted only when the facade configuration declares their bounded cases.
    """

    facade_calls = domain.get("facadeCalls", [])
    if not facade_calls:
        return [], []
    source_paths = tuple(source_paths)
    _, _, cases, fallbacks = _typed_domain_definition(root, domain)
    domain_name = domain.get("name", domain["enum"])
    results: list[dict[str, Any]] = []
    matched_facades: set[str] = set()
    source_cache: dict[str, tuple[str, str]] = {}

    for facade_index, declaration in enumerate(facade_calls):
        callee = declaration.get("callee")
        paths = declaration.get("paths")
        if not isinstance(callee, str) or not callee.strip():
            raise ManifestError(
                f"Typed domain {domain_name!r} has a facade call without a callee"
            )
        if not isinstance(paths, list) or not paths or not all(
            isinstance(pattern, str) and pattern for pattern in paths
        ):
            raise ManifestError(
                f"Typed domain {domain_name!r} facade {callee!r} must declare paths"
            )

        preceding_characters = "A-Za-z0-9_." if "." not in callee else "A-Za-z0-9_"
        callee_pattern = r"\s*\.\s*".join(
            re.escape(component) for component in callee.split(".")
        )
        pattern = re.compile(
            rf"(?<![{preceding_characters}]){callee_pattern}\s*\("
        )
        for relative_path in source_paths:
            if not any(fnmatch.fnmatch(relative_path, path) for path in paths):
                continue
            if relative_path not in source_cache:
                source = (root / relative_path).read_text(encoding="utf-8")
                source_without_comments = mask_swift_comments(source)
                source_cache[relative_path] = (
                    source_without_comments,
                    _mask_strings(source_without_comments),
                )
            source_without_comments, code = source_cache[relative_path]
            for match in pattern.finditer(code):
                # A bare method name may also match its declaration in the enum's
                # implementation file. It is not a runtime localization lookup.
                if re.search(
                    r"\bfunc\s*$",
                    code[max(0, match.start() - 32) : match.start()],
                ):
                    continue
                matched_facades.add(
                    f"typed:{domain_name}:facade:{facade_index}"
                )
                opening = match.end() - 1
                closing = _matching_delimiter(source_without_comments, opening)
                arguments = _parse_arguments(
                    source_without_comments[opening + 1 : closing]
                )
                key_expression = (_unlabeled_argument(arguments) or "").strip()
                while key_expression.startswith("("):
                    try:
                        outer_closing = _matching_delimiter(key_expression, 0)
                    except ManifestError:
                        break
                    if outer_closing != len(key_expression) - 1:
                        break
                    key_expression = key_expression[1:outer_closing].strip()
                case_match = re.fullmatch(
                    rf"(?:{re.escape(domain['enum'])}\s*)?\.\s*"
                    r"([A-Za-z_][A-Za-z0-9_]*)",
                    key_expression,
                )
                if case_match is None:
                    dynamic_cases = declaration.get("dynamicCases")
                    if not isinstance(dynamic_cases, list) or not dynamic_cases:
                        raise ManifestError(
                            f"{relative_path}:"
                            f"{_line_number(source_without_comments, match.start())}: "
                            f"unbounded typed localization call {callee!r} with "
                            f"expression {key_expression!r}"
                        )
                    invalid_dynamic_cases = [
                        case_name
                        for case_name in dynamic_cases
                        if not isinstance(case_name, str) or case_name not in cases
                    ]
                    if invalid_dynamic_cases:
                        raise ManifestError(
                            f"Typed localization facade {callee!r} has unknown "
                            f"dynamic cases {invalid_dynamic_cases}"
                        )
                    argument_count = _array_argument_count(
                        _argument(arguments, "arguments")
                    )
                    for case_name in sorted(set(dynamic_cases)):
                        key, _ = cases[case_name]
                        results.append(
                            _callsite(
                                source=source_without_comments,
                                path=relative_path,
                                offset=match.start(),
                                api=_typed_api(domain, argument_count),
                                key=key,
                                fallback=fallbacks.get(case_name),
                                argument_count=argument_count,
                                origin="typedDynamic",
                                config=config,
                                domain=domain_name,
                                type_safety="typed",
                            )
                        )
                    continue
                case_name = case_match.group(1)
                if case_name not in cases:
                    raise ManifestError(
                        f"{relative_path}:"
                        f"{_line_number(source_without_comments, match.start())}: "
                        f"Typed localization case {case_name!r} is not declared in "
                        f"{domain['enum']}"
                    )
                key, _ = cases[case_name]
                argument_count = _array_argument_count(
                    _argument(arguments, "arguments")
                )
                results.append(
                    _callsite(
                        source=source_without_comments,
                        path=relative_path,
                        offset=match.start(),
                        api=_typed_api(domain, argument_count),
                        key=key,
                        fallback=fallbacks.get(case_name),
                        argument_count=argument_count,
                        origin="typedCallsite",
                        config=config,
                        domain=domain_name,
                        type_safety="typed",
                    )
                )

    return (
        sorted(
            results,
            key=lambda item: (item["key"], item["path"], item["line"], item["api"]),
        ),
        sorted(matched_facades),
    )


def _catalog_english(entry: dict[str, Any]) -> tuple[str | None, list[dict[str, Any]]]:
    localization = entry.get("localizations", {}).get("en")
    if not isinstance(localization, dict):
        return None, []
    signature_map = localization_signature_map(localization) or {}
    if "stringUnit" in localization:
        value = localization.get("stringUnit", {}).get("value")
        signature = (
            signature_map.get("other")
            or signature_map.get("string")
            or next(iter(signature_map.values()), [])
        )
        return (
            value if isinstance(value, str) and value.strip() else None,
            signature,
        )
    try:
        variations = localization["variations"]["plural"]
        other = variations["other"]["stringUnit"]["value"]
    except (KeyError, TypeError):
        return None, []
    return (
        other if isinstance(other, str) and other.strip() else None,
        signature_map.get("other", parse_format_signature(other))
        if isinstance(other, str)
        else [],
    )


def _localization_contains_legacy_markup(localization: Any) -> bool:
    if isinstance(localization, dict):
        value = localization.get("value")
        if isinstance(value, str) and HTML_PATTERN.search(value):
            return True
        return any(
            _localization_contains_legacy_markup(child)
            for child in localization.values()
        )
    if isinstance(localization, list):
        return any(
            _localization_contains_legacy_markup(child) for child in localization
        )
    return False


def _inventory_interface_builder(root: Path, source_roots: Iterable[str]) -> list[dict[str, Any]]:
    entries: list[dict[str, Any]] = []
    for source_root in source_roots:
        directory = root / source_root
        if not directory.is_dir():
            continue
        for path in sorted(directory.rglob("*")):
            relative = path.relative_to(root).as_posix()
            if path.suffix in {".storyboard", ".xib"}:
                text = path.read_text(encoding="utf-8")
                for tag_match in re.finditer(r"<[^!?/][^>]*>", text):
                    attributes = {
                        name: value
                        for name, value in re.findall(
                            r'([A-Za-z_:][A-Za-z0-9_.:-]*)="([^"]*)"',
                            tag_match.group(0),
                        )
                    }
                    object_id = attributes.get("id")
                    for attribute in sorted(VISIBLE_INTERFACE_ATTRIBUTES & attributes.keys()):
                        value = attributes[attribute]
                        if value.strip():
                            entries.append(
                                {
                                    "attribute": attribute,
                                    "objectID": object_id,
                                    "path": relative,
                                    "value": value,
                                }
                            )
            elif path.suffix == ".strings" and path.name != "Localizable.strings":
                locale_match = re.search(r"/([^/]+)\.lproj/", f"/{relative}")
                locale = locale_match.group(1) if locale_match else None
                text = path.read_text(encoding="utf-8")
                for match in re.finditer(
                    r'^\s*"((?:\\.|[^"\\])*)"\s*=\s*"((?:\\.|[^"\\])*)"\s*;',
                    text,
                    re.MULTILINE,
                ):
                    entries.append(
                        {
                            "key": bytes(match.group(1), "utf-8").decode("unicode_escape"),
                            "locale": locale,
                            "path": relative,
                            "value": bytes(match.group(2), "utf-8").decode("unicode_escape"),
                        }
                    )
    return sorted(
        entries,
        key=lambda item: (
            item["path"],
            item.get("objectID") or "",
            item.get("attribute") or item.get("key") or "",
            item.get("locale") or "",
        ),
    )


def _load_info_plist(path: Path, context: str) -> dict[str, Any]:
    result = subprocess.run(
        ["/usr/bin/plutil", "-convert", "json", "-o", "-", str(path)],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        suffix = f": {detail}" if detail else ""
        raise ManifestError(f"{context} could not be parsed{suffix}")
    try:
        document = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise ManifestError(f"{context} could not be parsed as JSON") from error
    if not isinstance(document, dict):
        raise ManifestError(f"{context} must contain a top-level dictionary")
    return document


def _info_plist_visible_strings(
    document: dict[str, Any],
    context: str,
) -> dict[str, str]:
    visible: dict[str, str] = {}
    for key, value in sorted(document.items()):
        if key not in INFO_PLIST_VISIBLE_KEYS and not key.endswith("UsageDescription"):
            continue
        if not isinstance(value, str) or not value.strip():
            raise ManifestError(
                f"{context} visible key {key} must have a non-empty string value"
            )
        visible[key] = value
    return visible


def _configured_info_plist_templates(
    root: Path,
    config: dict[str, Any],
) -> list[str]:
    configured = config.get("infoPlistTemplates", [])
    if not isinstance(configured, list):
        raise ManifestError("infoPlistTemplates must be an array")
    templates: list[str] = []
    for index, relative in enumerate(configured):
        context = f"infoPlistTemplates[{index}]"
        if not isinstance(relative, str) or not relative.strip():
            raise ManifestError(f"{context} must be a non-empty string")
        candidate = Path(relative)
        if (
            candidate.is_absolute()
            or ".." in candidate.parts
            or candidate.as_posix() != relative
            or any(marker in relative for marker in "*?[")
        ):
            raise ManifestError(
                f"{context} must be an exact repository-relative path"
            )
        if relative in templates:
            raise ManifestError(f"Duplicate {context}: {relative}")
        if not (root / relative).is_file():
            raise ManifestError(f"{context} must name an existing file: {relative}")
        if (root / ".git").exists():
            tracked = subprocess.run(
                [
                    "git",
                    "-C",
                    str(root),
                    "ls-files",
                    "--error-unmatch",
                    "--",
                    relative,
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            if tracked.returncode != 0:
                raise ManifestError(
                    f"{context} must name a git-tracked template: {relative}"
                )
        templates.append(relative)
    return templates


def _inventory_info_plist(
    root: Path,
    config: dict[str, Any],
) -> list[dict[str, Any]]:
    entries: list[dict[str, Any]] = []
    for relative in _configured_info_plist_templates(root, config):
        template_path = root / relative
        template_context = f"Info.plist template {relative}"
        template_document = _load_info_plist(template_path, template_context)
        template_visible = _info_plist_visible_strings(
            template_document,
            template_context,
        )
        if not template_visible:
            raise ManifestError(f"{template_context} has no visible strings")

        if relative.endswith(".example"):
            assembled_relative = relative[: -len(".example")]
            assembled_path = root / assembled_relative
            if assembled_path.exists():
                assembled_context = f"Assembled Info.plist {assembled_relative}"
                if not assembled_path.is_file():
                    raise ManifestError(f"{assembled_context} is not a file")
                assembled_document = _load_info_plist(
                    assembled_path,
                    assembled_context,
                )
                assembled_visible = _info_plist_visible_strings(
                    assembled_document,
                    assembled_context,
                )
                for key, value in template_visible.items():
                    if key not in assembled_visible:
                        raise ManifestError(
                            f"{assembled_context} is missing visible key {key} "
                            f"from template {relative}"
                        )
                    if assembled_visible[key] != value:
                        raise ManifestError(
                            f"{assembled_context} visible key {key} does not "
                            f"match template {relative}"
                        )
                extra_visible = sorted(set(assembled_visible) - set(template_visible))
                if extra_visible:
                    raise ManifestError(
                        f"{assembled_context} has visible key {extra_visible[0]} "
                        f"missing from template {relative}"
                    )

        entries.extend(
            {
                "key": key,
                "path": relative,
                "value": value,
            }
            for key, value in template_visible.items()
        )
    return sorted(entries, key=lambda item: (item["path"], item["key"]))


def _deduplicate_dicts(items: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    by_json = {
        json.dumps(item, ensure_ascii=False, sort_keys=True): item for item in items
    }
    return [by_json[key] for key in sorted(by_json)]


def _manifest_dynamic_domains(
    config: dict[str, Any],
    calls: list[dict[str, Any]],
    typed_definitions: list[dict[str, Any]],
    dynamic_matches: Iterable[str],
) -> list[dict[str, Any]]:
    configured: list[tuple[str, dict[str, Any]]] = [
        ("bounded", domain)
        for domain in config.get("boundedDynamicDomains", [])
    ] + [
        ("typed", domain)
        for domain in config.get("typedDomains", [])
    ]
    names = [domain.get("name") for _, domain in configured]
    if any(not isinstance(name, str) or not name for name in names):
        raise ManifestError("Every dynamic localization domain must have a name")
    if len(set(names)) != len(names):
        raise ManifestError("Dynamic localization domain names must be unique")

    matched = set(dynamic_matches)
    for kind, domain in configured:
        domain_name = domain["name"]
        declared_patterns = domain.get("patterns")
        if declared_patterns is None and isinstance(domain.get("callsite"), dict):
            declared_patterns = [domain["callsite"]]
        if declared_patterns is None and kind == "bounded":
            declared_patterns = [domain]
        for pattern_index, _ in enumerate(declared_patterns or []):
            marker = f"{kind}:{domain_name}:pattern:{pattern_index}"
            if marker not in matched:
                raise ManifestError(
                    f"Dynamic localization domain {domain_name!r} pattern "
                    f"{pattern_index} matched no localization calls"
                )
        if kind == "typed":
            for facade_index, _ in enumerate(domain.get("facadeCalls", [])):
                marker = f"typed:{domain_name}:facade:{facade_index}"
                if marker not in matched:
                    raise ManifestError(
                        f"Dynamic localization domain {domain_name!r} facade "
                        f"{facade_index} matched no localization calls"
                    )

    calls_by_domain: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for call in calls:
        domain = call.get("domain")
        if isinstance(domain, str):
            calls_by_domain[domain].append(call)
    definitions_by_domain: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for definition in typed_definitions:
        domain = definition.get("domain")
        if isinstance(domain, str):
            definitions_by_domain[domain].append(definition)

    result: list[dict[str, Any]] = []
    for kind, domain in sorted(configured, key=lambda item: item[1]["name"]):
        if not calls_by_domain.get(domain["name"]):
            raise ManifestError(
                f"Dynamic localization domain {domain['name']!r} matched no "
                "localization calls"
            )
        declared_patterns = domain.get("patterns")
        if declared_patterns is None and isinstance(domain.get("callsite"), dict):
            declared_patterns = [domain["callsite"]]
        if declared_patterns is None and kind == "bounded":
            declared_patterns = [domain]

        patterns: list[dict[str, Any]] = []
        for pattern in declared_patterns or []:
            normalized = {
                field: pattern[field]
                for field in ("api", "keyExpression")
                if field in pattern
            }
            patterns.append(normalized)
        if kind == "typed" and not patterns:
            pattern = {
                "api": domain.get("api", "legacy"),
                "enum": domain["enum"],
            }
            if domain.get("formatWhenArgumentsPresent"):
                pattern["formatWhenArgumentsPresent"] = True
            patterns.append(pattern)

        paths = set(domain.get("paths") or [])
        if domain.get("path"):
            paths.add(domain["path"])
        if domain.get("source"):
            paths.add(domain["source"])
        callsite = domain.get("callsite")
        if isinstance(callsite, dict) and callsite.get("path"):
            paths.add(callsite["path"])

        expanded_by_key: dict[str, set[str]] = defaultdict(set)
        for call in calls_by_domain.get(domain["name"], []):
            expanded_by_key[call["key"]].add(call["api"])
        entry: dict[str, Any] = {
            "expandedKeys": [
                {"apis": sorted(expanded_by_key[key]), "key": key}
                for key in sorted(expanded_by_key)
            ],
            "kind": kind,
            "name": domain["name"],
            "paths": sorted(paths),
            "patterns": _deduplicate_dicts(patterns),
        }
        if kind == "typed":
            entry["casePolicy"] = domain["casePolicy"]
            declared_by_key: dict[str, set[str]] = defaultdict(set)
            for definition in definitions_by_domain.get(domain["name"], []):
                declared_by_key[definition["key"]].add(definition["api"])
            entry["declaredKeys"] = [
                {"apis": sorted(declared_by_key[key]), "key": key}
                for key in sorted(declared_by_key)
            ]
            entry["enum"] = domain["enum"]
            entry["facadeCalls"] = sorted(
                [
                    {
                        "callee": facade["callee"],
                        **(
                            {"dynamicCases": sorted(set(facade["dynamicCases"]))}
                            if facade.get("dynamicCases")
                            else {}
                        ),
                        "paths": sorted(set(facade["paths"])),
                    }
                    for facade in domain.get("facadeCalls", [])
                ],
                key=lambda facade: (
                    facade["callee"],
                    tuple(facade["paths"]),
                ),
            )
        result.append(entry)
    return result


PBX_OBJECT_ID_PATTERN = r"[A-Za-z0-9]{24}"
APPLICATION_TARGET_NAMES = ("xabber", "xabber-push-extension")


def _pbx_section_objects(source: str, section: str) -> dict[str, str]:
    """Parse object bodies from one ASCII Xcode project section."""

    begin = f"/* Begin {section} section */"
    end = f"/* End {section} section */"
    start = source.find(begin)
    finish = source.find(end, start + len(begin)) if start >= 0 else -1
    if start < 0 or finish < 0:
        return {}
    contents = source[start + len(begin) : finish]
    header = re.compile(
        rf"^\s*(?P<id>{PBX_OBJECT_ID_PATTERN})"
        r"(?:\s*/\*.*?\*/)?\s*=\s*\{",
        re.MULTILINE,
    )
    result: dict[str, str] = {}
    for match in header.finditer(contents):
        opening = match.end() - 1
        depth = 0
        quoted = False
        escaped = False
        closing = None
        for index in range(opening, len(contents)):
            character = contents[index]
            if quoted:
                if escaped:
                    escaped = False
                elif character == "\\":
                    escaped = True
                elif character == '"':
                    quoted = False
                continue
            if character == '"':
                quoted = True
            elif character == "{":
                depth += 1
            elif character == "}":
                depth -= 1
                if depth == 0:
                    closing = index
                    break
        if closing is None:
            raise ManifestError(
                f"Malformed {section} object {match.group('id')} in Xcode project"
            )
        result[match.group("id")] = contents[opening + 1 : closing]
    return result


def _pbx_scalar(body: str, field: str) -> str | None:
    match = re.search(
        rf"(?:^|;)\s*{re.escape(field)}\s*=\s*([^;]*?);",
        body,
    )
    if match is None:
        return None
    value = match.group(1).strip()
    if value.startswith('"') and value.endswith('"'):
        try:
            decoded = json.loads(value)
        except json.JSONDecodeError as error:
            raise ManifestError(
                f"Malformed quoted {field} in Xcode project: {value}"
            ) from error
        return decoded if isinstance(decoded, str) else None
    return value


def _pbx_list_ids(body: str, field: str) -> list[str]:
    match = re.search(
        rf"\b{re.escape(field)}\s*=\s*\((?P<items>.*?)\);",
        body,
        re.DOTALL,
    )
    if match is None:
        return []
    return re.findall(rf"\b({PBX_OBJECT_ID_PATTERN})\b", match.group("items"))


def _normalize_project_path(path: str) -> str:
    normalized = Path(path).as_posix()
    while normalized.startswith("./"):
        normalized = normalized[2:]
    return normalized


def _application_source_memberships(root: Path) -> dict[str, set[str]]:
    project_path = root / "xabber.xcodeproj/project.pbxproj"
    if not project_path.is_file():
        raise ManifestError(
            "Cannot validate non-target sources: Xcode project does not exist at "
            "xabber.xcodeproj/project.pbxproj"
        )
    source = project_path.read_text(encoding="utf-8")
    file_references = _pbx_section_objects(source, "PBXFileReference")
    build_files = _pbx_section_objects(source, "PBXBuildFile")
    source_phases = _pbx_section_objects(source, "PBXSourcesBuildPhase")
    native_targets = _pbx_section_objects(source, "PBXNativeTarget")
    groups: dict[str, str] = {}
    for section in (
        "PBXGroup",
        "PBXVariantGroup",
        "XCVersionGroup",
        "PBXFileSystemSynchronizedRootGroup",
    ):
        groups.update(_pbx_section_objects(source, section))

    parent_by_child: dict[str, str] = {}
    for group_id, body in groups.items():
        for child_id in _pbx_list_ids(body, "children"):
            parent_by_child.setdefault(child_id, group_id)

    group_path_cache: dict[str, tuple[str, ...]] = {}

    def group_path(group_id: str, visiting: set[str] | None = None) -> tuple[str, ...]:
        cached = group_path_cache.get(group_id)
        if cached is not None:
            return cached
        visiting = set() if visiting is None else set(visiting)
        if group_id in visiting:
            raise ManifestError(f"Cyclic PBXGroup hierarchy at {group_id}")
        visiting.add(group_id)
        body = groups.get(group_id, "")
        source_tree = _pbx_scalar(body, "sourceTree")
        parent = parent_by_child.get(group_id)
        if source_tree == "SOURCE_ROOT" or parent is None:
            parts: tuple[str, ...] = ()
        else:
            parts = group_path(parent, visiting)
        value = _pbx_scalar(body, "path")
        if value and value != ".":
            parts += tuple(Path(value).parts)
        group_path_cache[group_id] = parts
        return parts

    resolved_references: dict[str, str] = {}
    for reference_id, body in file_references.items():
        value = _pbx_scalar(body, "path") or _pbx_scalar(body, "name")
        if not value:
            continue
        source_tree = _pbx_scalar(body, "sourceTree")
        if source_tree == "SOURCE_ROOT":
            parts: tuple[str, ...] = ()
        elif source_tree == "<group>" or source_tree is None:
            parent = parent_by_child.get(reference_id)
            parts = group_path(parent) if parent is not None else ()
        else:
            continue
        resolved_references[reference_id] = _normalize_project_path(
            Path(*parts, value).as_posix()
        )

    reference_by_build_file: dict[str, str] = {}
    for build_id, body in build_files.items():
        match = re.search(
            rf"\bfileRef\s*=\s*({PBX_OBJECT_ID_PATTERN})\b",
            body,
        )
        if match is not None:
            reference_by_build_file[build_id] = match.group(1)

    target_bodies: dict[str, str] = {}
    for body in native_targets.values():
        name = _pbx_scalar(body, "name")
        if name in APPLICATION_TARGET_NAMES:
            target_bodies[name] = body
    missing_targets = sorted(set(APPLICATION_TARGET_NAMES) - set(target_bodies))
    if missing_targets:
        raise ManifestError(
            "Cannot validate non-target sources: Xcode project is missing target "
            f"{missing_targets[0]}"
        )

    memberships: dict[str, set[str]] = defaultdict(set)
    for target_name in APPLICATION_TARGET_NAMES:
        target_body = target_bodies[target_name]
        for phase_id in _pbx_list_ids(target_body, "buildPhases"):
            phase = source_phases.get(phase_id)
            if phase is None:
                continue
            for build_id in _pbx_list_ids(phase, "files"):
                reference_id = reference_by_build_file.get(build_id)
                path = resolved_references.get(reference_id or "")
                if path:
                    memberships[path].add(target_name)

        for group_id in _pbx_list_ids(target_body, "fileSystemSynchronizedGroups"):
            synchronized_root = Path(*group_path(group_id))
            absolute_root = root / synchronized_root
            if not absolute_root.is_dir():
                raise ManifestError(
                    "Cannot validate non-target sources: synchronized group does not "
                    f"exist at {synchronized_root.as_posix()}"
                )
            for path in absolute_root.rglob("*.swift"):
                memberships[path.relative_to(root).as_posix()].add(target_name)
    return memberships


def _non_target_sources(
    root: Path,
    config: dict[str, Any],
    source_roots: list[str],
) -> dict[str, str]:
    configured = config.get("nonTargetSources", [])
    if not isinstance(configured, list):
        raise ManifestError("nonTargetSources must be an array")
    result: dict[str, str] = {}
    for index, entry in enumerate(configured):
        context = f"non-target source {index}"
        if not isinstance(entry, dict) or set(entry) != {"path", "reason"}:
            raise ManifestError(f"{context} must contain exactly path and reason")
        path = entry["path"]
        reason = entry["reason"]
        if not isinstance(path, str) or not path.strip():
            raise ManifestError(f"{context} path must be a non-empty string")
        if not isinstance(reason, str) or not reason.strip():
            raise ManifestError(f"{context} reason must be a non-empty string")
        if Path(path).is_absolute() or ".." in Path(path).parts or any(
            marker in path for marker in "*?["
        ):
            raise ManifestError(
                f"{context} must be an exact repository-relative path"
            )
        if path in result:
            raise ManifestError(f"Duplicate {context}: {path}")
        if not any(
            path == source_root or path.startswith(source_root + "/")
            for source_root in source_roots
        ):
            raise ManifestError(f"{context} is outside configured source roots: {path}")
        target = root / path
        if target.suffix != ".swift" or not target.is_file():
            raise ManifestError(
                f"{context} does not name an existing Swift source: {path}"
            )
        result[path] = reason

    if result:
        memberships = _application_source_memberships(root)
        for path in sorted(result):
            targets = sorted(memberships.get(path, set()))
            if targets:
                raise ManifestError(
                    f"Stale non-target source target membership: {path} is compiled by "
                    + ", ".join(targets)
                )
    return result


def _hardcoded_ui_excluded_paths(
    root: Path,
    config: dict[str, Any],
    source_roots: list[str],
) -> dict[str, str]:
    configured = config.get("hardcodedUIExcludedPaths", [])
    if not isinstance(configured, list):
        raise ManifestError("hardcodedUIExcludedPaths must be an array")
    result: dict[str, str] = {}
    for index, entry in enumerate(configured):
        context = f"hardcoded UI excluded path {index}"
        if not isinstance(entry, dict) or set(entry) != {"path", "reason"}:
            raise ManifestError(f"{context} must contain exactly path and reason")
        path = entry["path"]
        reason = entry["reason"]
        if not isinstance(path, str) or not path.strip():
            raise ManifestError(f"{context} path must be a non-empty string")
        if not isinstance(reason, str) or not reason.strip():
            raise ManifestError(f"{context} reason must be a non-empty string")
        if Path(path).is_absolute() or ".." in Path(path).parts or any(
            marker in path for marker in "*?["
        ):
            raise ManifestError(
                f"{context} must be an exact repository-relative path"
            )
        if path in result:
            raise ManifestError(f"Duplicate {context}: {path}")
        if not any(
            path == source_root or path.startswith(source_root + "/")
            for source_root in source_roots
        ):
            raise ManifestError(f"{context} is outside configured source roots: {path}")
        target = root / path
        if target.suffix != ".swift" or not target.is_file():
            raise ManifestError(
                f"{context} does not name an existing Swift source: {path}"
            )
        result[path] = reason
    return result


def _apply_hardcoded_ui_exclusions(
    root: Path,
    candidates: list[dict[str, Any]],
    config: dict[str, Any],
) -> list[dict[str, Any]]:
    configured = config.get("hardcodedUIExclusions", [])
    if not isinstance(configured, list):
        raise ManifestError("hardcodedUIExclusions must be an array")
    candidate_fields = {"line", "path", "sink", "value"}
    candidate_identities = {
        (item["line"], item["path"], item["sink"], item["value"])
        for item in candidates
    }
    candidates_by_stable_identity: dict[
        tuple[str, str, str], list[tuple[int, str, str, str]]
    ] = defaultdict(list)
    for identity in candidate_identities:
        line, path, sink, value = identity
        candidates_by_stable_identity[(path, sink, value)].append(identity)
    excluded: set[tuple[int, str, str, str]] = set()
    excluded_stable_identities: set[tuple[str, str, str]] = set()

    configured_files = config.get("hardcodedUIExclusionFiles", [])
    if not isinstance(configured_files, list):
        raise ManifestError("hardcodedUIExclusionFiles must be an array")
    seen_files: set[str] = set()
    for file_index, relative_path in enumerate(configured_files):
        context = f"hardcoded UI exclusion file {file_index}"
        if not isinstance(relative_path, str) or not relative_path.strip():
            raise ManifestError(f"{context} must be a non-empty string")
        if (
            Path(relative_path).is_absolute()
            or ".." in Path(relative_path).parts
            or any(marker in relative_path for marker in "*?[")
        ):
            raise ManifestError(
                f"{context} must be an exact repository-relative path"
            )
        if relative_path in seen_files:
            raise ManifestError(
                f"Duplicate hardcoded UI exclusion file: {relative_path}"
            )
        seen_files.add(relative_path)
        path = root / relative_path
        if path.suffix != ".json" or not path.is_file():
            raise ManifestError(
                f"{context} does not name an existing JSON file: {relative_path}"
            )
        document = load_config(path)
        file_exclusions = document.get("exclusions")
        if not isinstance(file_exclusions, list):
            raise ManifestError(f"{context} must contain an exclusions array")
        for entry_index, entry in enumerate(file_exclusions):
            entry_context = f"{context} exclusion {entry_index}"
            expected_fields = {"path", "sink", "value", "reason"}
            if not isinstance(entry, dict) or set(entry) != expected_fields:
                raise ManifestError(
                    f"{entry_context} must contain exactly path, sink, value, and reason"
                )
            for field in expected_fields:
                if not isinstance(entry[field], str) or not entry[field].strip():
                    raise ManifestError(
                        f"{entry_context} {field} must be a non-empty string"
                    )
            stable_identity = (entry["path"], entry["sink"], entry["value"])
            if stable_identity in excluded_stable_identities:
                raise ManifestError(
                    f"Duplicate hardcoded UI exclusion: {stable_identity!r}"
                )
            matches = candidates_by_stable_identity.get(stable_identity, [])
            if not matches:
                raise ManifestError(
                    "Stale hardcoded UI exclusion: "
                    f"{entry['path']} {entry['sink']} {entry['value']!r}"
                )
            excluded_stable_identities.add(stable_identity)
            # Stable mapping entries intentionally omit line numbers so they
            # survive nearby source edits.  Repeated identical diagnostic or
            # fixture strings in one file form one reviewed exclusion and all
            # exact occurrences are removed together.
            excluded.update(matches)

    for index, entry in enumerate(configured):
        context = f"hardcoded UI exclusion {index}"
        if not isinstance(entry, dict) or set(entry) != candidate_fields | {"reason"}:
            raise ManifestError(
                f"{context} must contain exactly line, path, sink, value, and reason"
            )
        if type(entry["line"]) is not int or entry["line"] < 1:
            raise ManifestError(f"{context} line must be a positive integer")
        for field in ("path", "sink", "value", "reason"):
            if not isinstance(entry[field], str) or not entry[field].strip():
                raise ManifestError(f"{context} {field} must be a non-empty string")
        identity = (
            entry["line"],
            entry["path"],
            entry["sink"],
            entry["value"],
        )
        stable_identity = (entry["path"], entry["sink"], entry["value"])
        if stable_identity in excluded_stable_identities:
            raise ManifestError(
                f"Duplicate hardcoded UI exclusion: {stable_identity!r}"
            )
        if identity in excluded:
            raise ManifestError(f"Duplicate {context}: {identity!r}")
        if identity not in candidate_identities:
            raise ManifestError(
                f"Stale or mismatched {context}: "
                f"{entry['path']}:{entry['line']} "
                f"{entry['sink']} {entry['value']!r}"
            )
        excluded.add(identity)
        excluded_stable_identities.add(stable_identity)
    return [
        item
        for item in candidates
        if (item["line"], item["path"], item["sink"], item["value"])
        not in excluded
    ]


def build_manifest(root: Path, config: dict[str, Any]) -> dict[str, Any]:
    source_roots = config.get("sourceRoots", ["xabber", "xabber-push-extension"])
    if not isinstance(source_roots, list) or not all(
        isinstance(item, str) and item.strip() for item in source_roots
    ):
        raise ManifestError("Configured localization source roots must be strings")
    missing_source_roots = [
        source_root for source_root in source_roots if not (root / source_root).is_dir()
    ]
    if missing_source_roots:
        raise ManifestError(
            f"Configured localization source root is missing: {missing_source_roots[0]}"
        )
    hardcoded_excluded_paths = _hardcoded_ui_excluded_paths(
        root,
        config,
        source_roots,
    )
    non_target_sources = _non_target_sources(root, config, source_roots)
    require_zero_hardcoded = config.get("requireZeroUnclassifiedHardcodedUI", False)
    if type(require_zero_hardcoded) is not bool:
        raise ManifestError("requireZeroUnclassifiedHardcodedUI must be a boolean")
    catalog_path = config.get("catalog", DEFAULT_CATALOG_PATH)
    try:
        catalog = load_catalog(root / catalog_path)
    except CatalogError as error:
        raise ManifestError(str(error)) from error
    catalog_strings = catalog.get("strings")
    if not isinstance(catalog_strings, dict):
        raise ManifestError(f"Catalog {catalog_path} has no strings object")

    all_calls: list[dict[str, Any]] = []
    dynamic_matches: list[str] = []
    unresolved: list[dict[str, Any]] = []
    direct_lookups: list[dict[str, Any]] = []
    hardcoded: list[dict[str, Any]] = []
    typed_definitions: list[dict[str, Any]] = []
    scanned_source_paths: list[str] = []
    excluded_paths = config.get("excludedPaths", [])
    matched_hardcoded_excluded_paths: set[str] = set()
    for source_root in source_roots:
        directory = root / source_root
        for path in sorted(directory.rglob("*.swift")):
            relative = path.relative_to(root).as_posix()
            if any(fnmatch.fnmatch(relative, pattern) for pattern in excluded_paths):
                continue
            source = path.read_text(encoding="utf-8")
            result = scan_swift_source(source, relative, config)
            if relative in hardcoded_excluded_paths:
                if not result["hardcodedCandidates"]:
                    raise ManifestError(
                        "Stale hardcoded UI excluded path has no candidates: "
                        f"{relative}"
                    )
                matched_hardcoded_excluded_paths.add(relative)
            else:
                hardcoded.extend(result["hardcodedCandidates"])
            if relative in non_target_sources:
                continue
            scanned_source_paths.append(relative)
            frozen = _frozen_localization_declarations(source)
            if frozen:
                first = frozen[0]
                raise ManifestError(
                    "Localized static let freezes the process language: "
                    f"{relative}:{first['line']} ({first['name']})"
                )
            all_calls.extend(result["calls"])
            dynamic_matches.extend(result["dynamicMatches"])
            unresolved.extend(result["unresolved"])
            direct_lookups.extend(result["directLookups"])

    unmatched_hardcoded_paths = sorted(
        set(hardcoded_excluded_paths) - matched_hardcoded_excluded_paths
    )
    if unmatched_hardcoded_paths:
        raise ManifestError(
            "Stale hardcoded UI excluded path was not scanned: "
            f"{unmatched_hardcoded_paths[0]}"
        )

    for domain in config.get("typedDomains", []):
        if domain.get("casePolicy") not in {"allCasesRequired", "conservative"}:
            raise ManifestError(
                f"Typed domain {domain.get('name', domain.get('enum'))!r} must declare "
                "casePolicy as allCasesRequired or conservative"
            )
        typed_definitions.extend(_typed_domain_calls(root, domain, config))
        facade_calls, facade_matches = _typed_facade_callsite_calls(
            root,
            domain,
            config,
            sorted(set(scanned_source_paths)),
        )
        all_calls.extend(facade_calls)
        dynamic_matches.extend(facade_matches)

    for declared in config.get("declaredKeys", []):
        relative_path = declared["path"]
        source = (root / relative_path).read_text(encoding="utf-8")
        anchor = declared.get("anchor", declared["key"])
        offset = source.find(anchor)
        if offset < 0:
            raise ManifestError(
                f"Declared localization key {declared['key']!r} anchor is missing in {relative_path}"
            )
        all_calls.append(
            _callsite(
                source=source,
                path=relative_path,
                offset=offset,
                api=declared.get("api", "text"),
                key=declared["key"],
                fallback=declared.get("fallback"),
                argument_count=declared.get("argumentCount", 0),
                origin="generatedPattern",
                config=config,
                domain=declared.get("domain"),
            )
        )

    deduplicated_calls = _deduplicate_dicts(all_calls)
    calls_by_key: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for call in deduplicated_calls:
        calls_by_key[call["key"]].append(call)

    typed_definitions = _deduplicate_dicts(typed_definitions)
    dynamic_domains = _manifest_dynamic_domains(
        config,
        deduplicated_calls,
        typed_definitions,
        dynamic_matches,
    )

    computed_fallback_keys = {
        key
        for key, calls in calls_by_key.items()
        if any(call.get("fallback") is None for call in calls)
    }
    computed_fallback_config = config.get("computedFallbacks", {})
    if not isinstance(computed_fallback_config, dict) or any(
        not isinstance(key, str)
        or not isinstance(details, dict)
        or not isinstance(details.get("expression"), str)
        or not details["expression"].strip()
        or not isinstance(details.get("reason"), str)
        or not details["reason"].strip()
        for key, details in (
            computed_fallback_config.items()
            if isinstance(computed_fallback_config, dict)
            else []
        )
    ):
        raise ManifestError(
            "computedFallbacks must map localization keys to non-empty "
            "expression and reason strings"
        )
    configured_computed_fallbacks = set(computed_fallback_config)
    if computed_fallback_keys != configured_computed_fallbacks:
        unexpected = sorted(computed_fallback_keys - configured_computed_fallbacks)
        stale = sorted(configured_computed_fallbacks - computed_fallback_keys)
        detail = f"new keys {unexpected}" if unexpected else f"stale keys {stale}"
        raise ManifestError(
            f"Manifest computed fallback configuration does not match source: {detail}"
        )
    computed_fallbacks = [
        {
            "expression": computed_fallback_config[key]["expression"].strip(),
            "key": key,
            "reason": computed_fallback_config[key]["reason"].strip(),
        }
        for key in sorted(computed_fallback_keys)
    ]

    fallback_conflict_keys = {
        key
        for key, calls in calls_by_key.items()
        if len({call["fallback"] for call in calls if call.get("fallback")}) > 1
    }
    fallback_conflict_allowlist = config.get("fallbackConflictAllowlist", {})
    if not isinstance(fallback_conflict_allowlist, dict) or any(
        not isinstance(key, str)
        or not isinstance(reason, str)
        or not reason.strip()
        for key, reason in (
            fallback_conflict_allowlist.items()
            if isinstance(fallback_conflict_allowlist, dict)
            else []
        )
    ):
        raise ManifestError(
            "fallbackConflictAllowlist must map localization keys to non-empty reasons"
        )
    configured_fallback_conflicts = set(fallback_conflict_allowlist)
    if fallback_conflict_keys != configured_fallback_conflicts:
        unexpected = sorted(fallback_conflict_keys - configured_fallback_conflicts)
        stale = sorted(configured_fallback_conflicts - fallback_conflict_keys)
        detail = f"new keys {unexpected}" if unexpected else f"stale keys {stale}"
        raise ManifestError(
            f"Manifest fallback conflict quarantine does not match config: {detail}"
        )
    fallback_conflict_quarantine = [
        {"key": key, "reason": fallback_conflict_allowlist[key].strip()}
        for key in sorted(fallback_conflict_keys)
    ]

    english_overrides = config.get("englishOverrides", {})
    active_keys: list[dict[str, Any]] = []
    active_without_english = 0
    fallback_conflicts = 0
    for key in sorted(calls_by_key):
        callsites = sorted(
            calls_by_key[key],
            key=lambda item: (item["path"], item["line"], item["api"], item["origin"]),
        )
        fallbacks = sorted(
            {call["fallback"] for call in callsites if call.get("fallback")}
        )
        english_value, english_signature = _catalog_english(catalog_strings.get(key, {}))
        override = english_overrides.get(key)
        canonical_fallback = override or (fallbacks[0] if len(fallbacks) == 1 else None)
        if english_value is None:
            active_without_english += 1
        if len(fallbacks) > 1:
            fallback_conflicts += 1
        canonical_signature = english_signature
        if english_value is None and canonical_fallback is not None:
            canonical_signature = parse_format_signature(canonical_fallback)
        active_keys.append(
            {
                "apis": sorted({call["api"] for call in callsites}),
                "callsites": [
                    {name: value for name, value in call.items() if name != "key"}
                    for call in callsites
                ],
                "english": {
                    "fallbackStatus": (
                        "conflictingFallbacks"
                        if len(fallbacks) > 1
                        else "computedFallback"
                        if key in computed_fallback_keys
                        else "catalogWins"
                        if english_value is not None and fallbacks and english_value not in fallbacks
                        else "consistent"
                        if english_value is not None
                        else "override"
                        if override is not None
                        else "singleFallback"
                        if len(fallbacks) == 1
                        else "missingFallback"
                    ),
                    "value": english_value,
                },
                "fallbacks": fallbacks,
                "formatSignature": canonical_signature,
                "key": key,
                "origins": sorted({call["origin"] for call in callsites}),
                "surfaces": sorted(
                    {surface for call in callsites for surface in call["surfaces"]}
                ),
            }
        )

    active_key_names = set(calls_by_key)
    reserved_by_key: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for definition in typed_definitions:
        if definition["key"] not in active_key_names:
            reserved_by_key[definition["key"]].append(definition)
    domain_reserved_keys = [
        {
            "apis": sorted({item["api"] for item in reserved_by_key[key]}),
            "domains": sorted(
                {
                    item["domain"]
                    for item in reserved_by_key[key]
                    if isinstance(item.get("domain"), str)
                }
            ),
            "fallbacks": sorted(
                {
                    item["fallback"]
                    for item in reserved_by_key[key]
                    if isinstance(item.get("fallback"), str)
                }
            ),
            "formatSignatures": _deduplicate_dicts(
                [item["formatSignature"] for item in reserved_by_key[key]]
            ),
            "key": key,
            "surfaces": sorted(
                {
                    surface
                    for item in reserved_by_key[key]
                    for surface in item["surfaces"]
                }
            ),
        }
        for key in sorted(reserved_by_key)
    ]
    actual_legacy_markup_keys = {
        key
        for key, entry in catalog_strings.items()
        if _localization_contains_legacy_markup(
            entry.get("localizations", {}).get("en")
        )
    }
    configured_legacy_markup_keys = set(config.get("legacyMarkupKeys", []))
    if actual_legacy_markup_keys != configured_legacy_markup_keys:
        unexpected = sorted(actual_legacy_markup_keys - configured_legacy_markup_keys)
        stale = sorted(configured_legacy_markup_keys - actual_legacy_markup_keys)
        detail = (
            f"new keys {unexpected}" if unexpected else f"stale keys {stale}"
        )
        raise ManifestError(
            f"Catalog legacy markup quarantine does not match config: {detail}"
        )
    legacy_markup_quarantine = [
        {
            "key": key,
            "status": "active" if key in active_key_names else "catalogOnly",
        }
        for key in sorted(actual_legacy_markup_keys)
    ]
    interface_builder_keys = set(config.get("interfaceBuilderCatalogKeys", []))
    catalog_only: list[dict[str, str]] = []
    for key in sorted(set(catalog_strings) - active_key_names):
        english_value, _ = _catalog_english(catalog_strings[key])
        if key in interface_builder_keys:
            classification = "interfaceBuilder"
        elif LEGACY_PLURAL_PATTERN.match(key):
            classification = "retainedLegacyPlural"
        elif english_value and HTML_PATTERN.search(english_value):
            classification = "legacyMarkup"
        else:
            classification = "reviewCandidate"
        catalog_only.append({"classification": classification, "key": key})

    unresolved = _deduplicate_dicts(unresolved)
    direct_lookups = _deduplicate_dicts(direct_lookups)
    hardcoded = _apply_hardcoded_ui_exclusions(
        root,
        _deduplicate_dicts(hardcoded),
        config,
    )
    if require_zero_hardcoded and hardcoded:
        first = hardcoded[0]
        raise ManifestError(
            f"Manifest has {len(hardcoded)} unclassified hard-coded UI strings; "
            f"first: {first['path']}:{first['line']} "
            f"({first['sink']}: {first['value']!r})"
        )
    info_plist = _inventory_info_plist(root, config)
    document: dict[str, Any] = {
        "activeKeys": active_keys,
        "catalog": catalog_path,
        "catalogOnly": catalog_only,
        "computedFallbacks": computed_fallbacks,
        "directLookups": direct_lookups,
        "domainReservedKeys": domain_reserved_keys,
        "dynamicDomains": dynamic_domains,
        "excludedPaths": sorted(excluded_paths),
        "fallbackConflictQuarantine": fallback_conflict_quarantine,
        "hardcodedCandidates": hardcoded,
        "infoPlist": info_plist,
        "interfaceBuilder": _inventory_interface_builder(root, source_roots),
        "legacyMarkupQuarantine": legacy_markup_quarantine,
        "nonTargetSources": [
            {"path": path, "reason": non_target_sources[path]}
            for path in sorted(non_target_sources)
        ],
        "schemaVersion": SCHEMA_VERSION,
        "sourceLanguage": "en",
        "summary": {
            "activeKeys": len(active_keys),
            "activeWithoutEnglish": active_without_english,
            "catalogKeys": len(catalog_strings),
            "catalogOnlyKeys": len(catalog_only),
            "computedFallbacks": len(computed_fallbacks),
            "directLookups": len(direct_lookups),
            "domainReservedKeys": len(domain_reserved_keys),
            "dynamicDomains": len(dynamic_domains),
            "excludedPaths": len(excluded_paths),
            "fallbackConflicts": fallback_conflicts,
            "hardcodedCandidates": len(hardcoded),
            "infoPlistStrings": len(info_plist),
            "interfaceBuilderStrings": len(_inventory_interface_builder(root, source_roots)),
            "nonTargetSources": len(non_target_sources),
            "unresolvedDynamicCalls": len(unresolved),
        },
        "unresolvedDynamicCalls": unresolved,
    }
    return document


def validate_manifest(document: dict[str, Any]) -> None:
    if (
        type(document.get("schemaVersion")) is not int
        or document["schemaVersion"] != SCHEMA_VERSION
    ):
        raise ManifestError(f"Unsupported manifest schemaVersion {document.get('schemaVersion')!r}")
    required_fields = {
        "activeKeys": list,
        "catalog": str,
        "catalogOnly": list,
        "computedFallbacks": list,
        "directLookups": list,
        "domainReservedKeys": list,
        "dynamicDomains": list,
        "excludedPaths": list,
        "fallbackConflictQuarantine": list,
        "hardcodedCandidates": list,
        "infoPlist": list,
        "interfaceBuilder": list,
        "legacyMarkupQuarantine": list,
        "nonTargetSources": list,
        "schemaVersion": int,
        "sourceLanguage": str,
        "unresolvedDynamicCalls": list,
        "summary": dict,
    }
    missing_fields = sorted(set(required_fields) - set(document))
    unknown_fields = sorted(set(document) - set(required_fields))
    if missing_fields or unknown_fields:
        raise ManifestError(
            "Manifest top-level fields do not match schema: "
            f"missing {missing_fields}, unknown {unknown_fields}"
        )
    for field, expected_type in required_fields.items():
        value = document.get(field)
        valid_type = (
            type(value) is int
            if expected_type is int
            else isinstance(value, expected_type)
        )
        if not valid_type:
            raise ManifestError(
                f"Manifest field {field!r} must be {expected_type.__name__}"
            )
    if not document["catalog"].strip():
        raise ManifestError("Manifest catalog path must be non-empty")
    if document["sourceLanguage"] != "en":
        raise ManifestError("Manifest sourceLanguage must be 'en'")

    allowed_apis = {"legacy", "text", "format", "plural", "attributedMarkdown"}
    allowed_origins = {
        "generatedPattern",
        "sourceLiteral",
        "typedCallsite",
        "typedDynamic",
        "typedResolved",
    }
    allowed_surfaces = {"app", "push"}

    def require_nonempty_string(value: Any, context: str) -> None:
        if not isinstance(value, str) or not value.strip():
            raise ManifestError(f"Manifest {context} must be a non-empty string")

    def validate_string_list(
        value: Any,
        context: str,
        *,
        allowed: set[str] | None = None,
        nonempty: bool = False,
    ) -> list[str]:
        if not isinstance(value, list) or not all(
            isinstance(item, str) and item for item in value
        ):
            raise ManifestError(f"Manifest {context} must be a string array")
        if nonempty and not value:
            raise ManifestError(f"Manifest {context} must not be empty")
        if value != sorted(set(value)):
            raise ManifestError(f"Manifest {context} must be sorted and unique")
        if allowed is not None and not set(value) <= allowed:
            raise ManifestError(f"Manifest {context} contains an unsupported value")
        return value

    def validate_signature(value: Any, context: str) -> None:
        if not isinstance(value, list):
            raise ManifestError(f"Manifest {context} must be an array")
        required = {"argument", "conversion", "flags", "precision", "width"}
        for index, item in enumerate(value):
            item_context = f"{context}[{index}]"
            if not isinstance(item, dict):
                raise ManifestError(f"Manifest {item_context} must be an object")
            if set(item) not in (required, required | {"role"}):
                raise ManifestError(
                    f"Manifest {item_context} has invalid format-signature fields"
                )
            if type(item["argument"]) is not int or item["argument"] < 1:
                raise ManifestError(
                    f"Manifest {item_context}.argument must be a positive integer"
                )
            require_nonempty_string(item["conversion"], f"{item_context}.conversion")
            if not isinstance(item["flags"], str):
                raise ManifestError(f"Manifest {item_context}.flags must be a string")
            for field in ("precision", "width"):
                if item[field] is not None and not isinstance(item[field], str):
                    raise ManifestError(
                        f"Manifest {item_context}.{field} must be a string or null"
                    )
            if item.get("role") not in (None, "width", "precision"):
                raise ManifestError(f"Manifest {item_context}.role is invalid")

    def validate_keyed_entries(name: str) -> tuple[list[dict[str, Any]], set[str]]:
        entries = document[name]
        keys: list[str] = []
        for index, entry in enumerate(entries):
            if not isinstance(entry, dict):
                raise ManifestError(f"Manifest {name}[{index}] must be an object")
            require_nonempty_string(entry.get("key"), f"{name}[{index}].key")
            keys.append(entry["key"])
        if keys != sorted(keys) or len(keys) != len(set(keys)):
            raise ManifestError(f"Manifest {name} keys must be sorted and unique")
        return entries, set(keys)

    active_entries, active_keys = validate_keyed_entries("activeKeys")
    for index, entry in enumerate(active_entries):
        context = f"activeKeys[{index}]"
        required = {
            "apis",
            "callsites",
            "english",
            "fallbacks",
            "formatSignature",
            "key",
            "origins",
            "surfaces",
        }
        if set(entry) != required:
            raise ManifestError(f"Manifest {context} has invalid fields")
        apis = validate_string_list(
            entry["apis"], f"{context}.apis", allowed=allowed_apis, nonempty=True
        )
        validate_string_list(entry["fallbacks"], f"{context}.fallbacks")
        origins = validate_string_list(
            entry["origins"],
            f"{context}.origins",
            allowed=allowed_origins,
            nonempty=True,
        )
        surfaces = validate_string_list(
            entry["surfaces"],
            f"{context}.surfaces",
            allowed=allowed_surfaces,
            nonempty=True,
        )
        validate_signature(entry["formatSignature"], f"{context}.formatSignature")
        english = entry["english"]
        if not isinstance(english, dict) or set(english) != {"fallbackStatus", "value"}:
            raise ManifestError(f"Manifest {context}.english has invalid fields")
        if english["fallbackStatus"] not in {
            "catalogWins",
            "computedFallback",
            "conflictingFallbacks",
            "consistent",
            "missingFallback",
            "override",
            "singleFallback",
        }:
            raise ManifestError(f"Manifest {context}.english fallbackStatus is invalid")
        if english["value"] is not None and not isinstance(english["value"], str):
            raise ManifestError(f"Manifest {context}.english.value must be string or null")
        callsites = entry["callsites"]
        if not isinstance(callsites, list) or not callsites:
            raise ManifestError(f"Manifest {context}.callsites must not be empty")
        callsite_apis: set[str] = set()
        callsite_origins: set[str] = set()
        callsite_surfaces: set[str] = set()
        callsite_fallbacks: set[str] = set()
        for call_index, callsite in enumerate(callsites):
            call_context = f"{context}.callsites[{call_index}]"
            required_callsite = {
                "api",
                "argumentCount",
                "fallback",
                "formatSignature",
                "line",
                "origin",
                "path",
                "surfaces",
                "symbol",
                "typeSafety",
            }
            allowed_callsite = required_callsite | {"domain", "pluralCountArgument"}
            if not isinstance(callsite, dict) or not required_callsite <= set(callsite):
                raise ManifestError(f"Manifest {call_context} has missing fields")
            if not set(callsite) <= allowed_callsite:
                raise ManifestError(f"Manifest {call_context} has unknown fields")
            if callsite["api"] not in allowed_apis:
                raise ManifestError(f"Manifest {call_context}.api is invalid")
            argument_count = callsite["argumentCount"]
            if argument_count is not None and (
                type(argument_count) is not int or argument_count < 0
            ):
                raise ManifestError(
                    f"Manifest {call_context}.argumentCount must be non-negative or null"
                )
            fallback = callsite["fallback"]
            if fallback is not None and not isinstance(fallback, str):
                raise ManifestError(f"Manifest {call_context}.fallback is invalid")
            validate_signature(
                callsite["formatSignature"], f"{call_context}.formatSignature"
            )
            if type(callsite["line"]) is not int or callsite["line"] < 1:
                raise ManifestError(f"Manifest {call_context}.line must be positive")
            if callsite["origin"] not in allowed_origins:
                raise ManifestError(f"Manifest {call_context}.origin is invalid")
            require_nonempty_string(callsite["path"], f"{call_context}.path")
            call_surfaces = validate_string_list(
                callsite["surfaces"],
                f"{call_context}.surfaces",
                allowed=allowed_surfaces,
                nonempty=True,
            )
            if callsite["symbol"] is not None and not isinstance(callsite["symbol"], str):
                raise ManifestError(f"Manifest {call_context}.symbol is invalid")
            if callsite["typeSafety"] not in {"typed", "typeUnchecked"}:
                raise ManifestError(f"Manifest {call_context}.typeSafety is invalid")
            if "domain" in callsite:
                require_nonempty_string(callsite["domain"], f"{call_context}.domain")
            has_plural_count_argument = "pluralCountArgument" in callsite
            if callsite["api"] == "plural" and (
                not has_plural_count_argument
                or callsite["pluralCountArgument"] is not True
            ):
                raise ManifestError(
                    f"Manifest {call_context}.pluralCountArgument must be true for plural calls"
                )
            if callsite["api"] != "plural" and has_plural_count_argument:
                raise ManifestError(
                    f"Manifest {call_context}.pluralCountArgument is only valid for plural calls"
                )
            callsite_apis.add(callsite["api"])
            callsite_origins.add(callsite["origin"])
            callsite_surfaces.update(call_surfaces)
            if isinstance(fallback, str) and fallback:
                callsite_fallbacks.add(fallback)
        if set(apis) != callsite_apis:
            raise ManifestError(f"Manifest {context}.apis does not match callsites")
        if set(origins) != callsite_origins:
            raise ManifestError(f"Manifest {context}.origins does not match callsites")
        if set(surfaces) != callsite_surfaces:
            raise ManifestError(f"Manifest {context}.surfaces does not match callsites")
        if set(entry["fallbacks"]) != callsite_fallbacks:
            raise ManifestError(f"Manifest {context}.fallbacks does not match callsites")

    reserved_entries, reserved_keys = validate_keyed_entries("domainReservedKeys")
    for index, entry in enumerate(reserved_entries):
        context = f"domainReservedKeys[{index}]"
        if set(entry) != {
            "apis",
            "domains",
            "fallbacks",
            "formatSignatures",
            "key",
            "surfaces",
        }:
            raise ManifestError(f"Manifest {context} has invalid fields")
        validate_string_list(
            entry["apis"], f"{context}.apis", allowed=allowed_apis, nonempty=True
        )
        validate_string_list(entry["domains"], f"{context}.domains", nonempty=True)
        validate_string_list(entry["fallbacks"], f"{context}.fallbacks")
        validate_string_list(
            entry["surfaces"],
            f"{context}.surfaces",
            allowed=allowed_surfaces,
            nonempty=True,
        )
        if not isinstance(entry["formatSignatures"], list) or not entry[
            "formatSignatures"
        ]:
            raise ManifestError(
                f"Manifest {context}.formatSignatures must not be empty"
            )
        for signature_index, signature in enumerate(entry["formatSignatures"]):
            validate_signature(
                signature, f"{context}.formatSignatures[{signature_index}]"
            )
    if active_keys & reserved_keys:
        raise ManifestError("Manifest active/reserved key partition overlaps")
    reserved_keys_by_domain: dict[str, set[str]] = defaultdict(set)
    for entry in reserved_entries:
        for domain_name in entry["domains"]:
            reserved_keys_by_domain[domain_name].add(entry["key"])

    catalog_only_entries, catalog_only_keys = validate_keyed_entries("catalogOnly")
    for index, entry in enumerate(catalog_only_entries):
        if set(entry) != {"classification", "key"} or entry["classification"] not in {
            "interfaceBuilder",
            "legacyMarkup",
            "retainedLegacyPlural",
            "reviewCandidate",
        }:
            raise ManifestError(f"Manifest catalogOnly[{index}] is invalid")
    if active_keys & catalog_only_keys:
        raise ManifestError("Manifest active/catalog-only key partition overlaps")
    if not reserved_keys <= catalog_only_keys:
        raise ManifestError("Manifest reserved keys must remain catalog-only")

    dynamic_domains = document["dynamicDomains"]
    dynamic_names: list[str] = []
    for index, domain in enumerate(dynamic_domains):
        context = f"dynamicDomains[{index}]"
        if not isinstance(domain, dict):
            raise ManifestError(f"Manifest {context} must be an object")
        require_nonempty_string(domain.get("name"), f"{context}.name")
        dynamic_names.append(domain["name"])
        if domain.get("kind") not in {"bounded", "typed"}:
            raise ManifestError(f"Manifest {context}.kind is invalid")
        validate_string_list(domain.get("paths"), f"{context}.paths", nonempty=True)
        if not isinstance(domain.get("patterns"), list) or not domain["patterns"]:
            raise ManifestError(f"Manifest {context}.patterns must not be empty")
        for pattern_index, pattern in enumerate(domain["patterns"]):
            if not isinstance(pattern, dict) or not pattern:
                raise ManifestError(
                    f"Manifest {context}.patterns[{pattern_index}] must be an object"
                )
        expanded = domain.get("expandedKeys")
        if not isinstance(expanded, list):
            raise ManifestError(f"Manifest {context}.expandedKeys must be an array")
        expanded_keys: list[str] = []
        for expanded_index, item in enumerate(expanded):
            item_context = f"{context}.expandedKeys[{expanded_index}]"
            if not isinstance(item, dict) or set(item) != {"apis", "key"}:
                raise ManifestError(f"Manifest {item_context} is invalid")
            require_nonempty_string(item["key"], f"{item_context}.key")
            validate_string_list(
                item["apis"],
                f"{item_context}.apis",
                allowed=allowed_apis,
                nonempty=True,
            )
            expanded_keys.append(item["key"])
        if expanded_keys != sorted(set(expanded_keys)):
            raise ManifestError(f"Manifest {context}.expandedKeys must be sorted and unique")
        if not set(expanded_keys) <= active_keys:
            raise ManifestError(f"Manifest {context}.expandedKeys must be active")
        if domain["kind"] == "typed":
            for field in ("enum", "declaredKeys", "facadeCalls", "casePolicy"):
                if field not in domain:
                    raise ManifestError(f"Manifest {context}.{field} is required")
            require_nonempty_string(domain["enum"], f"{context}.enum")
            if domain["casePolicy"] not in {"allCasesRequired", "conservative"}:
                raise ManifestError(f"Manifest {context}.casePolicy is invalid")
            declared_keys: list[str] = []
            for declared_index, item in enumerate(domain["declaredKeys"]):
                item_context = f"{context}.declaredKeys[{declared_index}]"
                if not isinstance(item, dict) or set(item) != {"apis", "key"}:
                    raise ManifestError(f"Manifest {item_context} is invalid")
                require_nonempty_string(item["key"], f"{item_context}.key")
                validate_string_list(
                    item["apis"],
                    f"{item_context}.apis",
                    allowed=allowed_apis,
                    nonempty=True,
                )
                declared_keys.append(item["key"])
            if declared_keys != sorted(set(declared_keys)):
                raise ManifestError(
                    f"Manifest {context}.declaredKeys must be sorted and unique"
                )
            declared_key_set = set(declared_keys)
            domain_reserved_keys = reserved_keys_by_domain.get(domain["name"], set())
            if (
                not declared_key_set <= (active_keys | reserved_keys)
                or not (declared_key_set & active_keys) <= set(expanded_keys)
                or not domain_reserved_keys <= declared_key_set
            ):
                raise ManifestError(
                    f"Manifest {context}.declaredKeys do not match active/reserved keys"
                )
            if not isinstance(domain["facadeCalls"], list):
                raise ManifestError(f"Manifest {context}.facadeCalls must be an array")
            for facade_index, facade in enumerate(domain["facadeCalls"]):
                facade_context = f"{context}.facadeCalls[{facade_index}]"
                if not isinstance(facade, dict) or not {"callee", "paths"} <= set(facade):
                    raise ManifestError(f"Manifest {facade_context} is invalid")
                if not set(facade) <= {"callee", "dynamicCases", "paths"}:
                    raise ManifestError(f"Manifest {facade_context} has unknown fields")
                require_nonempty_string(facade["callee"], f"{facade_context}.callee")
                validate_string_list(
                    facade["paths"], f"{facade_context}.paths", nonempty=True
                )
                if "dynamicCases" in facade:
                    validate_string_list(
                        facade["dynamicCases"],
                        f"{facade_context}.dynamicCases",
                        nonempty=True,
                    )
    if dynamic_names != sorted(set(dynamic_names)):
        raise ManifestError("Manifest dynamicDomains must be sorted and unique")

    simple_keyed_shapes = {
        "computedFallbacks": {"expression", "key", "reason"},
        "fallbackConflictQuarantine": {"key", "reason"},
        "legacyMarkupQuarantine": {"key", "status"},
    }
    for name, fields in simple_keyed_shapes.items():
        entries, _ = validate_keyed_entries(name)
        for index, entry in enumerate(entries):
            if set(entry) != fields:
                raise ManifestError(f"Manifest {name}[{index}] has invalid fields")
            for field in fields - {"key", "status"}:
                require_nonempty_string(entry[field], f"{name}[{index}].{field}")
            if name == "legacyMarkupQuarantine" and entry["status"] not in {
                "active",
                "catalogOnly",
            }:
                raise ManifestError(f"Manifest {name}[{index}].status is invalid")

    validate_string_list(document["excludedPaths"], "excludedPaths")

    non_target_paths: list[str] = []
    for index, entry in enumerate(document["nonTargetSources"]):
        context = f"nonTargetSources[{index}]"
        if not isinstance(entry, dict) or set(entry) != {"path", "reason"}:
            raise ManifestError(f"Manifest {context} has invalid fields")
        require_nonempty_string(entry["path"], f"{context}.path")
        require_nonempty_string(entry["reason"], f"{context}.reason")
        non_target_paths.append(entry["path"])
    if non_target_paths != sorted(set(non_target_paths)):
        raise ManifestError("Manifest nonTargetSources must be sorted and unique")

    inventory_shapes = {
        "hardcodedCandidates": {"line", "path", "sink", "value"},
        "infoPlist": {"key", "path", "value"},
    }
    for name, fields in inventory_shapes.items():
        for index, entry in enumerate(document[name]):
            context = f"{name}[{index}]"
            if not isinstance(entry, dict) or set(entry) != fields:
                raise ManifestError(f"Manifest {context} has invalid fields")
            for field in fields - {"line"}:
                require_nonempty_string(entry[field], f"{context}.{field}")
            if "line" in fields and (
                type(entry["line"]) is not int or entry["line"] < 1
            ):
                raise ManifestError(f"Manifest {context}.line must be positive")
    interface_builder_shapes = (
        {"attribute", "objectID", "path", "value"},
        {"key", "locale", "path", "value"},
    )
    for index, entry in enumerate(document["interfaceBuilder"]):
        context = f"interfaceBuilder[{index}]"
        if not isinstance(entry, dict) or set(entry) not in interface_builder_shapes:
            raise ManifestError(f"Manifest {context} has invalid fields")
        for field, value in entry.items():
            require_nonempty_string(value, f"{context}.{field}")

    for name, fields in {
        "directLookups": {"api", "line", "path", "symbol"},
        "unresolvedDynamicCalls": {
            "api",
            "expression",
            "line",
            "path",
            "symbol",
        },
    }.items():
        for index, entry in enumerate(document[name]):
            context = f"{name}[{index}]"
            if not isinstance(entry, dict) or set(entry) != fields:
                raise ManifestError(f"Manifest {context} has invalid fields")
            require_nonempty_string(entry["api"], f"{context}.api")
            require_nonempty_string(entry["path"], f"{context}.path")
            if "expression" in fields:
                require_nonempty_string(entry["expression"], f"{context}.expression")
            if type(entry["line"]) is not int or entry["line"] < 1:
                raise ManifestError(f"Manifest {context}.line must be positive")
            if entry["symbol"] is not None and not isinstance(entry["symbol"], str):
                raise ManifestError(f"Manifest {context}.symbol is invalid")

    expected_summary = {
        "activeKeys": len(active_entries),
        "activeWithoutEnglish": sum(
            1
            for entry in active_entries
            if not isinstance(entry["english"]["value"], str)
            or not entry["english"]["value"].strip()
        ),
        "catalogKeys": len(active_entries) + len(catalog_only_entries),
        "catalogOnlyKeys": len(catalog_only_entries),
        "computedFallbacks": len(document["computedFallbacks"]),
        "directLookups": len(document["directLookups"]),
        "domainReservedKeys": len(reserved_entries),
        "dynamicDomains": len(dynamic_domains),
        "excludedPaths": len(document["excludedPaths"]),
        "fallbackConflicts": len(document["fallbackConflictQuarantine"]),
        "hardcodedCandidates": len(document["hardcodedCandidates"]),
        "infoPlistStrings": len(document["infoPlist"]),
        "interfaceBuilderStrings": len(document["interfaceBuilder"]),
        "nonTargetSources": len(document["nonTargetSources"]),
        "unresolvedDynamicCalls": len(document["unresolvedDynamicCalls"]),
    }
    if set(document["summary"]) != set(expected_summary):
        raise ManifestError("Manifest summary fields do not match schema")
    for field, expected in expected_summary.items():
        actual = document["summary"].get(field)
        if type(actual) is not int or actual != expected:
            raise ManifestError(
                f"Manifest summary {field} is {actual!r}, "
                f"expected {expected}"
            )

    unresolved = document.get("unresolvedDynamicCalls", [])
    if unresolved:
        first = unresolved[0]
        raise ManifestError(
            "Manifest has unresolved dynamic localization calls; first: "
            f"{first.get('path')}:{first.get('line')} ({first.get('expression')})"
        )
    direct = document.get("directLookups", [])
    if direct:
        first = direct[0]
        raise ManifestError(
            "Manifest has direct localization lookups outside the core; first: "
            f"{first.get('path')}:{first.get('line')} ({first.get('api')})"
        )
    missing = document.get("summary", {}).get("activeWithoutEnglish", 0)
    if missing:
        raise ManifestError(f"Manifest has {missing} active keys without English")


def render_manifest(document: dict[str, Any]) -> str:
    return json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n"


def load_config(path: Path) -> dict[str, Any]:
    def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise ManifestError(f"Duplicate JSON key {key!r} in {path}")
            result[key] = value
        return result

    try:
        document = json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=reject_duplicate_keys,
        )
    except ManifestError:
        raise
    except (OSError, json.JSONDecodeError) as error:
        raise ManifestError(f"Could not read manifest config {path}: {error}") from error
    if not isinstance(document, dict):
        raise ManifestError(f"Manifest config {path} must be a JSON object")
    return document


def _report(document: dict[str, Any]) -> dict[str, Any]:
    return {
        **document["summary"],
        "missingEnglishKeys": [
            entry["key"] for entry in document["activeKeys"] if entry["english"]["value"] is None
        ],
        "unresolvedDynamicCalls": document["unresolvedDynamicCalls"],
        "directLookups": document["directLookups"],
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("generate", "check", "report"))
    parser.add_argument("--root", type=Path, default=REPO_ROOT)
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG_PATH)
    arguments = parser.parse_args(argv)

    try:
        root = arguments.root.resolve()
        config_path = arguments.config
        if not config_path.is_absolute():
            config_path = root / config_path
        config = load_config(config_path)
        document = build_manifest(root, config)
        rendered = render_manifest(document)
        manifest_path = root / config.get("manifest", DEFAULT_MANIFEST_PATH)

        if arguments.command == "generate":
            manifest_path.parent.mkdir(parents=True, exist_ok=True)
            manifest_path.write_text(rendered, encoding="utf-8")
        elif arguments.command == "check":
            try:
                checked_in = manifest_path.read_text(encoding="utf-8")
            except OSError as error:
                raise ManifestError(f"Could not read manifest {manifest_path}: {error}") from error
            if checked_in != rendered:
                raise ManifestError(
                    f"Localization manifest is stale; run {Path(__file__).name} generate"
                )
            validate_manifest(document)

        print(json.dumps(_report(document), ensure_ascii=False, indent=2, sort_keys=True))
    except (ManifestError, CatalogError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
