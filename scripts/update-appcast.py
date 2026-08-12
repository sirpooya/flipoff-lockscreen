#!/usr/bin/env python3
"""Regenerate appcast.xml with an entry for one release.

Called by .github/workflows/release.yml after the zip is built and signed. Lives in
a file rather than inline in the workflow because the generation needs multi-line
XML templating, and nesting that inside an indented YAML `run:` block is how you get
silently-broken heredocs.

Idempotent: re-running the same tag replaces that build's <item> rather than adding
a duplicate. Newest entry is always first.

Sparkle's own `generate_appcast` is not used because it expects a directory holding
every archive ever shipped; we only have the one just built, and past releases live
as GitHub release assets.
"""

import argparse
import os
import re
import sys
import xml.dom.minidom as minidom
from datetime import datetime, timezone
from xml.sax.saxutils import escape

APPCAST = "appcast.xml"

SKELETON = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>FlipOff</title>
        <link>{feed_url}</link>
        <description>Most recent changes to FlipOff.</description>
        <language>en</language>
    </channel>
</rss>
"""

ITEM = """        <item>
            <title>{short_version}</title>
            <pubDate>{pub_date}</pubDate>
            <sparkle:version>{build_version}</sparkle:version>
            <sparkle:shortVersionString>{short_version}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>{min_system}</sparkle:minimumSystemVersion>
            <description><![CDATA[
{notes}
            ]]></description>
            <enclosure
                url="{url}"
                length="{length}"
                type="application/octet-stream"
                sparkle:edSignature="{signature}" />
        </item>
"""


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--tag", required=True)
    p.add_argument("--short-version", required=True)
    p.add_argument("--build-version", required=True)
    p.add_argument("--min-system", required=True)
    p.add_argument("--zip-name", required=True)
    p.add_argument("--length", required=True)
    p.add_argument("--signature", required=True)
    p.add_argument("--repo", required=True, help="owner/name")
    p.add_argument("--notes", default="")
    args = p.parse_args()

    feed_url = f"https://raw.githubusercontent.com/{args.repo}/main/appcast.xml"
    url = (
        f"https://github.com/{args.repo}/releases/download/"
        f"{args.tag}/{args.zip_name}"
    )

    notes = args.notes.strip() or f"FlipOff {args.short_version}"
    # A literal ]]> would close the CDATA block early and corrupt the feed.
    notes = notes.replace("]]>", "]]&gt;")

    if os.path.exists(APPCAST):
        with open(APPCAST, encoding="utf-8") as fh:
            xml = fh.read()
    else:
        xml = SKELETON.format(feed_url=escape(feed_url))

    # Drop any existing <item> for this build so re-tagging replaces it.
    stale = re.compile(
        r"[ \t]*<item>(?:(?!</item>).)*?<sparkle:version>"
        + re.escape(args.build_version)
        + r"</sparkle:version>.*?</item>\n?",
        re.S,
    )
    xml, removed = stale.subn("", xml)
    if removed:
        print(f"Replaced existing entry for build {args.build_version}")

    item = ITEM.format(
        short_version=escape(args.short_version),
        pub_date=datetime.now(timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000"),
        build_version=escape(args.build_version),
        min_system=escape(args.min_system),
        notes=notes,
        url=escape(url),
        length=escape(args.length),
        signature=escape(args.signature),
    )

    marker = "</language>\n"
    if marker not in xml:
        print("error: appcast.xml is missing the <language> marker", file=sys.stderr)
        return 1

    idx = xml.index(marker) + len(marker)
    xml = xml[:idx] + item + xml[idx:]

    with open(APPCAST, "w", encoding="utf-8") as fh:
        fh.write(xml)

    # Fail the release rather than publish a feed Sparkle can't parse.
    minidom.parse(APPCAST)
    print(f"appcast.xml updated for {args.tag} (build {args.build_version})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
