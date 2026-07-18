#!/usr/bin/env python3
"""Prepend a release item to the Sparkle appcast.

Usage:
  update_appcast.py <appcast.xml> --version X.Y.Z --url <enclosure-url>
                    --signature-attrs 'sparkle:edSignature="..." length="..."'
                    [--notes TEXT] [--minimum-system-version 15.0] [--print-only]

Creates the appcast if it does not exist. --print-only renders the new item to
stdout without touching the file (used by release.sh --dry-run).
"""

import argparse
import re
import sys
from email.utils import formatdate
from xml.sax.saxutils import escape

APPCAST_SKELETON = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Stackdust</title>
  </channel>
</rss>
"""

ITEM_TEMPLATE = """    <item>
      <title>{version}</title>
      <pubDate>{pub_date}</pubDate>
      <sparkle:version>{version}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{min_system}</sparkle:minimumSystemVersion>
      <description>{notes}</description>
      <enclosure url="{url}" sparkle:edSignature="{signature}" length="{length}" type="application/octet-stream"/>
    </item>
"""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("appcast")
    parser.add_argument("--version", required=True)
    parser.add_argument("--url", required=True)
    parser.add_argument(
        "--signature-attrs",
        required=True,
        help="verbatim output of Sparkle's sign_update",
    )
    parser.add_argument("--notes", default="Bug fixes and improvements.")
    parser.add_argument("--minimum-system-version", default="15.0")
    parser.add_argument("--print-only", action="store_true")
    args = parser.parse_args()

    signature = re.search(r'sparkle:edSignature="([^"]+)"', args.signature_attrs)
    length = re.search(r'length="(\d+)"', args.signature_attrs)
    if not signature or not length:
        print(f"cannot parse sign_update output: {args.signature_attrs!r}", file=sys.stderr)
        return 2

    item = ITEM_TEMPLATE.format(
        version=escape(args.version),
        pub_date=formatdate(usegmt=True),
        min_system=escape(args.minimum_system_version),
        notes=escape(args.notes),
        url=escape(args.url, {'"': "&quot;"}),
        signature=escape(signature.group(1), {'"': "&quot;"}),
        length=length.group(1),
    )

    if args.print_only:
        print(item, end="")
        return 0

    try:
        content = open(args.appcast, encoding="utf-8").read()
    except FileNotFoundError:
        content = APPCAST_SKELETON

    if f"<title>{escape(args.version)}</title>" in content:
        print(f"appcast already has an item for {args.version}", file=sys.stderr)
        return 2

    marker = "</title>\n"  # end of the channel title line
    pos = content.find(marker)
    if pos < 0:
        print(f"{args.appcast} has no channel title; malformed appcast?", file=sys.stderr)
        return 2
    pos += len(marker)

    open(args.appcast, "w", encoding="utf-8").write(content[:pos] + item + content[pos:])
    print(f"added {args.version} to {args.appcast}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
