#!/usr/bin/env python3
"""Stamp the exact shared chat package sources into a built app's Info.plist."""
from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import plistlib
import subprocess


def source_fingerprint(package: pathlib.Path) -> str:
    manifest = package / "Package.swift"
    sources = package / "Sources"
    if not manifest.is_file() or not sources.is_dir():
        raise ValueError("HouseChatCore package is missing its manifest or sources")
    files = [manifest] + sorted(p for p in sources.rglob("*") if p.is_file())
    digest = hashlib.sha256()
    for path in files:
        if path.is_symlink():
            raise ValueError(f"Refusing a symlinked package source: {path.name}")
        name = path.relative_to(package).as_posix().encode("utf-8")
        data = path.read_bytes()
        digest.update(len(name).to_bytes(8, "big"))
        digest.update(name)
        digest.update(len(data).to_bytes(8, "big"))
        digest.update(data)
    return digest.hexdigest()


def provenance(owner: pathlib.Path) -> dict:
    package = owner / "Packages" / "HouseChatCore"
    commit = subprocess.run(
        ["git", "-C", str(owner), "rev-parse", "HEAD"],
        check=True, capture_output=True, text=True,
    ).stdout.strip()
    dirty = bool(subprocess.run(
        ["git", "-C", str(owner), "status", "--porcelain", "--", "Packages/HouseChatCore"],
        check=True, capture_output=True, text=True,
    ).stdout.strip())
    return {"owner_commit": commit, "source_sha256": source_fingerprint(package), "dirty": dirty}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plist", type=pathlib.Path, help="Built app Info.plist to stamp before signing")
    parser.add_argument("--require-clean", action="store_true")
    args = parser.parse_args()
    owner = pathlib.Path(__file__).resolve().parent.parent
    try:
        receipt = provenance(owner)
        if args.require_clean and receipt["dirty"]:
            raise ValueError("Refusing a build with uncommitted HouseChatCore sources")
        if args.plist:
            info = plistlib.loads(args.plist.read_bytes())
            info["HouseChatCoreOwnerCommit"] = receipt["owner_commit"]
            info["HouseChatCoreSourceSHA256"] = receipt["source_sha256"]
            info["HouseChatCoreDirty"] = receipt["dirty"]
            # This is a build product, not application data. Existing signing follows.
            args.plist.write_bytes(plistlib.dumps(info, sort_keys=False))
        print(json.dumps(receipt, sort_keys=True))
        return 0
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"chat-core provenance: {error}\n")


if __name__ == "__main__":
    raise SystemExit(main())
