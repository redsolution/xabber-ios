#!/usr/bin/env python3

from __future__ import annotations

import json
import re
from collections import defaultdict
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
DOCS_ROOT = REPO_ROOT / "docs" / "xmpp"
DISCOVERY_PATH = DOCS_ROOT / "stanza-discovery.json"


SECTION_ORDER = [
    "session-auth-stream",
    "roster-presence",
    "message-send-receive-core",
    "mam-history",
    "omemo",
    "pubsub-push-notifications",
    "sync-favorites-custom",
    "other-xmpp-flows",
]

SECTION_META = {
    "session-auth-stream": {
        "title": "Session / Auth / Stream",
        "description": "Bootstrap, discovery, registration, ping, and stream-level capability handling.",
    },
    "roster-presence": {
        "title": "Roster / Presence",
        "description": "Roster management, subscription flow, presence metadata, and resource/device state.",
    },
    "message-send-receive-core": {
        "title": "Message Send / Receive Core",
        "description": "Interactive message bodies, receipts, markers, chat states, forwards, and message-side wrappers.",
    },
    "mam-history": {
        "title": "MAM / History",
        "description": "Archive query, archive result wrappers, and history paging flows.",
    },
    "omemo": {
        "title": "OMEMO",
        "description": "OMEMO encrypted messages, device lists, bundle publication, and trust-related encrypted flows.",
    },
    "pubsub-push-notifications": {
        "title": "Pubsub / Push / Notifications",
        "description": "Push enablement, pubsub-backed notification flows, and notification payload wrappers.",
    },
    "sync-favorites-custom": {
        "title": "Sync / Favorites / Xabber Custom",
        "description": "Synchronization, saved messages, favorites, device management, tokens, and app-specific XMPP families.",
    },
    "other-xmpp-flows": {
        "title": "Other XMPP Flows",
        "description": "Discovered stanza families that are XMPP-active but do not fit the main catalog buckets cleanly.",
    },
}

MANUAL_RESOLUTIONS = [
    {
        "id": "groupchat-create-lifecycle",
        "title": "Groupchat / Create And Membership Lifecycle",
        "section": "sync-favorites-custom",
        "purpose": "Manual resolution for group creation, deletion, join, leave, subscription, and lifecycle presence/IQ flows under the Xabber groups protocol.",
        "top_level": "mixed",
        "matchers": [
            {
                "file_suffix": "xabber/xmpp/groupchat/GroupchatManager.swift",
                "symbols": [
                    "createPeerToPeer",
                    "create",
                    "delete",
                    "join",
                    "cancelJoin",
                    "decline",
                    "leave",
                    "onInfo",
                    "onSubscribe",
                    "onCreate",
                    "onDelete",
                    "onError",
                    "success",
                    "fail",
                ],
            }
        ],
    },
    {
        "id": "groupchat-invites",
        "title": "Groupchat / Invites",
        "section": "sync-favorites-custom",
        "purpose": "Manual resolution for invite creation, cancellation, revocation, invite list fetches, invite parsing, and headline/message invite wrappers.",
        "top_level": "mixed",
        "matchers": [
            {
                "file_suffix": "xabber/xmpp/groupchat/GroupchatManager.swift",
                "symbols": [
                    "willInvite",
                    "didInvite",
                    "revokeInvites",
                    "revokeInvite",
                    "cancelInvite",
                    "requestInvitedUsers",
                    "onInviteList",
                    "isInvite",
                    "readInvite",
                    "onDecline",
                    "onSuccesInvite",
                    "onRevoke",
                    "onInviteUpdate",
                    "onNewInvites",
                    "getInvitesFallback",
                    "updateInvitesState",
                ],
            }
        ],
    },
    {
        "id": "groupchat-members-and-usercards",
        "title": "Groupchat / Members And User Cards",
        "section": "sync-favorites-custom",
        "purpose": "Manual resolution for member list requests, member payload parsing, user card updates, and member-bound message payload handling.",
        "top_level": "mixed",
        "matchers": [
            {
                "file_suffix": "xabber/xmpp/groupchat/GroupchatManager.swift",
                "symbols": [
                    "changeUserData",
                    "requestUsers",
                    "onUser",
                    "updateUserCard",
                    "readMessage",
                    "readHeadlineMessage",
                ],
            }
        ],
    },
    {
        "id": "groupchat-permissions",
        "title": "Groupchat / Permissions",
        "section": "sync-favorites-custom",
        "purpose": "Manual resolution for default, newbie, and per-user permissions queries and updates using the Xabber permissions namespace.",
        "top_level": "iq",
        "matchers": [
            {
                "file_suffix": "xabber/xmpp/groupchat/GroupchatManager.swift",
                "symbols": [
                    "updateUserPermissions",
                    "updateDefaultPermissions",
                    "getDefaultPermissions",
                    "onReceiveDefaultPermissionsList",
                    "updateNewbiesPermissions",
                    "getNewbiesPermissions",
                    "onReceiveNewbiesPermissionsList",
                    "onReceiveUserPermissionssList",
                    "requestUserPermissions",
                    "requestPermissionsEachUser",
                ],
            }
        ],
    },
    {
        "id": "groupchat-info-avatar-block-pin",
        "title": "Groupchat / Info Avatar Block Pin",
        "section": "sync-favorites-custom",
        "purpose": "Manual resolution for group info/settings updates, avatar mutation, block/unblock lists, pinned message management, and related info parsing.",
        "top_level": "iq",
        "matchers": [
            {
                "file_suffix": "xabber/xmpp/groupchat/GroupchatManager.swift",
                "symbols": [
                    "getGroupInfo",
                    "updateSettings",
                    "updateInfo",
                    "updateGroupAvatar",
                    "updateMemberAvatar",
                    "blockList",
                    "kickUser",
                    "blockUser",
                    "unblockUser",
                    "unpinMessage",
                    "pinMessage",
                    "requestPinnedMessage",
                    "onBlockList",
                    "onBlock",
                    "onGroupInfo",
                    "onUnblock",
                ],
            }
        ],
    },
    {
        "id": "omemo-sce-envelope",
        "title": "OMEMO / SCE Envelope",
        "section": "omemo",
        "purpose": "Manual resolution for Secure Content Encryption envelope construction, encrypted message wrapping, and encrypted stanza mutation.",
        "top_level": "message",
        "matchers": [
            {
                "file_suffix": "xabber/xmpp/omemo/OmemoManager.swift",
                "symbols": [
                    "prepareStanzaContent",
                    "modifyOmemoStanza",
                    "didReceiveOmemoMessageFromPush",
                    "didReceiveOmemoMessage",
                    "decryptMessage",
                ],
            },
            {
                "file_suffix": "xabber/xmpp/omemo/OmemoManager+Encryption.swift",
                "symbols": [
                    "encryptMessage",
                    "doubleRatchet",
                ],
            },
        ],
    },
    {
        "id": "omemo-pubsub-subscriptions",
        "title": "OMEMO / Pubsub Subscriptions",
        "section": "omemo",
        "purpose": "Manual resolution for pubsub subscribe and unsubscribe flows around OMEMO device, bundle, and trust-sharing nodes.",
        "top_level": "iq",
        "matchers": [
            {
                "file_suffix": "xabber/xmpp/omemo/OmemoManager.swift",
                "symbols": [
                    "subscribeNode",
                    "unsubscribeNode",
                ],
            }
        ],
    },
    {
        "id": "omemo-device-list",
        "title": "OMEMO / Device Lists",
        "section": "omemo",
        "purpose": "Manual resolution for OMEMO device list fetches, pubsub headline updates, and device-list item parsing.",
        "top_level": "mixed",
        "matchers": [
            {
                "file_suffix": "xabber/xmpp/omemo/OmemoManager.swift",
                "symbols": [
                    "getContactDevices",
                    "onContactDeviceListErrorReceive",
                    "onContactDeviceListReceive",
                    "onContactDeviceListReceiveHeadline",
                    "onEncryptionUpdateReceiveHeadline",
                    "onContactDeviceListReceiveItem",
                    "onContactDeviceReceiveHeadline",
                ],
            }
        ],
    },
    {
        "id": "omemo-bundles",
        "title": "OMEMO / Bundles",
        "section": "omemo",
        "purpose": "Manual resolution for device bundle publish/query/retract flows and bundle payload parsing.",
        "top_level": "iq",
        "matchers": [
            {
                "file_suffix": "xabber/xmpp/omemo/OmemoManager+BundlePublication.swift",
                "symbols": [
                    "createNode",
                    "configureNode",
                    "sendOwnDeviceBundle",
                    "sendOwnDevice",
                    "sendRetractOwnDevice",
                ],
            },
            {
                "file_suffix": "xabber/xmpp/omemo/OmemoManager.swift",
                "symbols": [
                    "getContactBundle",
                    "onContactBundleErrorReceive",
                    "deleteDeviceOrBundle",
                    "onContactBundleReceive",
                ],
            },
        ],
    },
    {
        "id": "omemo-decrypt-and-sync",
        "title": "OMEMO / Sync Overlay",
        "section": "omemo",
        "purpose": "Manual resolution for synchronization-aware OMEMO payload mutation and decrypt-side sync handling.",
        "top_level": "message",
        "matchers": [
            {
                "file_suffix": "xabber/xmpp/omemo/OmemoManager.swift",
                "symbols": [
                    "modifySyncQuery",
                ],
            }
        ],
    },
    {
        "id": "ake-verification-start",
        "title": "AKE / Verification Start",
        "section": "sync-favorites-custom",
        "purpose": "Manual resolution for trust verification start messages and inbound verification-start parsing.",
        "top_level": "message",
        "matchers": [
            {
                "file_suffix": "xabber/xmpp/ake/AuthenticatedKeyExchangeManager.swift",
                "symbols": [
                    "getMessageChildsForVerififcationRequest",
                    "sendVerificationRequest",
                    "didVerificationStartReceived",
                ],
            }
        ],
    },
    {
        "id": "ake-accepted-and-hash-exchange",
        "title": "AKE / Accepted And Hash Exchange",
        "section": "sync-favorites-custom",
        "purpose": "Manual resolution for verification acceptance, salt transport, ciphertext handling, and subsequent hash exchange messages.",
        "top_level": "message",
        "matchers": [
            {
                "file_suffix": "xabber/xmpp/ake/AuthenticatedKeyExchangeManager.swift",
                "symbols": [
                    "getMessageChildsForAcceptVerificationRequest",
                    "getMessageChildsToSendHashAndSaltToOpponent",
                    "acceptVerificationRequest",
                    "didVerificationAcceptReceived",
                    "didHashFromInitiatorReceived",
                    "didHashFromRecipientReceived",
                    "sendHashToOpponent",
                    "decryptElementFromXML",
                ],
            }
        ],
    },
    {
        "id": "ake-result-messages",
        "title": "AKE / Result Messages",
        "section": "sync-favorites-custom",
        "purpose": "Manual resolution for verification success, reject, and failure result messages in the trust exchange flow.",
        "top_level": "message",
        "matchers": [
            {
                "file_suffix": "xabber/xmpp/ake/AuthenticatedKeyExchangeManager.swift",
                "symbols": [
                    "getMessageChildsForErrorMessage",
                    "didVerificationSuccessReceived",
                    "didVerificationRejectReceived",
                    "didVerificationFailureReceived",
                    "sendSuccessfulVerificationMessage",
                    "sendErrorMessage",
                    "rejectRequestToVerify",
                ],
            }
        ],
    },
    {
        "id": "ake-high-priority-wrapper",
        "title": "AKE / High Priority Wrapper",
        "section": "sync-favorites-custom",
        "purpose": "Manual resolution for high-priority wrapped trust messages and the surrounding message dispatcher for AKE traffic.",
        "top_level": "message",
        "matchers": [
            {
                "file_suffix": "xabber/xmpp/ake/AuthenticatedKeyExchangeManager.swift",
                "symbols": [
                    "didReceivedVerificationMessage",
                    "processMessage",
                    "getSignalMessagePacket",
                ],
            }
        ],
    },
    {
        "id": "client-sync-query-and-pagination",
        "title": "Client Sync / Query And Pagination",
        "section": "sync-favorites-custom",
        "purpose": "Manual resolution for synchronization availability checks, snapshot queries, and RSM pagination over conversation snapshots.",
        "top_level": "iq",
        "matchers": [
            {
                "file_suffix": "xabber/xmpp/XEP-0CCC/ClientSynchronizationManager.swift",
                "symbols": [
                    "checkAvailability",
                    "syncStamp",
                    "sync",
                    "checkNextPage",
                    "parseSnapshotPage",
                    "readResult",
                ],
            }
        ],
    },
    {
        "id": "client-sync-conversation-updates",
        "title": "Client Sync / Conversation Updates",
        "section": "sync-favorites-custom",
        "purpose": "Manual resolution for outgoing synchronization conversation mutations such as mute, pin, and metadata update operations.",
        "top_level": "iq",
        "matchers": [
            {
                "file_suffix": "xabber/xmpp/XEP-0CCC/ClientSynchronizationManager.swift",
                "symbols": [
                    "muteChat",
                    "pinChat",
                    "update",
                ],
            }
        ],
    },
    {
        "id": "client-sync-presence-markers-invites",
        "title": "Client Sync / Presence Markers Invites",
        "section": "sync-favorites-custom",
        "purpose": "Manual resolution for synchronized embedded presence, message markers, push payloads, and invite overlays inside snapshot conversations.",
        "top_level": "mixed",
        "matchers": [
            {
                "file_suffix": "xabber/xmpp/XEP-0CCC/ClientSynchronizationManager.swift",
                "symbols": [
                    "readPush",
                    "readPresence",
                    "readMessageMarkers",
                    "readInvites",
                ],
            }
        ],
    },
    {
        "id": "client-sync-conversation-snapshot",
        "title": "Client Sync / Conversation Snapshot",
        "section": "sync-favorites-custom",
        "purpose": "Manual resolution for conversation snapshot metadata parsing, conversation payload reads, and synchronized last-message extraction.",
        "top_level": "mixed",
        "matchers": [
            {
                "file_suffix": "xabber/xmpp/XEP-0CCC/ClientSynchronizationManager.swift",
                "symbols": [
                    "readConversationMetadata",
                    "readConversation",
                ],
            }
        ],
    },
]


def slug(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")


def load_discovery() -> dict:
    if not DISCOVERY_PATH.exists():
        raise FileNotFoundError(
            f"Missing discovery input at {DISCOVERY_PATH}. Run tools/discover_xmpp_stanzas.py first."
        )
    return json.loads(DISCOVERY_PATH.read_text(encoding="utf-8"))


def infer_section(candidate: dict) -> str:
    directory = candidate["directory"]
    namespaces = set(candidate["namespaces"])
    owner = candidate["owner"]
    text = " ".join([directory, owner, candidate["symbol"], candidate["stanza_family_hint"]]).lower()

    if candidate["top_level"] == "stream" or "register" in text or "disco" in text or "ping" in text:
        return "session-auth-stream"
    if any(key in text for key in ["roster", "presence", "vcard", "avatar", "caps", "user"]) or candidate["top_level"] == "presence":
        return "roster-presence"
    if any(key in text for key in ["mam", "archive"]) or "urn:xmpp:mam:" in " ".join(namespaces):
        return "mam-history"
    if "omemo" in text or "eu.siacs.conversations.axolotl" in namespaces:
        return "omemo"
    if any(key in text for key in ["push", "notification", "pubsub"]) or any(ns in namespaces for ns in ["urn:xmpp:push:0", "urn:xabber:xen:0"]):
        return "pubsub-push-notifications"
    if any(key in text for key in ["sync", "favorites", "device", "token", "groupchat", "rewrite", "trust", "ake", "xep-0", "block", "abuse", "upload", "voip"]):
        return "sync-favorites-custom"
    if candidate["top_level"] == "message" or any(key in text for key in ["message", "receipt", "marker", "carbon", "chat_states", "chat-markers", "chat states", "forward"]):
        return "message-send-receive-core"
    return "other-xmpp-flows"


def make_signature(candidate: dict) -> tuple:
    namespace_key = tuple(candidate["namespaces"][:4])
    created = tuple(candidate["created_elements"][:5])
    read = tuple(candidate["read_elements"][:5])
    top_level = candidate["top_level"]
    section = infer_section(candidate)
    owner = candidate["owner"]
    family = candidate["stanza_family_hint"]
    return (section, top_level, owner, family, namespace_key, created, read)


def candidate_matches(candidate: dict, matcher: dict) -> bool:
    if matcher.get("file_suffix") and not candidate["file"].endswith(matcher["file_suffix"]):
        return False
    if matcher.get("symbols") and candidate["symbol"] not in matcher["symbols"]:
        return False
    if matcher.get("contains") and not any(token in candidate["id"] for token in matcher["contains"]):
        return False
    return True


def build_manual_entries(discovery: dict) -> tuple[list[dict], set[str]]:
    entries = []
    matched_ids: set[str] = set()
    for resolution in MANUAL_RESOLUTIONS:
        matched = []
        for candidate in discovery["candidates"]:
            if any(candidate_matches(candidate, matcher) for matcher in resolution["matchers"]):
                matched.append(candidate)
                matched_ids.add(candidate["id"])
        if not matched:
            continue

        producers = []
        consumers = []
        directions = set()
        namespaces = sorted({ns for item in matched for ns in item["namespaces"]})
        created_elements = sorted({value for item in matched for value in item["created_elements"]})
        read_elements = sorted({value for item in matched for value in item["read_elements"]})
        attributes = sorted({value for item in matched for value in item["attributes"]})
        owners = sorted({item["owner"] for item in matched})
        top_levels = sorted({item["top_level"] for item in matched if item["top_level"] != "unknown"})
        top_level = resolution["top_level"]
        if top_level == "mixed":
            top_level = ", ".join(top_levels) if top_levels else "unknown"

        for item in sorted(matched, key=lambda item: (item["file"], item["start_line"], item["symbol"])):
            directions.update(item["direction"])
            site = {"file": item["file"], "symbol": item["symbol"], "line": item["start_line"]}
            if item["produces_stanza"]:
                producers.append(site)
            if item["consumes_stanza"]:
                consumers.append(site)

        entries.append(
            {
                "id": resolution["id"],
                "section": resolution["section"],
                "title": resolution["title"],
                "top_level": top_level,
                "direction": sorted(direction for direction in directions if direction != "unknown") or ["unknown"],
                "completeness": "manual-resolved",
                "owner": ", ".join(owners),
                "namespaces": namespaces,
                "created_elements": created_elements,
                "read_elements": read_elements,
                "attributes": attributes,
                "purpose": resolution["purpose"],
                "producer_sites": sorted(producers, key=lambda item: (item["file"], item["line"], item["symbol"])),
                "consumer_sites": sorted(consumers, key=lambda item: (item["file"], item["line"], item["symbol"])),
                "source_candidates": [
                    {
                        "id": item["id"],
                        "file": item["file"],
                        "symbol": item["symbol"],
                        "line": item["start_line"],
                    }
                    for item in sorted(matched, key=lambda item: (item["file"], item["start_line"], item["symbol"]))
                ],
            }
        )
    return entries, matched_ids


def merge_candidates(discovery: dict) -> list[dict]:
    grouped: dict[tuple, list[dict]] = defaultdict(list)
    for candidate in discovery["candidates"]:
        grouped[make_signature(candidate)].append(candidate)

    entries = []
    for _, group in grouped.items():
        group = sorted(group, key=lambda item: (item["file"], item["start_line"]))
        section = infer_section(group[0])
        producers = []
        consumers = []
        directions = set()
        completeness_rank = {"complete": 0, "partial": 1, "manual-review": 2}
        completeness = "complete"
        namespaces = sorted({ns for item in group for ns in item["namespaces"]})
        created_elements = sorted({value for item in group for value in item["created_elements"]})
        read_elements = sorted({value for item in group for value in item["read_elements"]})
        attributes = sorted({value for item in group for value in item["attributes"]})
        for item in group:
            directions.update(item["direction"])
            site = {
                "file": item["file"],
                "symbol": item["symbol"],
                "line": item["start_line"],
            }
            if item["produces_stanza"]:
                producers.append(site)
            if item["consumes_stanza"]:
                consumers.append(site)
            if completeness_rank[item["completeness"]] > completeness_rank[completeness]:
                completeness = item["completeness"]

        representative = group[0]
        signature_tail = "-".join(
            [
                representative["symbol"],
                representative["stanza_family_hint"],
                representative["top_level"],
                namespaces[0] if namespaces else "no-ns",
            ]
        )
        label_parts = [representative["owner"], signature_tail]
        entry_id = slug("-".join(label_parts))
        title = f"{representative['owner']} / {representative['symbol']}"
        lines = []
        if created_elements:
            lines.append(f"creates `{', '.join(created_elements[:6])}`")
        if read_elements:
            lines.append(f"reads `{', '.join(read_elements[:6])}`")
        if namespaces:
            lines.append(f"namespaces `{', '.join(namespaces[:6])}`")
        purpose = "; ".join(lines) if lines else "Discovered stanza-active flow."

        entries.append(
            {
                "id": entry_id,
                "section": section,
                "title": title,
                "top_level": representative["top_level"],
                "direction": sorted(direction for direction in directions if direction != "unknown") or ["unknown"],
                "completeness": completeness,
                "owner": representative["owner"],
                "namespaces": namespaces,
                "created_elements": created_elements,
                "read_elements": read_elements,
                "attributes": attributes,
                "purpose": purpose,
                "producer_sites": sorted(producers, key=lambda item: (item["file"], item["line"], item["symbol"])),
                "consumer_sites": sorted(consumers, key=lambda item: (item["file"], item["line"], item["symbol"])),
                "source_candidates": [
                    {
                        "id": item["id"],
                        "file": item["file"],
                        "symbol": item["symbol"],
                        "line": item["start_line"],
                    }
                    for item in group
                ],
            }
        )
    return sorted(entries, key=lambda entry: (SECTION_ORDER.index(entry["section"]), entry["owner"], entry["title"], entry["id"]))


def build_manifest(discovery: dict) -> dict:
    manual_entries, matched_ids = build_manual_entries(discovery)
    auto_discovery = dict(discovery)
    auto_discovery["candidates"] = [
        candidate for candidate in discovery["candidates"] if candidate["id"] not in matched_ids
    ]
    entries = manual_entries + merge_candidates(auto_discovery)
    seen_ids: dict[str, int] = {}
    for entry in entries:
        base_id = entry["id"]
        seen_ids[base_id] = seen_ids.get(base_id, 0) + 1
        if seen_ids[base_id] > 1:
            entry["id"] = f"{base_id}-{seen_ids[base_id]}"
    covered_directories = sorted({site["file"].rsplit("/", 1)[0] for entry in entries for site in (entry["producer_sites"] + entry["consumer_sites"]) if site["file"].startswith("xabber/xmpp/")})
    missing_directories = sorted(set(discovery["active_directories"]) - set(covered_directories))
    sections = []
    for section_id in SECTION_ORDER:
        section_entries = [entry for entry in entries if entry["section"] == section_id]
        if not section_entries:
            continue
        meta = SECTION_META[section_id]
        sections.append(
            {
                "id": section_id,
                "title": meta["title"],
                "description": meta["description"],
                "entries": section_entries,
            }
        )

    manifest = {
        "catalog_version": 2,
        "generated_from": "tools/generate_xmpp_stanza_catalog.py",
        "discovery_input": "docs/xmpp/stanza-discovery.json",
        "manually_resolved_entry_count": len(manual_entries),
        "section_count": len(sections),
        "entry_count": len(entries),
        "active_directory_count": len(discovery["active_directories"]),
        "covered_directory_count": len(covered_directories),
        "uncovered_active_directories": missing_directories,
        "sections": sections,
    }
    if missing_directories:
        raise ValueError(f"Active stanza directories missing from final catalog: {missing_directories}")
    return manifest


def render_markdown(manifest: dict, discovery: dict) -> str:
    _, matched_ids = build_manual_entries(discovery)
    lines = [
        "# XMPP Stanza Catalog",
        "",
        "This catalog is generated from discovered stanza-active functions under `xabber/xmpp` and the app-side XMPP entrypoints that feed them. Each entry aggregates one or more discovered producer or consumer candidates into a normalized stanza-family record.",
        "",
        f"- Generated by: `{manifest['generated_from']}`",
        f"- Discovery input: `{manifest['discovery_input']}`",
        f"- Sections: `{manifest['section_count']}`",
        f"- Final catalog entries: `{manifest['entry_count']}`",
        f"- Manual resolutions applied: `{manifest['manually_resolved_entry_count']}`",
        f"- Active stanza directories covered: `{manifest['covered_directory_count']}` / `{manifest['active_directory_count']}`",
        "",
        "## Discovery Notes",
        "",
        "- This is discovery-first output: breadth and traceability take priority over perfect XML reconstruction.",
        "- Entries marked `partial` or `manual-review` need human follow-up for dynamic helpers, propagated child trees, or namespace indirection.",
        "- REST-only upload code is excluded unless the scanned function actually constructs or parses XMPP stanza XML.",
        "",
    ]

    for section in manifest["sections"]:
        lines.extend([f"## {section['title']}", "", section["description"], ""])
        for entry in section["entries"]:
            lines.extend(
                [
                    f"### {entry['title']}: `{entry['id']}`",
                    "",
                    f"- Top-level: `{entry['top_level']}`",
                    f"- Direction: `{', '.join(entry['direction'])}`",
                    f"- Completeness: `{entry['completeness']}`",
                    f"- Owner: `{entry['owner']}`",
                    f"- Purpose: {entry['purpose']}",
                    f"- Namespaces: {', '.join(f'`{value}`' for value in entry['namespaces']) if entry['namespaces'] else '`none`'}",
                    f"- Created elements: {', '.join(f'`{value}`' for value in entry['created_elements']) if entry['created_elements'] else '`none`'}",
                    f"- Read elements: {', '.join(f'`{value}`' for value in entry['read_elements']) if entry['read_elements'] else '`none`'}",
                    f"- Attributes: {', '.join(f'`{value}`' for value in entry['attributes']) if entry['attributes'] else '`none`'}",
                    "",
                    "#### Producer Sites",
                    "",
                ]
            )
            if entry["producer_sites"]:
                lines.extend(f"- `{site['file']}:{site['line']}` `{site['symbol']}`" for site in entry["producer_sites"])
            else:
                lines.append("- `none`")
            lines.extend(["", "#### Consumer Sites", ""])
            if entry["consumer_sites"]:
                lines.extend(f"- `{site['file']}:{site['line']}` `{site['symbol']}`" for site in entry["consumer_sites"])
            else:
                lines.append("- `none`")
            lines.extend(["", "#### Source Candidates", ""])
            lines.extend(f"- `{site['file']}:{site['line']}` `{site['symbol']}`" for site in entry["source_candidates"])
            lines.append("")

    lines.extend(["## Manual Review Carryover", ""])
    carryover = [
        candidate
        for candidate in discovery["manual_review_required"]
        if candidate["id"] not in matched_ids
    ]
    if not carryover:
        lines.append("- `none`")
    else:
        for candidate in carryover:
            lines.append(
                f"- `{candidate['file']}:{candidate['start_line']}` `{candidate['symbol']}` "
                f"top-level=`{candidate['top_level']}` completeness=`{candidate['completeness']}`"
            )
    lines.append("")
    return "\n".join(lines)


def main() -> None:
    discovery = load_discovery()
    manifest = build_manifest(discovery)
    DOCS_ROOT.mkdir(parents=True, exist_ok=True)
    (DOCS_ROOT / "stanza-catalog.json").write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    (DOCS_ROOT / "stanza-catalog.md").write_text(
        render_markdown(manifest, discovery),
        encoding="utf-8",
    )
    print(f"Generated {DOCS_ROOT / 'stanza-catalog.json'}")
    print(f"Generated {DOCS_ROOT / 'stanza-catalog.md'}")
    print(f"Cataloged {manifest['entry_count']} normalized stanza entries")


if __name__ == "__main__":
    main()
