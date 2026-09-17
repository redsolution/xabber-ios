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


def _hardcoded_candidates(
    source: str, source_without_comments: str, path: str
) -> list[dict[str, Any]]:
    candidates: list[dict[str, Any]] = []
    for token in _swift_string_tokens(source_without_comments):
        prefix = source_without_comments[max(0, token["start"] - 160) : token["start"]]
        suffix = source_without_comments[token["end"] : token["end"] + 80]
        if re.match(r"\s*\.localizeString\s*\(", suffix):
            continue
        sink_match = re.search(
            r"\.(accessibilityLabel|accessibilityHint|accessibilityValue|text|title|placeholder)"
            r"\s*=\s*$",
            prefix,
        )
        sink: str | None = sink_match.group(1) if sink_match else None
        if sink is None:
            named_match = re.search(
                r"\b(accessibilityLabel|accessibilityHint|accessibilityValue|"
                r"title|message|subtitle|placeholder|text)\s*:\s*$",
                prefix,
            )
            sink = named_match.group(1) if named_match else None
        if sink is None and re.search(r"\bsetTitle\s*\(\s*$", prefix):
            sink = "setTitle"
        if sink is None and re.search(r"\.makeToast\s*\(\s*$", prefix):
            sink = "makeToast"
        if sink is None and re.search(
            r"\b(?:NSAttributedString|NSMutableAttributedString|AttributedString)\s*\(\s*"
            r"(?:string\s*:\s*)?$",
            prefix,
        ):
            sink = "attributedString"
        if sink is None:
            continue
        if re.search(r"\b(?:logger|log|NSLog|os_log)\w*\s*\([^)]*$", prefix, re.I):
            continue
        value = token["value"]
        if not value.strip() or value.startswith("%@"):
            continue
        candidates.append(
            {
                "line": _line_number(source, token["start"]),
                "path": path,
                "sink": sink,
                "value": value,
            }
        )
    return sorted(candidates, key=lambda item: (item["sink"], item["value"], item["line"]))


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


def _inventory_info_plist(root: Path, source_roots: Iterable[str]) -> list[dict[str, Any]]:
    entries: list[dict[str, Any]] = []
    for source_root in source_roots:
        directory = root / source_root
        if not directory.is_dir():
            continue
        for path in sorted(directory.rglob("*.plist")):
            result = subprocess.run(
                ["/usr/bin/plutil", "-convert", "json", "-o", "-", str(path)],
                check=False,
                capture_output=True,
                text=True,
            )
            if result.returncode != 0:
                continue
            try:
                document = json.loads(result.stdout)
            except json.JSONDecodeError:
                continue
            if not isinstance(document, dict):
                continue
            for key, value in sorted(document.items()):
                visible = key in INFO_PLIST_VISIBLE_KEYS or key.endswith("UsageDescription")
                if visible and isinstance(value, str) and value.strip():
                    entries.append(
                        {
                            "key": key,
                            "path": path.relative_to(root).as_posix(),
                            "value": value,
                        }
                    )
    return entries


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


def build_manifest(root: Path, config: dict[str, Any]) -> dict[str, Any]:
    source_roots = config.get("sourceRoots", ["xabber", "xabber-push-extension"])
    missing_source_roots = [
        source_root for source_root in source_roots if not (root / source_root).is_dir()
    ]
    if missing_source_roots:
        raise ManifestError(
            f"Configured localization source root is missing: {missing_source_roots[0]}"
        )
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
    for source_root in source_roots:
        directory = root / source_root
        for path in sorted(directory.rglob("*.swift")):
            relative = path.relative_to(root).as_posix()
            if any(fnmatch.fnmatch(relative, pattern) for pattern in excluded_paths):
                continue
            scanned_source_paths.append(relative)
            result = scan_swift_source(path.read_text(encoding="utf-8"), relative, config)
            all_calls.extend(result["calls"])
            dynamic_matches.extend(result["dynamicMatches"])
            unresolved.extend(result["unresolved"])
            direct_lookups.extend(result["directLookups"])
            hardcoded.extend(result["hardcodedCandidates"])

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
    hardcoded = _deduplicate_dicts(hardcoded)
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
        "infoPlist": _inventory_info_plist(root, source_roots),
        "interfaceBuilder": _inventory_interface_builder(root, source_roots),
        "legacyMarkupQuarantine": legacy_markup_quarantine,
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
            "infoPlistStrings": len(_inventory_info_plist(root, source_roots)),
            "interfaceBuilderStrings": len(_inventory_interface_builder(root, source_roots)),
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
