#!/usr/bin/env bash
set -euo pipefail

# triangulation_gen.sh — Generate a transparent PNG using triangulation matting.
#
# Workflow:
#   1. Generate image on bg1-color background
#   2. Upload via Files API
#   3. Edit background to bg2-color via Gemini
#   4. Combine with transparent_png.py --triangulation
#
# Usage:
#   triangulation_gen.sh --prompt "..." --bg1 "#FFFFFF" --bg2 "#000000" --output out.png \
#     [--size 1K] [--aspect 1:1] [--max-retries 2]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env_setup.sh"

# ── Parse arguments ──────────────────────────────────────────────────────────
PROMPT=""
BG1="#FFFFFF"
BG2="#000000"
OUTPUT=""
SIZE="1K"
ASPECT="1:1"
MAX_RETRIES=2

while [[ $# -gt 0 ]]; do
  case $1 in
    --prompt)  PROMPT="$2"; shift 2 ;;
    --bg1)     BG1="$2"; shift 2 ;;
    --bg2)     BG2="$2"; shift 2 ;;
    --output)  OUTPUT="$2"; shift 2 ;;
    --size)    SIZE="$2"; shift 2 ;;
    --aspect)  ASPECT="$2"; shift 2 ;;
    --max-retries) MAX_RETRIES="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$PROMPT" || -z "$OUTPUT" ]]; then
  echo "Usage: triangulation_gen.sh --prompt '...' --output path.png [--bg1 '#FFFFFF'] [--bg2 '#000000'] [--size 1K] [--aspect 1:1]" >&2
  exit 1
fi

# Convert hex to human-readable color name for prompts
hex_to_name() {
  local upper
  upper=$(echo "$1" | tr '[:lower:]' '[:upper:]')
  case "$upper" in
    "#FFFFFF"|"#FFF") echo "white" ;;
    "#000000"|"#000") echo "black" ;;
    "#FF0000"|"#F00") echo "red" ;;
    "#0000FF"|"#00F") echo "blue" ;;
    "#00FF00"|"#0F0") echo "green" ;;
    "#808080")        echo "gray" ;;
    *) echo "$1" ;;
  esac
}

BG1_NAME=$(hex_to_name "$BG1")
BG2_NAME=$(hex_to_name "$BG2")

PYTHON=$(find_python) || exit 1

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# ── Step 1: Generate image on BG1 ───────────────────────────────────────────
echo "[1/4] Generating image on ${BG1_NAME} background..."

GEN_PROMPT="${PROMPT}
CRITICAL REQUIREMENTS:
1. Background: pure solid ${BG1_NAME} (${BG1}), absolutely no other color in background.
2. The subject and all effects (glows, gradients, shadows) should be fully rendered.
3. Flat studio lighting, no shadows cast on background.
4. Centered composition with generous padding.
5. No reflections, no ground shadows, no gradients on background area.
6. Do NOT wrap the subject in any frame, border, rounded rectangle, card, or container shape. The subject and its effects must float directly on the solid background."

# Build JSON payload in temp file (avoids bash 3.2 $() quoting issues with multiline vars)
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
" "$GEN_PROMPT" "$ASPECT" "$SIZE" "$TMP_DIR/gen_payload.json"

curl -s --max-time 300 -X POST \
  "${API_BASE_URL}/v1beta/models/gemini-3-pro-image-preview:generateContent" \
  -H "x-goog-api-key: $GEMINI_API_KEY" \
  -H "Content-Type: application/json" \
  -d @"$TMP_DIR/gen_payload.json" > "$TMP_DIR/bg1_response.json"

python3 -c "
import json, base64, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
if 'error' in data:
    print('ERROR:', data['error']['message'], file=sys.stderr)
    sys.exit(1)
for part in data['candidates'][0]['content']['parts']:
    if 'inlineData' in part:
        with open(sys.argv[2], 'wb') as f:
            f.write(base64.b64decode(part['inlineData']['data']))
        print('OK')
        sys.exit(0)
print('ERROR: No image in response', file=sys.stderr)
sys.exit(1)
" "$TMP_DIR/bg1_response.json" "$TMP_DIR/bg1.png"
echo "  Saved ${BG1_NAME}-background image."

# ── Step 2: Upload via Files API ─────────────────────────────────────────────
echo "[2/4] Uploading image via Files API..."

FILE_URI=$("$SCRIPT_DIR/upload_file.sh" --image "$TMP_DIR/bg1.png" --display-name "triangulation_bg1")
echo "  File URI: ${FILE_URI}"

# ── Step 3: Edit background to BG2 ──────────────────────────────────────────
echo "[3/4] Editing background to ${BG2_NAME}..."

EDIT_PROMPT="Replace the ${BG1_NAME} background with pure solid ${BG2_NAME} (${BG2}). Keep everything else exactly unchanged — same subject, same position, same effects."

RETRY=0
while [[ $RETRY -le $MAX_RETRIES ]]; do
  # Build JSON payload in temp file
  python3 -c "
import json, sys
with open(sys.argv[3], 'w') as f:
    json.dump({
        'contents': [{'parts': [
            {'text': sys.argv[1]},
            {'file_data': {'mime_type': 'image/png', 'file_uri': sys.argv[2]}}
        ]}],
        'generationConfig': {'responseModalities': ['TEXT', 'IMAGE']}
    }, f)
" "$EDIT_PROMPT" "$FILE_URI" "$TMP_DIR/edit_payload.json"

  curl -s --max-time 300 -X POST \
    "${API_BASE_URL}/v1beta/models/gemini-3-pro-image-preview:generateContent" \
    -H "x-goog-api-key: $GEMINI_API_KEY" \
    -H "Content-Type: application/json" \
    -d @"$TMP_DIR/edit_payload.json" > "$TMP_DIR/bg2_response.json"

  RESULT=$(python3 -c "
import json, base64, sys, os
fpath = sys.argv[1]
out_path = sys.argv[2]
if os.path.getsize(fpath) == 0:
    print('EMPTY'); sys.exit(0)
with open(fpath) as f:
    data = json.load(f)
if 'error' in data:
    print('ERROR:' + data['error']['message'][:80]); sys.exit(0)
for part in data['candidates'][0]['content']['parts']:
    if 'inlineData' in part:
        with open(out_path, 'wb') as f:
            f.write(base64.b64decode(part['inlineData']['data']))
        print('OK'); sys.exit(0)
print('NO_IMAGE')
" "$TMP_DIR/bg2_response.json" "$TMP_DIR/bg2.png")

  if [[ "$RESULT" == "OK" ]]; then
    echo "  Saved ${BG2_NAME}-background image."
    break
  fi

  RETRY=$((RETRY + 1))
  if [[ $RETRY -le $MAX_RETRIES ]]; then
    echo "  Retry $RETRY/$MAX_RETRIES (${RESULT})..."
    sleep 3
  else
    echo "ERROR: Failed to generate ${BG2_NAME}-background image after $MAX_RETRIES retries: ${RESULT}" >&2
    exit 1
  fi
done

# ── Step 4: Triangulation matting ────────────────────────────────────────────
echo "[4/4] Applying triangulation matting..."

$PYTHON "$SCRIPT_DIR/transparent_png.py" \
  "$TMP_DIR/bg1.png" "$OUTPUT" \
  --triangulation --bg2 "$TMP_DIR/bg2.png" \
  --bg1-color "$BG1" --bg2-color "$BG2"

echo "Done: $OUTPUT"
