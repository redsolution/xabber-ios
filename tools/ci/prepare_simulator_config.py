#!/usr/bin/env python3
"""Materialize the public plist examples for an isolated CI simulator build."""

import argparse
import plistlib
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app_directory", type=Path)
    app_dir = parser.parse_args().app_directory

    simulator_host = "xmpp.example.invalid"
    bundle_id = "xabber.ios"
    overrides = {
        "Info.plist": {"CrowdinDistributionHash": ""},
        "common_config.plist": {
            "allowed_hosts": [simulator_host],
            "app_name": "Xabber CI",
            "bundle_id": bundle_id,
            "push_bundle_id": f"{bundle_id}.xabber-push-extension",
            "domain": simulator_host,
            "allow_registration": False,
            "support_xabber_account": False,
            "xabber_account_xmpp_jid": "",
        },
        "credential_store.plist": {"uniqueServiceName": "xabber.ci.keychain"},
        "push_service.plist": {
            "release_url": "https://push.example.invalid",
            "debug_url": "https://push.example.invalid",
            "release_key": "",
            "debug_key": "",
        },
        "subscribtions_secret.plist": {
            "api_url": "https://subscriptions.example.invalid",
            "product_list": [],
        },
        "xabber.entitlements": {
            "com.apple.security.application-groups": [f"group.{bundle_id}"],
        },
    }

    documents = {}
    for name, values in overrides.items():
        destination = app_dir / name
        if destination.is_symlink() or destination.exists():
            parser.error(f"Refusing to replace {destination}")
        with (app_dir / f"{name}.example").open("rb") as template:
            document = plistlib.load(template)
        document.update(values)
        if name == "xabber.entitlements":
            # Keep the groups shared with the push extension for simulator signing.
            document = {key: document[key] for key in (*values, "keychain-access-groups")}
        documents[destination] = document

    for destination, document in documents.items():
        with destination.open("xb") as output:
            plistlib.dump(document, output)


if __name__ == "__main__":
    main()
