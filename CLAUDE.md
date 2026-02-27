# CLAUDE.md — Image Generator Skill

## Project Structure

```
.claude/skills/image-generator/
├── skill.md                 # Skill definition (loaded by Claude Code)
├── .env                     # Runtime config (GEMINI_API_KEY, GEMINI_BASE_URL)
├── .env.example             # Config template
└── scripts/
    ├── env_setup.sh         # Shared env loader — sourced by all shell scripts
    ├── generate_image.sh    # Text → image
    ├── edit_image.sh        # Image editing (1-14 inputs)
    ├── upload_file.sh       # Files API resumable upload
    ├── triangulation_gen.sh # Transparent PNG (triangulation matting workflow)
    └── transparent_png.py   # Alpha extraction post-processor (4 modes)
```

## Key Conventions

- All shell scripts source `env_setup.sh` for shared config and utilities (`find_python`, `detect_mime`, `encode_base64`)
- `API_BASE_URL` defaults to `https://generativelanguage.googleapis.com`; overridden by `GEMINI_BASE_URL`
- JSON payloads are built via `python3 -c json.dump(...)` to avoid bash quoting issues
- All API calls use `curl -s --max-time 300` with retry logic
- Scripts print progress to stdout and errors to stderr
- `upload_file.sh` prints only the `file_uri` to stdout (for piping)

## Transparent PNG Architecture

Two-mode system with auto-selection based on prompt keywords:

1. **Triangulation Matting** (`triangulation_gen.sh` → `transparent_png.py --triangulation`)
   - Generates on two backgrounds, computes per-pixel alpha via compositing equation
   - Background colors chosen from 6-color palette with conflict avoidance
   - CRITICAL REQUIREMENTS appended in the script (lines 72-79) — includes anti-frame rule

2. **rembg AI** (`transparent_png.py --use-rembg`)
   - Single generation with chroma key background
   - CRITICAL REQUIREMENTS template defined in `skill.md` Mode B section

## When Editing Scripts

- `triangulation_gen.sh` line 72-79: The `GEN_PROMPT` template appends CRITICAL REQUIREMENTS to every user prompt. Changes here affect all triangulation generations.
- `transparent_png.py`: Has 4 modes (`--triangulation`, `--color-distance`, `--use-rembg`, default HSV). The triangulation mode is the primary path.
- `skill.md`: Contains Mode B's prompt template and the AI caller guidance for Mode A. This is the document Claude Code reads when the skill is invoked.

## Testing

Generate a test image and visually inspect:

```bash
# Triangulation (semi-transparent effects)
bash .claude/skills/image-generator/scripts/triangulation_gen.sh \
  --prompt "A glowing orb" \
  --bg1 "#FF0000" --bg2 "#0000FF" \
  --output /tmp/test_tri.png --size "1K"

# rembg (solid edges)
bash .claude/skills/image-generator/scripts/generate_image.sh \
  --prompt "A red apple on solid chroma key green #00FF00 background" \
  --output /tmp/test_raw.png --size "1K"
python3 .claude/skills/image-generator/scripts/transparent_png.py \
  /tmp/test_raw.png /tmp/test_rembg.png --use-rembg
```

Verify: no white corners, no frame artifacts, clean alpha edges.

## Common Pitfalls

- **White corners**: Gemini may wrap subjects in rounded-rect frames. The anti-frame rule (CRITICAL REQUIREMENTS #6) prevents this. If it recurs, strengthen the prompt.
- **503 / empty responses**: Proxy (`GEMINI_BASE_URL`) can go unresponsive. Scripts have retry logic but may ultimately fail.
- **Base64 timeouts**: Large images should use `--use-files-api` flag in `edit_image.sh`.
- **Background color clashing**: If subject color matches background color, triangulation produces artifacts. The smart palette in `skill.md` handles this.
