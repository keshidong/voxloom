#!/usr/bin/env python3
"""Print the stable release tag for the checked-out commit."""

import re
import subprocess


STABLE_TAG = re.compile(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")


def versions(*tag_options):
    tags = subprocess.check_output(["git", "tag", "--list", *tag_options], text=True)
    for tag in tags.splitlines():
        if match := STABLE_TAG.fullmatch(tag):
            yield tuple(map(int, match.groups()))


def release_version():
    current = max(versions("--points-at", "HEAD"), default=None)
    if current is not None:
        return current
    major, minor, patch = max(versions(), default=(0, 1, -1))
    return major, minor, patch + 1


if __name__ == "__main__":
    major, minor, patch = release_version()
    print(f"v{major}.{minor}.{patch}")
