#!/usr/bin/env python3
"""Set each tracked file's mtime to the time of the last commit that changed it.

CI only. A fresh checkout stamps every file with the clone time, so SwiftPM
and swift-driver see every source as new and a restored .build buys nothing.
With commit-time stamps an unchanged file looks the same in every run and the
build is incremental. Needs full history (actions/checkout fetch-depth: 0).
"""
import os
import subprocess

tracked = set(subprocess.run(
    ["git", "ls-files", "-z"], check=True, capture_output=True
).stdout.decode().split("\0")) - {""}

log = subprocess.run(
    ["git", "log", "--format=@%ct", "--name-only", "--no-renames", "-z", "HEAD"],
    check=True, capture_output=True,
).stdout.decode()

stamp = None
for token in log.replace("\n", "\0").split("\0"):
    if token.startswith("@") and token[1:].isdigit():
        stamp = int(token[1:])
    elif token in tracked:
        tracked.discard(token)
        if os.path.lexists(token) and not os.path.islink(token):
            os.utime(token, (stamp, stamp))
    if not tracked:
        break
