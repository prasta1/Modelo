#!/usr/bin/env python3
"""Reject releases whose Sparkle build number does not increase."""

import re
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def build_number(value):
    if not re.fullmatch(r"[0-9]+", value) or int(value) < 1:
        raise ValueError(f"Expected a positive integer build number, got {value!r}")
    return int(value)


def check_version(current, feed_url):
    current = build_number(current)
    try:
        with urllib.request.urlopen(feed_url, timeout=30) as response:
            feed = response.read()
    except urllib.error.HTTPError as error:
        # Only a missing feed can mean the first Sparkle release.
        if error.code == 404:
            print("No previous appcast; this is the first Sparkle release.")
            return
        raise

    root = ET.fromstring(feed)
    versions = root.findall(f"./channel/item/{SPARKLE}version")
    if not versions:
        raise ValueError("Previous appcast has no build numbers")
    previous = max(build_number(version.text or "") for version in versions)
    if current <= previous:
        raise ValueError(f"Build {current} must be greater than published build {previous}")
    print(f"Build number increases: {previous} → {current}")


if __name__ == "__main__":
    try:
        check_version(*sys.argv[1:])
    except (ValueError, TypeError, OSError, ET.ParseError) as error:
        sys.exit(f"Update version check failed: {error}")
