#!/usr/bin/env bash
set -euo pipefail

# Migration script: Download all podcast audio/images from acast and upload to MinIO
# Run this once before deploying the K8s podcast feed service.
#
# Prerequisites:
#   - curl
#   - mc (MinIO client): https://min.io/docs/minio/linux/reference/minio-mc.html
#   - Access to MinIO API (either via port-forward or direct)
#
# Usage:
#   # 1. Port-forward MinIO (in another terminal):
#   #    kubectl -n simon-frey-com port-forward svc/minio-api 9000:9000
#   #
#   # 2. Get credentials:
#   #    cd /home/oli/simon_sre_projects/hetzner_cloud_k8s
#   #    MINIO_USER=$(terraform output -raw minio_root_user)
#   #    MINIO_PASS=$(terraform output -raw minio_root_password)
#   #
#   # 3. Run:
#   #    MINIO_ENDPOINT=http://localhost:9000 MINIO_USER=$MINIO_USER MINIO_PASS=$MINIO_PASS ./scripts/migrate-podcasts.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_DIR="/tmp/podcast-migration"
DOCKER_DATA_DIR="$REPO_ROOT/docker/podcast-feeds/data"

STARTUPPIRATEN_SHOW_ID="66c47e31a294c7a662d49dfc"
SWPODCAST_SHOW_ID="66c2f1cbbc2cd0e1690dd4b1"

STARTUPPIRATEN_ACAST_URL="https://feeds.acast.com/public/shows/$STARTUPPIRATEN_SHOW_ID"
SWPODCAST_ACAST_URL="https://feeds.acast.com/public/shows/$SWPODCAST_SHOW_ID"

MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://localhost:9000}"
MINIO_USER="${MINIO_USER:-}"
MINIO_PASS="${MINIO_PASS:-}"

mkdir -p "$WORK_DIR"/{startuppiraten,swpodcast}/{audio,images}
mkdir -p "$DOCKER_DATA_DIR"

echo "=== Step 1: Download RSS feeds from acast ==="

curl -sL "$STARTUPPIRATEN_ACAST_URL" -o "$WORK_DIR/startuppiraten_feed_raw.xml"
echo "Downloaded startuppiraten feed: $(wc -c < "$WORK_DIR/startuppiraten_feed_raw.xml") bytes"

curl -sL "$SWPODCAST_ACAST_URL" -o "$WORK_DIR/swpodcast_feed_raw.xml"
echo "Downloaded swpodcast feed: $(wc -c < "$WORK_DIR/swpodcast_feed_raw.xml") bytes"

echo ""
echo "=== Step 2: Extract and download audio files ==="

download_audio() {
    local feed_xml="$1"
    local output_dir="$2"
    local podcast_name="$3"

    # Extract enclosure URLs
    local urls
    urls=$(grep -oP '<enclosure[^>]*url="[^"]*"' "$feed_xml" | grep -oP 'url="\K[^"]+')

    local total
    total=$(echo "$urls" | wc -l)
    local count=0

    echo "Downloading $total audio files for $podcast_name..."

    while IFS= read -r url; do
        count=$((count + 1))
        # Extract episode ID from URL: .../e/<episode_id>/media.mp3
        local episode_id
        episode_id=$(echo "$url" | grep -oP '/e/\K[^/]+')
        local filename="${episode_id}.mp3"
        local output_path="$output_dir/$filename"

        if [[ -f "$output_path" ]]; then
            echo "  [$count/$total] Skipping $filename (already exists)"
            continue
        fi

        echo "  [$count/$total] Downloading $filename..."
        if curl -sL -o "$output_path" "$url"; then
            local size
            size=$(wc -c < "$output_path")
            echo "    -> $(( size / 1024 / 1024 )) MB"
        else
            echo "    -> FAILED to download $url"
        fi
    done <<< "$urls"
}

download_audio "$WORK_DIR/startuppiraten_feed_raw.xml" "$WORK_DIR/startuppiraten/audio" "Startuppiraten"
download_audio "$WORK_DIR/swpodcast_feed_raw.xml" "$WORK_DIR/swpodcast/audio" "SWPodcast"

echo ""
echo "=== Step 3: Extract and download image files ==="

download_images() {
    local feed_xml="$1"
    local output_dir="$2"
    local podcast_name="$3"

    # Extract all pippa.io image URLs (from itunes:image href and <url> tags)
    local urls
    urls=$(grep -oP 'https://assets\.pippa\.io/shows/[^"<]+' "$feed_xml" | sort -u)

    local total
    total=$(echo "$urls" | wc -l)
    local count=0

    echo "Downloading $total image files for $podcast_name..."

    while IFS= read -r url; do
        count=$((count + 1))
        local filename
        filename=$(basename "$url")
        local output_path="$output_dir/$filename"

        if [[ -f "$output_path" ]]; then
            echo "  [$count/$total] Skipping $filename (already exists)"
            continue
        fi

        echo "  [$count/$total] Downloading $filename..."
        curl -sL -o "$output_path" "$url" || echo "    -> FAILED"
    done <<< "$urls"
}

download_images "$WORK_DIR/startuppiraten_feed_raw.xml" "$WORK_DIR/startuppiraten/images" "Startuppiraten"
download_images "$WORK_DIR/swpodcast_feed_raw.xml" "$WORK_DIR/swpodcast/images" "SWPodcast"

echo ""
echo "=== Step 4: Rewrite URLs in feed XML ==="

rewrite_feed() {
    local input_xml="$1"
    local output_xml="$2"
    local podcast_slug="$3"  # startuppiraten or swpodcast
    local show_id="$4"

    cp "$input_xml" "$output_xml"

    # Rewrite audio URLs: sphinx.acast.com/.../e/<id>/media.mp3 -> simon-frey.com/files/podcasts/<slug>/<id>.mp3
    # Use sed to replace each unique audio URL
    local urls
    urls=$(grep -oP '<enclosure[^>]*url="[^"]*"' "$input_xml" | grep -oP 'url="\K[^"]+')

    while IFS= read -r url; do
        local episode_id
        episode_id=$(echo "$url" | grep -oP '/e/\K[^/]+')
        local new_url="https://simon-frey.com/files/podcasts/${podcast_slug}/${episode_id}.mp3"
        # Escape special chars for sed
        local escaped_url
        escaped_url=$(printf '%s' "$url" | sed 's/[&/\]/\\&/g')
        local escaped_new
        escaped_new=$(printf '%s' "$new_url" | sed 's/[&/\]/\\&/g')
        sed -i "s|${escaped_url}|${escaped_new}|g" "$output_xml"
    done <<< "$urls"

    # Rewrite image URLs: assets.pippa.io/shows/<show_id>/<filename> -> simon-frey.com/files/podcasts/<slug>/images/<filename>
    sed -i "s|https://assets.pippa.io/shows/${show_id}/|https://simon-frey.com/files/podcasts/${podcast_slug}/images/|g" "$output_xml"

    echo "Rewrote URLs in $output_xml"
}

rewrite_feed "$WORK_DIR/startuppiraten_feed_raw.xml" "$DOCKER_DATA_DIR/startuppiraten_feed.xml" "startuppiraten" "$STARTUPPIRATEN_SHOW_ID"
rewrite_feed "$WORK_DIR/swpodcast_feed_raw.xml" "$DOCKER_DATA_DIR/swpodcast_feed.xml" "swpodcast" "$SWPODCAST_SHOW_ID"

echo ""
echo "=== Step 5: Upload to MinIO ==="

if [[ -z "$MINIO_USER" || -z "$MINIO_PASS" ]]; then
    echo "MINIO_USER and MINIO_PASS not set. Skipping upload."
    echo "To upload manually later, run:"
    echo "  mc alias set k8sminio $MINIO_ENDPOINT \$MINIO_USER \$MINIO_PASS"
    echo "  mc cp --recursive $WORK_DIR/startuppiraten/audio/ k8sminio/public/podcasts/startuppiraten/"
    echo "  mc cp --recursive $WORK_DIR/startuppiraten/images/ k8sminio/public/podcasts/startuppiraten/images/"
    echo "  mc cp --recursive $WORK_DIR/swpodcast/audio/ k8sminio/public/podcasts/swpodcast/"
    echo "  mc cp --recursive $WORK_DIR/swpodcast/images/ k8sminio/public/podcasts/swpodcast/images/"
else
    echo "Configuring MinIO client..."
    mc alias set k8sminio "$MINIO_ENDPOINT" "$MINIO_USER" "$MINIO_PASS"

    # Create podcasts directories in the public bucket
    echo "Uploading startuppiraten audio..."
    mc cp --recursive "$WORK_DIR/startuppiraten/audio/" k8sminio/public/podcasts/startuppiraten/
    echo "Uploading startuppiraten images..."
    mc cp --recursive "$WORK_DIR/startuppiraten/images/" k8sminio/public/podcasts/startuppiraten/images/
    echo "Uploading swpodcast audio..."
    mc cp --recursive "$WORK_DIR/swpodcast/audio/" k8sminio/public/podcasts/swpodcast/
    echo "Uploading swpodcast images..."
    mc cp --recursive "$WORK_DIR/swpodcast/images/" k8sminio/public/podcasts/swpodcast/images/

    echo "Upload complete!"
    echo "Verify at: https://simon-frey.com/files/podcasts/"
fi

echo ""
echo "=== Done ==="
echo "Rewritten feed XML files saved to: $DOCKER_DATA_DIR/"
echo "Downloaded files in: $WORK_DIR/"
echo ""
echo "Total audio files:"
echo "  Startuppiraten: $(ls "$WORK_DIR/startuppiraten/audio/" | wc -l)"
echo "  SWPodcast: $(ls "$WORK_DIR/swpodcast/audio/" | wc -l)"
echo "Total size:"
echo "  Startuppiraten: $(du -sh "$WORK_DIR/startuppiraten/audio/" | cut -f1)"
echo "  SWPodcast: $(du -sh "$WORK_DIR/swpodcast/audio/" | cut -f1)"
