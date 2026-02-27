# Image Generator Skill

A Claude Code skill for generating and editing images using Google's Gemini model (`gemini-3-pro-image-preview`), with advanced transparent PNG support via triangulation matting.

## Features

- **Text-to-Image**: Generate images from text descriptions (1K/2K/4K, multiple aspect ratios)
- **Image Editing**: Edit 1-14 images with natural language instructions
- **Transparent PNG**: Two strategies for true alpha transparency:
  - **Triangulation Matting** — mathematically precise, handles semi-transparent effects (glows, gradients, shadows)
  - **rembg AI** — fast single-pass removal for solid-edge subjects
- **Smart Mode Selection**: Auto-detects which transparency method to use based on prompt keywords
- **Smart Background Colors**: 6-color palette with conflict avoidance to prevent subject-background clashing
- **Files API**: Resumable upload for large images to avoid base64 timeouts

## Setup

1. Get a free API key from [Google AI Studio](https://aistudio.google.com/)

2. Configure the key (choose one):

   **Option A** — Environment variable (recommended):
   ```bash
   export GEMINI_API_KEY="your_api_key_here"
   ```

   **Option B** — `.env` file:
   ```bash
   cp .claude/skills/image-generator/.env.example .claude/skills/image-generator/.env
   # Edit .env and add your key
   ```

3. (Optional) Set `GEMINI_BASE_URL` to route requests through a proxy.

## Scripts

All scripts live in `.claude/skills/image-generator/scripts/`:

| Script | Purpose |
|--------|---------|
| `generate_image.sh` | Text-to-image generation |
| `edit_image.sh` | Edit/compose 1-14 images |
| `upload_file.sh` | Upload image via Files API (resumable) |
| `triangulation_gen.sh` | Transparent PNG via triangulation matting |
| `transparent_png.py` | Post-processing: alpha extraction from images |
| `env_setup.sh` | Shared config loader (sourced by all scripts) |

### Quick Examples

**Generate an image:**
```bash
bash .claude/skills/image-generator/scripts/generate_image.sh \
  --prompt "A minimalist logo for a coffee shop" \
  --output logo.png --size "2K" --aspect "1:1"
```

**Edit an image:**
```bash
bash .claude/skills/image-generator/scripts/edit_image.sh \
  --prompt "Add a sunset background" \
  --image photo.png --output edited.png
```

**Transparent PNG (triangulation):**
```bash
bash .claude/skills/image-generator/scripts/triangulation_gen.sh \
  --prompt "A glowing crystal orb" \
  --bg1 "#FFFFFF" --bg2 "#000000" \
  --output crystal.png --size "1K" --aspect "1:1"
```

**Remove background (rembg):**
```bash
python3 .claude/skills/image-generator/scripts/transparent_png.py \
  input.png output.png --use-rembg
```

## Dependencies

```bash
# Core
pip install google-genai pillow

# Transparent PNG post-processing
pip install numpy scipy

# AI background removal (optional)
pip install rembg
```

**System requirements:** Python 3.10+, Bash, curl

## How Transparent PNG Works

Gemini cannot natively output RGBA. This skill works around the limitation:

### Triangulation Matting (best quality)
1. Generate the image on background color A (e.g., red)
2. Edit the same image to background color B (e.g., blue)
3. Compute exact alpha per-pixel: `alpha = 1 - (I_A - I_B) / (A - B)`
4. Recover true foreground color: `F = (I - (1-alpha) * B) / alpha`

### rembg AI (simpler)
1. Generate with chroma key green background
2. Run pre-trained AI model to remove background

The skill auto-selects the method based on prompt keywords (e.g., "glow", "gradient" triggers triangulation).

## Resolution Reference

| Aspect Ratio | 1K | 2K | 4K |
|---|---|---|---|
| 1:1 | 1024x1024 | 2048x2048 | 4096x4096 |
| 16:9 | 1376x768 | 2752x1536 | 5504x3072 |
| 9:16 | 768x1376 | 1536x2752 | 3072x5504 |

## License

Internal skill — not for redistribution.
