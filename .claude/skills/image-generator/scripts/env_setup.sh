#!/usr/bin/env bash
# env_setup.sh — Source this to load Gemini API configuration.
#
# Usage: source "$(dirname "$0")/env_setup.sh"
#
# Sets: GEMINI_API_KEY, GEMINI_BASE_URL, API_BASE_URL, SKILL_DIR, SCRIPT_DIR
# Provides: find_python() — find python with numpy+PIL

ENV_SETUP_ERROR=""

# Derive SCRIPT_DIR from this file's location
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  SCRIPT_DIR="${SCRIPT_DIR:-}"
fi

if [[ -z "$SCRIPT_DIR" ]]; then
  ENV_SETUP_ERROR="Cannot determine SCRIPT_DIR. Set it before sourcing env_setup.sh."
  echo "ERROR: $ENV_SETUP_ERROR" >&2
  return 1 2>/dev/null || true
fi

SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load from .env if env vars not already set
if [[ -f "$SKILL_DIR/.env" ]]; then
  [[ -z "${GEMINI_API_KEY:-}" ]] && \
    GEMINI_API_KEY=$(grep -E '^GEMINI_API_KEY=' "$SKILL_DIR/.env" | cut -d'=' -f2- | tr -d '[:space:]"'"'"'')
  [[ -z "${GEMINI_BASE_URL:-}" ]] && \
    GEMINI_BASE_URL=$(grep -E '^GEMINI_BASE_URL=' "$SKILL_DIR/.env" | cut -d'=' -f2- | tr -d '[:space:]"'"'"'')
fi

API_BASE_URL="${GEMINI_BASE_URL:-https://generativelanguage.googleapis.com}"

if [[ -z "${GEMINI_API_KEY:-}" ]]; then
  ENV_SETUP_ERROR="GEMINI_API_KEY is not set. Set via env var or in $SKILL_DIR/.env"
  echo "ERROR: $ENV_SETUP_ERROR" >&2
  return 1 2>/dev/null || true
fi

# Utility: find python with numpy+PIL
find_python() {
  for py in python3.10 python3.11 python3.12 python3 python; do
    if command -v "$py" >/dev/null 2>&1 && "$py" -c "import numpy, PIL" 2>/dev/null; then
      echo "$py"
      return 0
    fi
  done
  echo "ERROR: No python with numpy+PIL found. Install with: pip install numpy Pillow" >&2
  return 1
}

# Utility: detect MIME type from file extension
detect_mime() {
  case "$1" in
    *.png)          echo "image/png" ;;
    *.jpg|*.jpeg)   echo "image/jpeg" ;;
    *.webp)         echo "image/webp" ;;
    *.gif)          echo "image/gif" ;;
    *)              echo "image/png" ;;
  esac
}

# Utility: base64 encode (OS-aware)
encode_base64() {
  if [[ "$(uname)" == "Darwin" ]]; then
    base64 -i "$1"
  else
    base64 -w0 "$1"
  fi
}
