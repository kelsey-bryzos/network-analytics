#!/usr/bin/env python3
"""
Append a new <item> to web/updates/macos/appcast.xml.

Inputs come from env vars (set by release-macos.yml):
  APPCAST_PATH  path to appcast.xml
  VERSION       semantic version (e.g. 1.0.1)
  BUILD         monotonic build number (e.g. 1000001)
  SIG           Sparkle Ed25519 base64 signature
  LEN           DMG length in bytes
  DMG_URL       full https URL of the uploaded DMG
  REPO          github repo "owner/name" (for release-notes link)
"""
import os, pathlib, datetime, sys

required = ["APPCAST_PATH", "VERSION", "BUILD", "SIG", "LEN", "DMG_URL", "REPO"]
missing = [k for k in required if not os.environ.get(k)]
if missing:
    print(f"::error::missing env vars: {missing}", file=sys.stderr)
    sys.exit(1)

appcast_path = pathlib.Path(os.environ["APPCAST_PATH"])
version = os.environ["VERSION"]
build = os.environ["BUILD"]
sig = os.environ["SIG"]
length = os.environ["LEN"]
dmg_url = os.environ["DMG_URL"]
repo = os.environ["REPO"]

pub_date = datetime.datetime.utcnow().strftime("%a, %d %b %Y %H:%M:%S +0000")

item = f"""    <item>
      <title>Version {version}</title>
      <pubDate>{pub_date}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>10.15</sparkle:minimumSystemVersion>
      <description><![CDATA[<p>See <a href="https://github.com/{repo}/releases/tag/v{version}">release notes on GitHub</a>.</p>]]></description>
      <enclosure
        url="{dmg_url}"
        sparkle:edSignature="{sig}"
        length="{length}"
        type="application/octet-stream" />
    </item>
"""

src = appcast_path.read_text()
if "</channel>" not in src:
    print("::error::appcast.xml missing </channel> closing tag", file=sys.stderr)
    sys.exit(1)

new = src.replace("</channel>", item + "  </channel>")
appcast_path.write_text(new)
print(f"Appended v{version} (build {build}) to {appcast_path}")
