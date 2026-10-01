#!/usr/bin/env python3
"""Check or recreate the two local Signal CocoaPods dependencies.

Examples:
    python3 tools/local_dependencies.py check
    python3 tools/local_dependencies.py bootstrap --repository SignalProtocolC
    XABBER_DEPS_ROOT=/path/to/deps python3 tools/local_dependencies.py bootstrap

Bootstrap creates missing checkouts only. Existing checkouts are checked without
applying preparation patches or switching branches. It does not install Pods,
reset source changes, or push repositories.
"""

import argparse
import json
import os
from pathlib import Path, PurePosixPath
import subprocess
import sys
import tempfile


PROJECT = Path(__file__).resolve().parent.parent
MANIFEST = PROJECT / "tools/local-dependencies.json"
SIGNAL_REPOSITORIES = {"SignalProtocolC", "SignalProtocolObjC"}


class DependencyError(Exception):
    pass


def git(path, *arguments):
    result = subprocess.run(
        ["git", "-C", str(path), *arguments],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode:
        reason = result.stderr.strip() or result.stdout.strip()
        raise DependencyError("git {}: {}".format(" ".join(arguments), reason))
    return result.stdout.strip()


def relative_path(value):
    path = PurePosixPath(value)
    if not value or path.is_absolute() or ".." in path.parts or "\\" in value:
        raise DependencyError("Unsafe relative path: {!r}".format(value))
    return path


def inside(parent, path):
    try:
        path.resolve().relative_to(parent.resolve())
        return True
    except ValueError:
        return False


def repository_path(root, repository):
    path = root / relative_path(repository["directory"])
    if not inside(root, path):
        raise DependencyError("Repository path escapes dependency root: {}".format(path))
    return path


def patch_id(contents):
    result = subprocess.run(
        ["git", "patch-id", "--stable"], input=contents,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    if result.returncode or not result.stdout.strip():
        raise DependencyError("Cannot calculate preparation patch identity")
    return result.stdout.split()[0]


def check_preparation(path, repository):
    preparation = repository.get("preparation_patch")
    if not preparation:
        return
    patch = PROJECT / relative_path(preparation)
    if not inside(PROJECT, patch) or not patch.is_file():
        raise DependencyError("Missing preparation patch: {}".format(patch))
    prepared = repository.get("prepared_revision")
    if prepared:
        try:
            git(path, "merge-base", "--is-ancestor", prepared, "HEAD")
            return
        except DependencyError:
            pass
    # Replaying the reviewed patch creates a different commit SHA. Locate the
    # equivalent prepared tree in history so later source edits remain allowed.
    expected = patch_id(patch.read_text())
    commits = git(path, "rev-list", "{}..HEAD".format(repository["base_revision"])).splitlines()
    for commit in commits:
        changes = git(path, "diff", "--binary", repository["base_revision"], commit)
        if changes and patch_id(changes + "\n") == expected:
            return
    try:
        git(path, "apply", "--reverse", "--check", str(patch))
    except DependencyError as error:
        raise DependencyError(
            "{}: required local preparation is missing or cannot be verified; "
            "existing checkout preserved. Review {}. Details: {}".format(
                repository["id"], preparation, error
            )
        )


def check_repository(root, repository):
    path = repository_path(root, repository)
    if not path.is_dir():
        raise DependencyError("Missing checkout: {}".format(path))
    actual_root = Path(git(path, "rev-parse", "--show-toplevel")).resolve()
    if actual_root != path.resolve():
        raise DependencyError("Path is not a separate Git checkout: {}".format(path))
    branch = git(path, "branch", "--show-current")
    if branch != repository["branch"]:
        raise DependencyError(
            "{}: branch is {!r}, expected {!r}; existing branch preserved".format(
                repository["id"], branch, repository["branch"]
            )
        )
    git(path, "merge-base", "--is-ancestor", repository["base_revision"], "HEAD")
    check_preparation(path, repository)
    for pod in repository.get("pods", []):
        if not any((path / (pod + suffix)).is_file() for suffix in (".podspec", ".podspec.json")):
            raise DependencyError("Missing root podspec for {}: {}".format(pod, path))
    origin = git(path, "remote", "get-url", "origin")
    if origin not in (repository["url"], repository.get("origin")):
        print("NOTE {}: existing origin preserved: {}".format(repository["id"], origin))
    if git(path, "status", "--porcelain"):
        print("NOTE {}: local source changes preserved".format(repository["id"]))


def bootstrap_repository(root, repository):
    destination = repository_path(root, repository)
    if destination.exists() or destination.is_symlink():
        check_repository(root, repository)
        print("KEEP {}".format(destination))
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".xabber-checkout-", dir=str(destination.parent)) as temporary:
        staging = Path(temporary) / "checkout"
        staging.mkdir()
        git(staging, "init", "--quiet")
        git(staging, "remote", "add", "origin", repository["url"])
        print("FETCH {} at {}".format(repository["id"], repository["base_revision"]), flush=True)
        git(staging, "fetch", "--quiet", "--depth", "1", "origin", repository["base_revision"])
        git(staging, "switch", "--quiet", "-c", repository["branch"], repository["base_revision"])
        preparation = repository.get("preparation_patch")
        if preparation:
            patch = PROJECT / relative_path(preparation)
            if not inside(PROJECT, patch) or not patch.is_file():
                raise DependencyError("Missing preparation patch: {}".format(patch))
            git(staging, "apply", "--check", str(patch))
            git(staging, "apply", "--index", str(patch))
            git(
                staging,
                "-c", "user.name=Xabber Dependency Bootstrap",
                "-c", "user.email=local-dependencies@localhost",
                "commit", "--quiet", "-m",
                "Prepare pinned {} for local development".format(repository["id"]),
            )
        if destination.exists() or destination.is_symlink():
            raise DependencyError("Checkout appeared during bootstrap; preserved: {}".format(destination))
        staging.rename(destination)
    print("CREATED {}".format(destination))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=("check", "bootstrap"))
    parser.add_argument("--root", help="Dependency root; overrides XABBER_DEPS_ROOT and manifest default")
    parser.add_argument("--repository", action="append", default=[], metavar="ID",
                        help="Limit to one Signal repository ID (repeat for both; default: both)")
    arguments = parser.parse_args()
    manifest = json.loads(MANIFEST.read_text())
    if manifest.get("schema_version") != 1:
        raise DependencyError("Unsupported dependency manifest schema")
    root = Path(arguments.root or os.environ.get("XABBER_DEPS_ROOT") or
                (PROJECT / manifest["default_root_relative_to_project"])).expanduser().resolve()
    repositories = {r["id"]: dict(r, branch=r.get("branch", manifest["default_branch"]))
                    for r in manifest["repositories"]}
    if set(repositories) != SIGNAL_REPOSITORIES or any(
        r["manager"] != "CocoaPods" for r in repositories.values()
    ):
        raise DependencyError("Manifest must contain only SignalProtocolC and SignalProtocolObjC CocoaPods checkouts")
    unknown = set(arguments.repository) - set(repositories)
    if unknown:
        parser.error("Unknown repository IDs: " + ", ".join(sorted(unknown)))
    selected = [r for key, r in repositories.items() if not arguments.repository or key in arguments.repository]
    print("Dependency root: {}".format(root), flush=True)
    failures = []
    for repository in selected:
        try:
            if arguments.command == "bootstrap":
                bootstrap_repository(root, repository)
            check_repository(root, repository)
            print("OK repository {}".format(repository["id"]))
        except (DependencyError, OSError) as error:
            failures.append(str(error))
            print("ERROR {}: {}".format(repository["id"], error), file=sys.stderr)
    if failures:
        print("Failed: {} issue(s); existing work preserved.".format(len(failures)), file=sys.stderr)
        return 1
    print("Verified {} Signal repository/repositories.".format(len(selected)))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (DependencyError, OSError, ValueError) as error:
        print("ERROR: {}".format(error), file=sys.stderr)
        sys.exit(1)
