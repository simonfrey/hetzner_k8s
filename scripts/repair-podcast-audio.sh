#!/usr/bin/env bash
set -euo pipefail

# Repair broken podcast audio objects in MinIO (public/podcasts/<podcast>/<id>.mp3).
#
# Background: during the 2026-10-03 migration acast's CDN sometimes returned a
# 19-byte "MEDIAFILE_NOT_READY" body with HTTP 200 instead of the MP3, and
# migrate-podcasts.sh uploaded those placeholders. The original uploads are
# still publicly available on acast's asset bucket (assets.pippa.io), so this
# script re-downloads them from there.
#
# For every <item> in docker/podcast-feeds/data/*_feed.xml it:
#   1. Checks the MinIO object (via the public URL). It is broken if it is
#      < 1 MB, ffprobe cannot decode it, or its duration is off by more than
#      5% from <itunes:duration> (acast also served some cut-short encodes).
#   2. Resolves the original file via <acast:episodeId>:
#      scripts/podcast-acast-audio-files.tsv for acast-native episodes,
#      <episode_id>.mp3 for episodes imported from Transistor.
#   3. Downloads it and validates size (>= 1 MB, matches Content-Length),
#      full ffmpeg decode, and duration within 5% of <itunes:duration>.
#   4. Uploads it to MinIO, overwriting the placeholder.
#
# Prerequisites: curl, ffmpeg/ffprobe, python3, aws CLI
#
# Usage:
#   # 1. Port-forward MinIO (in another terminal):
#   #    kubectl -n simon-frey-com port-forward svc/minio-api 9000:9000
#   #
#   # 2. Run (DRY_RUN=1 only reports, without downloading or uploading):
#   #    MINIO_PASS=$(terraform output -raw minio_root_password) ./scripts/repair-podcast-audio.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DATA_DIR="$REPO_ROOT/docker/podcast-feeds/data"
MAPPING="$SCRIPT_DIR/podcast-acast-audio-files.tsv"

PUBLIC_BASE="https://simon-frey.com/files/podcasts"
PIPPA_BASE="https://assets.pippa.io/shows"
MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://localhost:9000}"
MINIO_USER="${MINIO_USER:-admin}"
MINIO_PASS="${MINIO_PASS:-}"
DRY_RUN="${DRY_RUN:-0}"
MIN_SIZE=$((1024 * 1024))

if [[ "$DRY_RUN" != 1 && -z "$MINIO_PASS" ]]; then
    echo "MINIO_PASS not set (use DRY_RUN=1 to only report)" >&2
    exit 1
fi

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# podcast<TAB>show_id<TAB>object_id<TAB>acast_episode_id<TAB>duration_seconds<TAB>title
python3 -I - "$DATA_DIR" > "$WORK_DIR/items.tsv" <<'EOF'
import re, sys
for podcast in ("swpodcast", "startuppiraten"):
    xml = open(f"{sys.argv[1]}/{podcast}_feed.xml", encoding="utf-8").read()
    show_id = re.search(r"<acast:showId>([^<]+)", xml).group(1)
    for item in re.findall(r"<item>(.*?)</item>", xml, re.S):
        object_id = re.search(r'<enclosure url="[^"]+/([^/"]+)\.mp3"', item).group(1)
        episode_id = re.search(r"<acast:episodeId>([^<]+)", item).group(1)
        seconds = 0
        for part in re.search(r"<itunes:duration>([^<]+)", item).group(1).split(":"):
            seconds = seconds * 60 + int(part)
        title = re.search(r"<title>(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?</title>", item, re.S).group(1)
        print(podcast, show_id, object_id, episode_id, seconds, title.replace("\t", " "), sep="\t")
EOF

# Returns 0 if the duration of $1 (file or URL) is within 5% of $2 seconds
duration_matches() {
    local duration
    duration=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$1" </dev/null 2>/dev/null) || return 1
    python3 -I -c "import sys; d, e = float(sys.argv[1] or 0), int(sys.argv[2]); sys.exit(0 if e == 0 or abs(d - e) <= e * 0.05 else 1)" "$duration" "$2"
}

# Returns 0 if $1 is a decodable MP3 >= 1 MB whose duration is within 5% of $2 seconds
valid_mp3() {
    local file="$1" expected="$2" size
    size=$(stat -c %s "$file")
    (( size >= MIN_SIZE )) || return 1
    # Audio stream only: some originals have corrupt embedded cover art
    ffmpeg -nostdin -v error -xerror -i "$file" -map 0:a -f null - 2>/dev/null || return 1
    duration_matches "$file" "$expected"
}

repaired=0
failed=0
total=$(wc -l < "$WORK_DIR/items.tsv")

while IFS=$'\t' read -r -u 3 podcast show_id object_id episode_id seconds title; do
    url="$PUBLIC_BASE/$podcast/$object_id.mp3"
    size=$(curl -s -o /dev/null -I -w '%header{content-length}' "$url")
    size=${size:-0}
    if (( size >= MIN_SIZE )) && curl -s -r 0-$((MIN_SIZE - 1)) "$url" -o "$WORK_DIR/head.mp3" \
        && ffprobe -v error -f mp3 -i "$WORK_DIR/head.mp3" >/dev/null 2>&1 \
        && duration_matches "$url" "$seconds"; then
        continue
    fi

    filename=$(awk -F'\t' -v p="$podcast" -v e="$episode_id" '$1 == p && $2 == e { print $3 }' "$MAPPING")
    source="$PIPPA_BASE/$show_id/${filename:-$episode_id.mp3}"
    echo "BROKEN $podcast/$object_id.mp3 ($size bytes): $title"
    echo "  source: $source"
    [[ "$DRY_RUN" == 1 ]] && continue

    out="$WORK_DIR/$object_id.mp3"
    if ! curl -sSf --retry 5 --retry-delay 10 -o "$out" "$source"; then
        echo "  FAILED: download error"; failed=$((failed + 1)); continue
    fi
    if ! valid_mp3 "$out" "$seconds"; then
        echo "  FAILED: downloaded file did not validate ($(stat -c %s "$out") bytes)"; failed=$((failed + 1)); rm -f "$out"; continue
    fi
    AWS_ACCESS_KEY_ID="$MINIO_USER" AWS_SECRET_ACCESS_KEY="$MINIO_PASS" AWS_DEFAULT_REGION=us-east-1 \
        aws --endpoint-url "$MINIO_ENDPOINT" s3 cp --only-show-errors --content-type audio/mpeg \
        "$out" "s3://public/podcasts/$podcast/$object_id.mp3"
    echo "  repaired ($(stat -c %s "$out") bytes)"
    repaired=$((repaired + 1))
    rm -f "$out"
done 3< "$WORK_DIR/items.tsv"

echo ""
echo "Checked $total items: $repaired repaired, $failed failed."
[[ $failed -eq 0 ]]
