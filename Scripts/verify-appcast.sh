#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/version.env"

VERSION=${1:-$MARKETING_VERSION}
APPCAST="${ROOT}/appcast.xml"

if [[ ! -f "$APPCAST" ]]; then
    echo "appcast.xml not found" >&2
    exit 1
fi

if ! command -v sign_update &>/dev/null; then
    echo "sign_update not found. Install: brew install andyhtran/tap/sparkle-tools" >&2
    exit 1
fi

TMP_ZIP=$(mktemp /tmp/appcast-verify.XXXX.zip)
trap 'rm -f "$TMP_ZIP" "$TMP_ZIP.meta"' EXIT

python3 - "$APPCAST" "$VERSION" >"$TMP_ZIP.meta" <<'PY'
import sys, xml.etree.ElementTree as ET

appcast, version = sys.argv[1], sys.argv[2]
tree = ET.parse(appcast)
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}

for item in tree.getroot().findall("./channel/item"):
    sv = item.findtext("sparkle:shortVersionString", default="", namespaces=ns)
    if sv == version:
        enc = item.find("enclosure")
        url = enc.get("url")
        sig = enc.get("{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature")
        length = enc.get("length")
        if not all([url, sig, length]):
            sys.exit(f"Missing url/signature/length for version {version}")
        print(url)
        print(sig)
        print(length)
        sys.exit(0)

sys.exit(f"No appcast entry for version {version}")
PY

readarray -t META <"$TMP_ZIP.meta"
URL="${META[0]}"
SIG="${META[1]}"
LEN_EXPECTED="${META[2]}"

echo "Downloading: $URL"
curl -fSL -o "$TMP_ZIP" "$URL"

LEN_ACTUAL=$(stat -f%z "$TMP_ZIP")
if [[ "$LEN_ACTUAL" != "$LEN_EXPECTED" ]]; then
    echo "Length mismatch: expected $LEN_EXPECTED, got $LEN_ACTUAL" >&2
    exit 1
fi

echo "Verifying signature..."
sign_update --verify "$TMP_ZIP" "$SIG"
echo "Appcast entry for $VERSION verified."
