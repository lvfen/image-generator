#!/usr/bin/env bash
set -euo pipefail

# generate_image.sh — Generate an image from a text prompt via Gemini API.
#
# Usage:
#   generate_image.sh --prompt "..." --output path.png [--size 1K] [--aspect 1:1] [--max-retries 2]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env_setup.sh"

# ── Parse arguments ──────────────────────────────────────────────────────────
PROMPT=""
OUTPUT=""
SIZE="1K"
ASPECT="1:1"
MAX_RETRIES=2

while [[ $# -gt 0 ]]; do
  case $1 in
    --prompt)      PROMPT="$2"; shift 2 ;;
    --output)      OUTPUT="$2"; shift 2 ;;
    --size)        SIZE="$2"; shift 2 ;;
    --aspect)      ASPECT="$2"; shift 2 ;;
    --max-retries) MAX_RETRIES="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$PROMPT" || -z "$OUTPUT" ]]; then
  echo "Usage: generate_image.sh --prompt '...' --output path.png [--size 1K] [--aspect 1:1]" >&2
  exit 1
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# ── Generate ─────────────────────────────────────────────────────────────────
RETRY=0
while [[ $RETRY -le $MAX_RETRIES ]]; do
  # Build JSON payload in temp file (avoids bash 3.2 $() quoting issues)
  python3 -c "
import json, sys
with open(sys.argv[4], 'w') as f:
    json.dump({
        'contents': [{'parts': [{'text': sys.argv[1]}]}],
        'generationConfig': {
            'responseModalities': ['TEXT', 'IMAGE'],
            'imageConfig': {'aspectRatio': sys.argv[2], 'imageSize': sys.argv[3]}
        }
    }, f)
" "$PROMPT" "$ASPECT" "$SIZE" "$TMP_DIR/payload.json"

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
    echo "ERROR: Failed to generate image after $MAX_RETRIES retries: ${RESULT}" >&2
    exit 1
  fi
done
