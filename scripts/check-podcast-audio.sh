#!/usr/bin/env bash
set -euo pipefail

# Validate every audio enclosure in the live podcast feeds.
#
# For each unique enclosure URL it checks:
#   - HTTP 200
#   - Content-Length >= 1 MB (acast once returned 19-byte "MEDIAFILE_NOT_READY" bodies)
#   - Content-Length matches the enclosure length="" attribute
#   - ffprobe can decode the first MB as MP3
#
# Prerequisites: curl, ffprobe, python3
#
# Usage:
#   ./scripts/check-podcast-audio.sh                  # checks both live feeds
#   ./scripts/check-podcast-audio.sh <feed-url>...    # checks the given feeds
#
# Exits non-zero if any enclosure fails.

FEEDS=("$@")
if [[ ${#FEEDS[@]} -eq 0 ]]; then
    FEEDS=(https://swpodcastfeed.simon-frey.com/ https://startuppiratenfeed.simon-frey.com/)
fi

MIN_SIZE=$((1024 * 1024))
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

failures=0
checked=0

for feed in "${FEEDS[@]}"; do
    echo "=== $feed"
    curl -sSf "$feed" -o "$TMP_DIR/feed.xml"

    # url<TAB>length<TAB>title, deduplicated by URL (BestOf items reuse enclosures)
    python3 -I - "$TMP_DIR/feed.xml" > "$TMP_DIR/enclosures.tsv" <<'EOF'
import sys
import xml.etree.ElementTree as ET
seen = set()
for item in ET.parse(sys.argv[1]).getroot().iter("item"):
    enc = item.find("enclosure")
    if enc is None or enc.get("url") in seen:
        continue
    seen.add(enc.get("url"))
    title = (item.findtext("title") or "").replace("\t", " ")
    print(enc.get("url"), enc.get("length", ""), title, sep="\t")
EOF

    while IFS=$'\t' read -r url length title; do
        checked=$((checked + 1))
        problem=""
        read -r code size < <(curl -s -o /dev/null -I -w '%{http_code} %header{content-length}\n' "$url")
        size=${size:-0}
        if [[ "$code" != 200 ]]; then
            problem="HTTP $code"
        elif (( size < MIN_SIZE )); then
            problem="only $size bytes"
        elif [[ "$size" != "$length" ]]; then
            problem="length attr $length != Content-Length $size"
        elif ! curl -s -r 0-$((MIN_SIZE - 1)) "$url" -o "$TMP_DIR/head.mp3" \
            || ! ffprobe -v error -f mp3 -i "$TMP_DIR/head.mp3" -show_entries format=format_name -of csv=p=0 >/dev/null 2>&1; then
            problem="not decodable as MP3"
        fi
        if [[ -n "$problem" ]]; then
            failures=$((failures + 1))
            echo "  FAIL  $problem  $url  ($title)"
        fi
    done < "$TMP_DIR/enclosures.tsv"
done

echo ""
echo "Checked $checked enclosures, $failures failed."
[[ $failures -eq 0 ]]
