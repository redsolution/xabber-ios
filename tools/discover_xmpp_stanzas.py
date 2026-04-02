#!/usr/bin/env python3

from __future__ import annotations

import json
import re
from collections import Counter, defaultdict
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
DOCS_ROOT = REPO_ROOT / "docs" / "xmpp"
SCAN_ROOTS = [
    REPO_ROOT / "xabber" / "xmpp",
    REPO_ROOT / "xabber" / "models" / "account" / "delegates",
    REPO_ROOT / "xabber" / "models" / "account" / "extensions",
    REPO_ROOT / "xabber" / "utils" / "XMPPUtils",
]

FUNCTION_RE = re.compile(
    r"^\s*(?:@\w+\s+)*(?:(?:override|public|private|internal|open|fileprivate|final|class|static|convenience|required|mutating|nonmutating)\s+)*func\s+([A-Za-z_][A-Za-z0-9_]*)"
)
INIT_RE = re.compile(
    r"^\s*(?:@\w+\s+)*(?:(?:override|public|private|internal|open|fileprivate|final|convenience|required)\s+)*init\b"
)
NAMESPACE_RE = re.compile(
    r"(urn:[A-Za-z0-9:._-]+|jabber:[A-Za-z0-9:._#-]+|https?://[A-Za-z0-9./:_#-]+|eu\.siacs\.conversations\.axolotl)"
)
ELEMENT_CREATE_RE = re.compile(
    r'DDXMLElement(?:\.element\(withName:|\(name:)\s*"([^"]+)"'
)
ELEMENT_READ_RE = re.compile(
    r'element[s]?\(forName:\s*"([^"]+)"'
)
ATTRIBUTE_RE = re.compile(
    r'(?:addAttribute\(withName:|attributeStringValue\(forName:|attributeForName:\s*)"([^"]+)"'
)
STANZA_ACTIVITY_RE = re.compile(
    r"XMPPMessage\(|XMPPIQ\(|XMPPPresence\(|DDXMLElement\(|element\(forName:|elements\(forName:|attributeStringValue|setXmlns|addChild\(|xmlns\(\)|presenceType|iqType|messageType"
)


def is_namespace_like(value: str) -> bool:
    return (
        value == "eu.siacs.conversations.axolotl"
        or value.startswith("urn:")
        or value.startswith("jabber:")
        or value.startswith("http://jabber.org/protocol/")
        or value.startswith("http://xabber.com/protocol/")
        or value.startswith("https://xabber.com/protocol/")
        or value.startswith("http://www.facebook.com/xmpp/")
        or value.startswith("urn:ietf:params:xml:ns:xmpp-")
    )


def relpath(path: Path) -> str:
    return str(path.relative_to(REPO_ROOT))


def slug(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")


def infer_owner(path: Path) -> str:
    relative = path.relative_to(REPO_ROOT / "xabber")
    parts = relative.parts
    if parts[0] == "xmpp" and len(parts) > 1:
        return parts[1]
    if "delegates" in parts:
        return "account-delegates"
    if "extensions" in parts:
        return "account-extensions"
    if "XMPPUtils" in parts:
        return "xmpp-utils"
    return parts[0]


def infer_top_level(signature_line: str, body: str) -> str:
    text = signature_line + "\n" + body
    if "XMPPMessage(" in text or "XMPPMessage " in text or "message: XMPPMessage" in text or "withMessage message" in text:
        return "message"
    if "XMPPIQ(" in text or "iq: XMPPIQ" in text or "withIQ iq" in text:
        return "iq"
    if "XMPPPresence(" in text or "presence: XMPPPresence" in text or "withPresence presence" in text:
        return "presence"
    if "stream:features" in text or "onStreamPrepared" in text or "features.element(forName:" in text:
        return "stream"
    return "unknown"


def infer_direction(body: str, producers: bool, consumers: bool) -> list[str]:
    directions = []
    send_markers = ["xmppStream.send(", "stream.send(", "return XMPPMessage(", "return XMPPIQ(", "return XMPPPresence("]
    recv_markers = ["read(with", "element(forName:", "elements(forName:", "attributeStringValue", "xmlns()", "presenceType", "iqType", "messageType"]
    if producers or any(marker in body for marker in send_markers):
        directions.append("send")
    if consumers or any(marker in body for marker in recv_markers):
        directions.append("receive")
    if not directions:
        directions.append("both" if producers and consumers else "receive" if consumers else "send" if producers else "unknown")
    return sorted(set(directions))


def infer_completeness(top_level: str, body: str, namespaces: list[str]) -> str:
    manual_markers = [
        "DDXMLElement(name: variable",
        "DDXMLElement(name: name",
        "child: element",
        "child: query",
        "addChild(child",
        "addChild(element)",
    ]
    partial_markers = [
        "getPrimaryNamespace()",
        "setXmlns(getPrimaryNamespace())",
        "xmlns: getPrimaryNamespace()",
        "addChild(",
        "compactMap",
        ".copy()",
    ]
    if top_level == "unknown":
        return "manual-review"
    if any(marker in body for marker in manual_markers):
        return "manual-review"
    if not namespaces or any(marker in body for marker in partial_markers):
        return "partial"
    return "complete"


def find_evidence(lines: list[str], start_line: int) -> list[dict]:
    evidence = []
    for offset, line in enumerate(lines):
        if STANZA_ACTIVITY_RE.search(line):
            evidence.append({"line": start_line + offset, "code": line.strip()})
    return evidence[:20]


def extract_function_blocks(path: Path) -> list[dict]:
    text = path.read_text(encoding="utf-8", errors="ignore")
    lines = text.splitlines()
    blocks = []
    i = 0
    while i < len(lines):
        line = lines[i]
        function_match = FUNCTION_RE.match(line)
        init_match = INIT_RE.match(line)
        if not function_match and not init_match:
            i += 1
            continue
        symbol = function_match.group(1) if function_match else "init"
        start_line = i + 1
        brace_depth = 0
        started = False
        block_lines = [line]
        j = i
        while j < len(lines):
            current = lines[j]
            if j != i:
                block_lines.append(current)
            brace_depth += current.count("{")
            if current.count("{") > 0:
                started = True
            brace_depth -= current.count("}")
            if started and brace_depth <= 0:
                break
            j += 1
        blocks.append(
            {
                "symbol": symbol,
                "signature_line": line,
                "start_line": start_line,
                "end_line": min(j + 1, len(lines)),
                "body_lines": block_lines,
                "body": "\n".join(block_lines),
            }
        )
        i = max(j + 1, i + 1)
    return blocks


def build_candidate(path: Path, block: dict) -> dict | None:
    body = block["body"]
    if not STANZA_ACTIVITY_RE.search(body):
        return None
    producers = any(token in body for token in ["XMPPMessage(", "XMPPIQ(", "XMPPPresence(", "DDXMLElement("])
    consumers = any(token in body for token in ["element(forName:", "elements(forName:", "attributeStringValue", "xmlns()", "presenceType", "iqType", "messageType"])
    namespaces = sorted({value for value in NAMESPACE_RE.findall(body) if is_namespace_like(value)})
    created_elements = sorted(set(ELEMENT_CREATE_RE.findall(body)))
    read_elements = sorted(set(ELEMENT_READ_RE.findall(body)))
    attributes = sorted(set(ATTRIBUTE_RE.findall(body)))
    top_level = infer_top_level(block["signature_line"], body)
    direction = infer_direction(body, producers, consumers)
    completeness = infer_completeness(top_level, body, namespaces)
    evidence = find_evidence(block["body_lines"], block["start_line"])
    owner = infer_owner(path)
    relative = relpath(path)
    stanza_family = created_elements[0] if created_elements else read_elements[0] if read_elements else top_level
    candidate_id = slug(f"{owner}-{block['symbol']}-{stanza_family}-{top_level}")
    return {
        "id": candidate_id,
        "symbol": block["symbol"],
        "owner": owner,
        "file": relative,
        "directory": str(Path(relative).parent),
        "start_line": block["start_line"],
        "end_line": block["end_line"],
        "top_level": top_level,
        "direction": direction,
        "completeness": completeness,
        "produces_stanza": producers,
        "consumes_stanza": consumers,
        "namespaces": namespaces,
        "created_elements": created_elements,
        "read_elements": read_elements,
        "attributes": attributes,
        "stanza_family_hint": stanza_family,
        "evidence": evidence,
    }


def scan() -> dict:
    files = []
    candidates = []
    active_directories = set()
    scanned_roots = []
    for root in SCAN_ROOTS:
        scanned_roots.append(relpath(root))
        for path in sorted(root.rglob("*.swift")):
            relative = relpath(path)
            files.append(relative)
            blocks = extract_function_blocks(path)
            for block in blocks:
                candidate = build_candidate(path, block)
                if candidate:
                    candidates.append(candidate)
                    if candidate["directory"].startswith("xabber/xmpp/"):
                        active_directories.add(candidate["directory"])

    candidates.sort(key=lambda item: (item["file"], item["start_line"], item["symbol"]))
    owner_counts = Counter(candidate["owner"] for candidate in candidates)
    completeness_counts = Counter(candidate["completeness"] for candidate in candidates)
    top_level_counts = Counter(candidate["top_level"] for candidate in candidates)
    manual_review = [candidate for candidate in candidates if candidate["completeness"] in {"partial", "manual-review"}]

    return {
        "version": 1,
        "generated_from": "tools/discover_xmpp_stanzas.py",
        "scan_roots": scanned_roots,
        "files_scanned": files,
        "files_with_activity": sorted({candidate["file"] for candidate in candidates}),
        "candidate_count": len(candidates),
        "owner_counts": dict(owner_counts),
        "top_level_counts": dict(top_level_counts),
        "completeness_counts": dict(completeness_counts),
        "active_directories": sorted(active_directories),
        "candidates": candidates,
        "manual_review_required": manual_review,
    }


def render_report(discovery: dict) -> str:
    lines = [
        "# XMPP Stanza Discovery Report",
        "",
        f"- Generated by: `{discovery['generated_from']}`",
        f"- Scan roots: {', '.join(f'`{root}`' for root in discovery['scan_roots'])}",
        f"- Files scanned: `{len(discovery['files_scanned'])}`",
        f"- Files with stanza activity: `{len(discovery['files_with_activity'])}`",
        f"- Extracted candidates: `{discovery['candidate_count']}`",
        "",
        "## Summary",
        "",
        f"- Top-level counts: {', '.join(f'`{key}`={value}' for key, value in sorted(discovery['top_level_counts'].items()))}",
        f"- Completeness counts: {', '.join(f'`{key}`={value}' for key, value in sorted(discovery['completeness_counts'].items()))}",
        "",
        "## Active Directories",
        "",
    ]
    lines.extend(f"- `{value}`" for value in discovery["active_directories"])
    lines.extend(["", "## Manual Review Required", ""])
    if not discovery["manual_review_required"]:
        lines.append("- `none`")
    else:
        for candidate in discovery["manual_review_required"]:
            lines.append(
                f"- `{candidate['file']}:{candidate['start_line']}` `{candidate['symbol']}` "
                f"top-level=`{candidate['top_level']}` completeness=`{candidate['completeness']}` "
                f"namespaces={', '.join(f'`{ns}`' for ns in candidate['namespaces']) if candidate['namespaces'] else '`none`'}"
            )
    lines.extend(["", "## Candidate Sample", ""])
    for candidate in discovery["candidates"][:40]:
        lines.append(
            f"- `{candidate['file']}:{candidate['start_line']}` `{candidate['symbol']}` "
            f"owner=`{candidate['owner']}` top-level=`{candidate['top_level']}` "
            f"direction=`{','.join(candidate['direction'])}` completeness=`{candidate['completeness']}`"
        )
    lines.append("")
    return "\n".join(lines)


def main() -> None:
    discovery = scan()
    DOCS_ROOT.mkdir(parents=True, exist_ok=True)
    (DOCS_ROOT / "stanza-discovery.json").write_text(
        json.dumps(discovery, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    (DOCS_ROOT / "stanza-discovery-report.md").write_text(
        render_report(discovery),
        encoding="utf-8",
    )
    print(f"Generated {DOCS_ROOT / 'stanza-discovery.json'}")
    print(f"Generated {DOCS_ROOT / 'stanza-discovery-report.md'}")
    print(f"Discovered {discovery['candidate_count']} stanza candidates")


if __name__ == "__main__":
    main()
