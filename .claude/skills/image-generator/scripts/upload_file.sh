#!/usr/bin/env bash
set -euo pipefail

# upload_file.sh — Upload an image via Gemini Files API (resumable upload).
#
# Prints the file_uri to stdout on success. All progress/errors go to stderr.
#
# Usage:
#   upload_file.sh --image path.png [--display-name "my_image"]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env_setup.sh"

# ── Parse arguments ──────────────────────────────────────────────────────────
IMAGE_PATH=""
DISPLAY_NAME="uploaded_image"

while [[ $# -gt 0 ]]; do
  case $1 in
    --image)        IMAGE_PATH="$2"; shift 2 ;;
    --display-name) DISPLAY_NAME="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$IMAGE_PATH" ]]; then
  echo "Usage: upload_file.sh --image path.png [--display-name \"name\"]" >&2
  exit 1
fi

if [[ ! -f "$IMAGE_PATH" ]]; then
  echo "ERROR: File not found: $IMAGE_PATH" >&2
  exit 1
fi

# ── Detect MIME type and file size ───────────────────────────────────────────
MIME_TYPE=$(detect_mime "$IMAGE_PATH")
NUM_BYTES=$(wc -c < "$IMAGE_PATH" | tr -d ' ')

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# ── Step 1: Initiate resumable upload ────────────────────────────────────────
echo "Uploading $IMAGE_PATH (${NUM_BYTES} bytes)..." >&2

curl -s "${API_BASE_URL}/upload/v1beta/files" \
  -H "x-goog-api-key: $GEMINI_API_KEY" \
  -D "$TMP_DIR/upload-header.tmp" \
  -H "X-Goog-Upload-Protocol: resumable" \
  -H "X-Goog-Upload-Command: start" \
  -H "X-Goog-Upload-Header-Content-Length: ${NUM_BYTES}" \
  -H "X-Goog-Upload-Header-Content-Type: ${MIME_TYPE}" \
  -H "Content-Type: application/json" \
  -d "{\"file\": {\"display_name\": \"${DISPLAY_NAME}\"}}" 2>/dev/null

upload_url=$(grep -i "x-goog-upload-url: " "$TMP_DIR/upload-header.tmp" | cut -d" " -f2 | tr -d "\r")
if [[ -z "$upload_url" ]]; then
  echo "ERROR: Failed to initiate upload — no upload URL in response headers." >&2
  exit 1
fi

# ── Step 2: Upload file data ────────────────────────────────────────────────
curl -s "${upload_url}" \
  -H "Content-Length: ${NUM_BYTES}" \
  -H "X-Goog-Upload-Offset: 0" \
  -H "X-Goog-Upload-Command: upload, finalize" \
  --data-binary "@${IMAGE_PATH}" 2>/dev/null > "$TMP_DIR/file_info.json"

# ── Extract file_uri ─────────────────────────────────────────────────────────
FILE_URI=$(python3 -c "
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    print(data['file']['uri'])
except (KeyError, json.JSONDecodeError) as e:
    print('ERROR: Failed to extract file URI: ' + str(e), file=sys.stderr)
    sys.exit(1)
" "$TMP_DIR/file_info.json")

if [[ -z "$FILE_URI" ]]; then
  echo "ERROR: Failed to upload file — no file URI returned." >&2
  exit 1
fi

echo "Uploaded: $FILE_URI" >&2
echo "$FILE_URI"
