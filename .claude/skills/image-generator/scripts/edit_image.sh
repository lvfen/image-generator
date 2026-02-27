#!/usr/bin/env bash
set -euo pipefail

# edit_image.sh — Edit one or more images via Gemini API.
#
# Supports 1-14 input images. Uses inline base64 by default,
# or Files API with --use-files-api for large images.
#
# Usage:
#   edit_image.sh --prompt "..." --image path1.png [--image path2.png ...] --output path.png \
#     [--use-files-api] [--max-retries 2]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env_setup.sh"

# ── Parse arguments ──────────────────────────────────────────────────────────
PROMPT=""
IMAGES=()
OUTPUT=""
USE_FILES_API=false
MAX_RETRIES=2

while [[ $# -gt 0 ]]; do
  case $1 in
    --prompt)        PROMPT="$2"; shift 2 ;;
    --image)         IMAGES+=("$2"); shift 2 ;;
    --output)        OUTPUT="$2"; shift 2 ;;
    --use-files-api) USE_FILES_API=true; shift ;;
    --max-retries)   MAX_RETRIES="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$PROMPT" || ${#IMAGES[@]} -eq 0 || -z "$OUTPUT" ]]; then
  echo "Usage: edit_image.sh --prompt '...' --image path.png [--image path2.png] --output path.png [--use-files-api]" >&2
  exit 1
fi

# Validate all images exist
for img in "${IMAGES[@]}"; do
  if [[ ! -f "$img" ]]; then
    echo "ERROR: Image not found: $img" >&2
    exit 1
  fi
done

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# ── Prepare image data ───────────────────────────────────────────────────────
# Build a list of (mime_type, data_source) pairs for the Python JSON builder
IMG_ARGS=()

if [[ "$USE_FILES_API" == "true" ]]; then
  # Upload each image via Files API
  for i in "${!IMAGES[@]}"; do
    img="${IMAGES[$i]}"
    mime=$(detect_mime "$img")
    echo "Uploading image $((i+1))/${#IMAGES[@]}: $img ..." >&2
    file_uri=$("$SCRIPT_DIR/upload_file.sh" --image "$img" --display-name "edit_image_$i")
    IMG_ARGS+=("file" "$mime" "$file_uri")
  done
else
  # Base64 encode each image to temp files
  for i in "${!IMAGES[@]}"; do
    img="${IMAGES[$i]}"
    mime=$(detect_mime "$img")
    b64_file="$TMP_DIR/img_${i}.b64"
    encode_base64 "$img" > "$b64_file"
    IMG_ARGS+=("inline" "$mime" "$b64_file")
  done
fi

# ── Build JSON payload ───────────────────────────────────────────────────────
# Pass image info as args: mode mime data [mode mime data ...]
python3 -c "
import json, sys

prompt = sys.argv[1]
output = sys.argv[2]
args = sys.argv[3:]

parts = [{'text': prompt}]
i = 0
while i < len(args):
    mode, mime, data_src = args[i], args[i+1], args[i+2]
    if mode == 'file':
        parts.append({'file_data': {'mime_type': mime, 'file_uri': data_src}})
    else:  # inline
        with open(data_src) as f:
            b64 = f.read().strip()
        parts.append({'inline_data': {'mime_type': mime, 'data': b64}})
    i += 3

with open(output, 'w') as f:
    json.dump({
        'contents': [{'parts': parts}],
        'generationConfig': {'responseModalities': ['TEXT', 'IMAGE']}
    }, f)
" "$PROMPT" "$TMP_DIR/payload.json" "${IMG_ARGS[@]}"

# ── Call API with retry ──────────────────────────────────────────────────────
RETRY=0
while [[ $RETRY -le $MAX_RETRIES ]]; do
  curl -s --max-time 300 -X POST \
    "${API_BASE_URL}/v1beta/models/gemini-3-pro-image-preview:generateContent" \
    -H "x-goog-api-key: $GEMINI_API_KEY" \
    -H "Content-Type: application/json" \
    -d @"$TMP_DIR/payload.json" > "$TMP_DIR/response.json"

  RESULT=$(python3 -c "
import json, base64, sys, os
fpath = sys.argv[1]
out_path = sys.argv[2]
if os.path.getsize(fpath) == 0:
    print('EMPTY'); sys.exit(0)
with open(fpath) as f:
    data = json.load(f)
if 'error' in data:
    print('ERROR:' + data['error'].get('message','unknown')[:120]); sys.exit(0)
for part in data.get('candidates', [{}])[0].get('content', {}).get('parts', []):
    if 'inlineData' in part:
        with open(out_path, 'wb') as f:
            f.write(base64.b64decode(part['inlineData']['data']))
        print('OK'); sys.exit(0)
    elif 'text' in part:
        print('TEXT:' + part['text'][:80], file=sys.stderr)
print('NO_IMAGE')
" "$TMP_DIR/response.json" "$OUTPUT")

  if [[ "$RESULT" == "OK" ]]; then
    echo "Saved: $OUTPUT"
    exit 0
  fi

  RETRY=$((RETRY + 1))
  if [[ $RETRY -le $MAX_RETRIES ]]; then
    echo "Retry $RETRY/$MAX_RETRIES (${RESULT})..." >&2
    sleep 3
  else
    echo "ERROR: Failed to edit image after $MAX_RETRIES retries: ${RESULT}" >&2
    exit 1
  fi
done
