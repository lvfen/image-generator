---
name: Image Generator
description: Generate and edit images using Gemini's Nano Banana Pro model (gemini-3-pro-image-preview). Use this skill when the user asks you to generate images, create visuals, edit photos, create logos, generate product mockups, or perform any image generation/editing task.
allowed-tools: Read, Write, Bash, WebFetch
---

# Image Generator

This skill generates and edits images using Google's Gemini Nano Banana Pro model (`gemini-3-pro-image-preview`).

## IMPORTANT: Setup Required

The `GEMINI_API_KEY` is required. It can be configured in **two ways** (checked in order):

1. **Environment variable** (takes priority): Export in your shell profile (`~/.zshrc`, `~/.bashrc`, etc.):
   ```bash
   export GEMINI_API_KEY="your_api_key_here"
   ```
2. **`.env` file** (fallback): Edit the `.env` file in this skill's directory (`SKILL_DIR/.env`):
   ```
   GEMINI_API_KEY=your_api_key_here
   GEMINI_BASE_URL=https://your-proxy.example.com
   ```

`GEMINI_BASE_URL` is **optional**. When set, all API requests are routed through this URL instead of directly to `https://generativelanguage.googleapis.com`. This is useful for proxy/relay setups.

Get a free API key from [Google AI Studio](https://aistudio.google.com/).

**The skill will not work without `GEMINI_API_KEY`.**

## Pre-flight Check

All scripts in `$SKILL_DIR/scripts/` automatically load configuration by sourcing `env_setup.sh`, which:
- Reads `GEMINI_API_KEY` and `GEMINI_BASE_URL` from the `.env` file (if not already set as env vars)
- Sets `API_BASE_URL` (defaults to `https://generativelanguage.googleapis.com`)
- Provides shared utilities: `find_python()`, `detect_mime()`, `encode_base64()`

To use in a custom script:
```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env_setup.sh"
```

If `GEMINI_API_KEY` is missing, all scripts will error with a clear message. Tell the user to set it using the instructions above.

## Scripts Reference

All operational scripts live in `$SKILL_DIR/scripts/`:

| Script | Purpose | Key Options |
|--------|---------|-------------|
| `env_setup.sh` | Source-able env loader (shared by all scripts) | — |
| `generate_image.sh` | Text-to-image generation | `--prompt`, `--output`, `--size`, `--aspect` |
| `edit_image.sh` | Edit 1-14 images | `--prompt`, `--image` (repeatable), `--output`, `--use-files-api` |
| `upload_file.sh` | Upload image via Files API | `--image`, `--display-name`; prints `file_uri` to stdout |
| `triangulation_gen.sh` | Transparent PNG via triangulation matting | `--prompt`, `--bg1`, `--bg2`, `--output`, `--size`, `--aspect` |
| `transparent_png.py` | Post-processing: alpha extraction from images | `--triangulation`, `--color-distance`, `--use-rembg` |

## Configuration

**Model**: `gemini-3-pro-image-preview`

**API Key**: Read from `GEMINI_API_KEY` environment variable, falls back to `.env` file in skill directory

**Base URL**: Read from `GEMINI_BASE_URL` environment variable or `.env` file. Optional — defaults to `https://generativelanguage.googleapis.com`. When set, all requests route through this URL as a proxy/relay

## Iterating on User-Provided Images

When the user provides a path to an image they want to edit or iterate on, use `edit_image.sh`:

### Single Image Edit

```bash
bash "$SKILL_DIR/scripts/edit_image.sh" \
  --prompt "Add a santa hat to the person in this image" \
  --image /path/to/user/image.png \
  --output edited_output.png
```

The script handles MIME detection, base64 encoding, JSON payload construction, API call with retry, and response extraction.

### Multi-Image Input (Combine/Compose)

Use repeatable `--image` flags (up to 14 images):

```bash
bash "$SKILL_DIR/scripts/edit_image.sh" \
  --prompt "Put the dress from the first image on the person in the second image" \
  --image /path/to/dress.png \
  --image /path/to/model.png \
  --output composed_output.png
```

### Large Images (Files API)

For large images that may cause base64 payload timeouts, use `--use-files-api`:

```bash
bash "$SKILL_DIR/scripts/edit_image.sh" \
  --prompt "Make the background a sunset beach" \
  --image /path/to/large_image.png \
  --output edited_output.png \
  --use-files-api
```

## Transparent PNG Generation

Gemini cannot natively output RGBA. This workflow generates transparent PNGs using two strategies:
- **Triangulation matting** — best quality, for subjects with semi-transparent effects (glows, gradients, shadows)
- **rembg AI removal** — simpler, for subjects with clean/solid edges

### When to Trigger

Activate when the user's prompt contains ANY of:

- **Chinese**: `透明`, `透明背景`, `抠图`, `免抠`
- **English**: `transparent`, `transparent background`, `alpha channel`, `cutout`, `no background`, `remove background`, `PNG with transparency`

### Step 1: Choose Mode

Scan the user's prompt for **semi-transparent effect keywords**. If ANY are present → use **Triangulation Matting**. Otherwise → use **rembg AI**.

**Triangulation trigger keywords:**
- **Chinese**: `渐变`, `光晕`, `发光`, `半透明`, `玻璃`, `透光`, `阴影`, `模糊边缘`, `柔光`, `霓虹`, `光效`, `辉光`, `荧光`, `磨砂`, `烟雾`
- **English**: `gradient`, `glow`, `aura`, `semi-transparent`, `translucent`, `glass`, `shadow`, `soft edge`, `neon`, `blur`, `haze`, `smoke`, `frost`, `luminous`

### Mode A: Triangulation Matting (Semi-Transparent Effects)

#### A.1: Select Background Color Pair

Analyze the prompt to identify subject colors that could clash with background colors. Use this palette:

| Color  | HEX       | Exclude if prompt contains (CN)              | Exclude if prompt contains (EN)                |
|--------|-----------|----------------------------------------------|------------------------------------------------|
| White  | `#FFFFFF` | 白,雪,牛奶,云,米,象牙                        | white,snow,milk,cloud,ivory,cream               |
| Black  | `#000000` | 黑,暗,夜,煤,墨                               | black,dark,night,coal,ink                       |
| Red    | `#FF0000` | 红,火,血,玫瑰,番茄,樱桃                      | red,fire,blood,rose,cherry,crimson              |
| Blue   | `#0000FF` | 蓝,海,天空,水,冰,靛                          | blue,sea,sky,water,ice,indigo,ocean             |
| Green  | `#00FF00` | 绿,草,树,叶,森林,翡翠,抹茶                   | green,grass,tree,leaf,forest,emerald,matcha      |
| Gray   | `#808080` | 灰,银,金属,钢,铁                             | gray,silver,metal,steel,iron                    |

**Selection rules:**
1. Exclude colors whose keywords appear in the prompt
2. From remaining, pick the pair with maximum contrast. Preference: white+black > red+blue > green+gray
3. If white+black are both excluded → use red+blue
4. If only one of white/black excluded → pair the remaining with the next best (red or blue)

**Examples:**
- "企鹅" (black+white body) → exclude white, black → **red `#FF0000` + blue `#0000FF`**
- "红色火焰 with glow" → exclude red → **white `#FFFFFF` + black `#000000`**
- "银色金属球" → exclude gray → **white `#FFFFFF` + black `#000000`**

#### A.2: Run triangulation_gen.sh

**Prompt guidance**: When constructing the `--prompt`, do NOT add framing language like "app icon with rounded corners", "icon in a card", or "badge with border" unless the user **explicitly** requests a rounded rectangle or frame. If the user does want a framed shape, describe the frame as part of the subject itself (e.g., "a penguin inside a rounded square shape") so the frame is treated as foreground, not background.

```bash
bash "$SKILL_DIR/scripts/triangulation_gen.sh" \
  --prompt "User's original image description" \
  --bg1 "#FFFFFF" --bg2 "#000000" \
  --output OUTPUT_PATH \
  --size "1K" --aspect "1:1"
```

The script handles the full workflow:
1. Generates image on bg1 background via Gemini
2. Uploads via Files API
3. Edits background to bg2 via Gemini
4. Runs `transparent_png.py --triangulation` to compute exact alpha

#### A.3: If triangulation_gen.sh fails

If the API returns errors (503, timeout), fall back to single-image approach:
1. Generate with green chroma key background (or magenta if subject is green)
2. Process with `--color-distance` mode:

```bash
python3 "$SKILL_DIR/scripts/transparent_png.py" /tmp/gemini_raw.png OUTPUT_PATH \
  --color-distance --chroma-color "#00FF00" --near-threshold 40 --gaussian-blur 0.3
```

### Mode B: rembg AI Removal (Solid-Edge Subjects)

For subjects WITHOUT semi-transparent effects (icons, logos, objects with clean edges):

#### B.1: Generate with green chroma key

Append to the user's prompt:
```
[User's original description].
CRITICAL REQUIREMENTS:
1. Background: solid chroma key green, exactly hex #00FF00.
2. Lighting: flat studio lights, absolutely no shadows on background.
3. Subject must have a 2-pixel pure white border to prevent color bleeding.
4. Centered composition with generous padding.
5. No reflections, no ground shadows, no gradients on background.
6. Do NOT wrap the subject in any frame, border, rounded rectangle, card, or container shape. The subject must float directly on the chroma key background.
```

If the prompt contains green-related words (绿/green/plant/tree/leaf/forest/grass/emerald/matcha), use magenta `#FF00FF` instead.

#### B.2: Remove background with rembg

```bash
python3 "$SKILL_DIR/scripts/transparent_png.py" /tmp/gemini_raw.png OUTPUT_PATH --use-rembg
```

### Removing Background from Existing Images

If the user provides an existing image and wants to remove its background:

```bash
python3 "$SKILL_DIR/scripts/transparent_png.py" USER_IMAGE_PATH OUTPUT_PATH --use-rembg
```

### Files API Reference

Upload an image via the Files API (resumable upload). Returns the `file_uri` to stdout:

```bash
file_uri=$(bash "$SKILL_DIR/scripts/upload_file.sh" --image /tmp/source.png --display-name "my_image")
echo "$file_uri"  # e.g. https://generativelanguage.googleapis.com/v1beta/files/abc123
```

The `edit_image.sh` script uses this automatically when `--use-files-api` is passed.

## Capabilities

### Text-to-Image Generation
- Generate high-quality images from text descriptions
- Support for photorealistic, stylized, and artistic outputs
- Accurate text rendering in images (logos, infographics, diagrams)

### Image Editing
- Add or remove elements from images
- Inpainting with semantic masking (edit specific parts)
- Style transfer (apply artistic styles to photos)
- Multi-image composition (combine elements from multiple images)

### Advanced Features
- **High Resolution**: 1K, 2K, or 4K output
- **Aspect Ratios**: 1:1, 2:3, 3:2, 3:4, 4:3, 4:5, 5:4, 9:16, 16:9, 21:9
- **Google Search Grounding**: Generate images based on real-time data
- **Multi-turn Editing**: Iteratively refine images through conversation
- **Up to 14 Reference Images**: Combine multiple inputs for complex compositions
- **Transparent PNG**: Chroma key generation + post-processing for true alpha transparency (HSV color key or rembg AI)

## API Usage

### Basic Text-to-Image (Python)

```python
import os
from google import genai
from google.genai import types

# Build client options: use base_url for proxy if configured
client_kwargs = {"api_key": os.environ.get("GEMINI_API_KEY")}
base_url = os.environ.get("GEMINI_BASE_URL")
if base_url:
    client_kwargs["http_options"] = {"base_url": base_url}

client = genai.Client(**client_kwargs)

response = client.models.generate_content(
    model="gemini-3-pro-image-preview",
    contents=["Your prompt here"],
    config=types.GenerateContentConfig(
        response_modalities=['TEXT', 'IMAGE'],
        image_config=types.ImageConfig(
            aspect_ratio="16:9",  # Optional
            image_size="2K"       # Optional: "1K", "2K", "4K"
        )
    )
)

for part in response.parts:
    if part.text is not None:
        print(part.text)
    elif part.inline_data is not None:
        image = part.as_image()
        image.save("generated_image.png")
```

### Basic Text-to-Image (JavaScript)

```javascript
import { GoogleGenAI } from "@google/genai";
import * as fs from "node:fs";

const options = { apiKey: process.env.GEMINI_API_KEY };
if (process.env.GEMINI_BASE_URL) {
    options.httpOptions = { baseUrl: process.env.GEMINI_BASE_URL };
}
const ai = new GoogleGenAI(options);

const response = await ai.models.generateContent({
    model: "gemini-3-pro-image-preview",
    contents: "Your prompt here",
    config: {
        responseModalities: ['TEXT', 'IMAGE'],
        imageConfig: {
            aspectRatio: "16:9",
            imageSize: "2K"
        }
    }
});

for (const part of response.candidates[0].content.parts) {
    if (part.text) {
        console.log(part.text);
    } else if (part.inlineData) {
        const buffer = Buffer.from(part.inlineData.data, "base64");
        fs.writeFileSync("generated_image.png", buffer);
    }
}
```

### REST API (curl)

```bash
bash "$SKILL_DIR/scripts/generate_image.sh" \
  --prompt "Your prompt here" \
  --output output.png \
  --aspect "16:9" \
  --size "2K"
```

The script handles JSON payload construction (via `python3 -c json.dump()`), API call with retry, and response extraction.

### Image Editing (with input image)

```python
import os
from google import genai
from google.genai import types
from PIL import Image

client_kwargs = {"api_key": os.environ.get("GEMINI_API_KEY")}
base_url = os.environ.get("GEMINI_BASE_URL")
if base_url:
    client_kwargs["http_options"] = {"base_url": base_url}
client = genai.Client(**client_kwargs)

input_image = Image.open('input.png')
prompt = "Add a wizard hat to the cat in this image"

response = client.models.generate_content(
    model="gemini-3-pro-image-preview",
    contents=[prompt, input_image],
    config=types.GenerateContentConfig(
        response_modalities=['TEXT', 'IMAGE']
    )
)

for part in response.parts:
    if part.inline_data is not None:
        image = part.as_image()
        image.save("edited_image.png")
```

### Multi-Image Composition

```python
import os
from google import genai
from google.genai import types
from PIL import Image

client_kwargs = {"api_key": os.environ.get("GEMINI_API_KEY")}
base_url = os.environ.get("GEMINI_BASE_URL")
if base_url:
    client_kwargs["http_options"] = {"base_url": base_url}
client = genai.Client(**client_kwargs)

image1 = Image.open('dress.png')
image2 = Image.open('model.png')
prompt = "Put the dress from the first image on the model from the second image"

response = client.models.generate_content(
    model="gemini-3-pro-image-preview",
    contents=[image1, image2, prompt],
    config=types.GenerateContentConfig(
        response_modalities=['TEXT', 'IMAGE'],
        image_config=types.ImageConfig(
            aspect_ratio="3:4",
            image_size="2K"
        )
    )
)
```

### With Google Search Grounding

```python
import os
from google import genai
from google.genai import types

client_kwargs = {"api_key": os.environ.get("GEMINI_API_KEY")}
base_url = os.environ.get("GEMINI_BASE_URL")
if base_url:
    client_kwargs["http_options"] = {"base_url": base_url}
client = genai.Client(**client_kwargs)

response = client.models.generate_content(
    model="gemini-3-pro-image-preview",
    contents="Visualize the current weather forecast for San Francisco",
    config=types.GenerateContentConfig(
        response_modalities=['TEXT', 'IMAGE'],
        image_config=types.ImageConfig(aspect_ratio="16:9"),
        tools=[{"google_search": {}}]
    )
)
```

## Prompting Best Practices

### 1. Be Descriptive, Not Keyword-Based
Instead of: `cat, wizard hat, cute`
Write: `A fluffy orange cat wearing a small knitted wizard hat, sitting on a wooden floor with soft natural lighting from a window`

### 2. Specify Style and Mood
- Photography terms: "shot with 85mm lens", "soft bokeh background", "golden hour lighting"
- Artistic styles: "in the style of Van Gogh", "minimalist illustration", "photorealistic"
- Mood: "warm and cozy atmosphere", "dramatic noir lighting"

### 3. For Text in Images
Be explicit about:
- The exact text to render
- Font style (descriptively): "clean, bold, sans-serif font"
- Placement and size

### 4. For Editing
- Describe what to change and what to preserve
- Use "keep everything else unchanged"
- Reference specific elements clearly

### 5. For Product/Commercial Images
Mention:
- Lighting setup: "three-point softbox lighting"
- Background: "clean white studio background"
- Camera angle: "slightly elevated 45-degree shot"

## Resolution and Aspect Ratio Reference

| Aspect Ratio | 1K Resolution | 2K Resolution | 4K Resolution |
|--------------|---------------|---------------|---------------|
| 1:1          | 1024x1024     | 2048x2048     | 4096x4096     |
| 16:9         | 1376x768      | 2752x1536     | 5504x3072     |
| 9:16         | 768x1376      | 1536x2752     | 3072x5504     |
| 3:2          | 1264x848      | 2528x1696     | 5056x3392     |
| 2:3          | 848x1264      | 1696x2528     | 3392x5056     |

## Common Use Cases

### Logo Creation
```
Create a modern, minimalist logo for a coffee shop called 'The Daily Grind'.
The text should be in a clean, bold, sans-serif font.
Black and white color scheme. Put the logo in a circle.
```

### Product Photography
```
A high-resolution, studio-lit product photograph of a minimalist ceramic
coffee mug in matte black on a polished concrete surface. Three-point
softbox lighting with soft, diffused highlights. Slightly elevated
45-degree camera angle. Sharp focus on steam rising from the coffee.
```

### Style Transfer
```
Transform this photograph of a city street at night into Vincent van Gogh's
'Starry Night' style. Preserve the composition but render with swirling,
impasto brushstrokes and deep blues with bright yellows.
```

### Infographic
```
Create a vibrant infographic explaining photosynthesis as a recipe.
Show "ingredients" (sunlight, water, CO2) and "finished dish" (sugar/energy).
Style like a colorful kids' cookbook, suitable for 4th graders.
```

## Error Handling

Common issues:
- **No image returned**: Check that `response_modalities` includes `'IMAGE'`
- **Safety filters**: Some prompts may be blocked; try rephrasing
- **Rate limits**: Implement exponential backoff for retries
- **Large images**: For 4K, ensure sufficient timeout settings

## Dependencies

To use the Python SDK:
```bash
pip install google-genai pillow
```

For transparent PNG post-processing:
```bash
pip install numpy scipy  # Required for HSV chroma key mode
pip install rembg        # Optional: high-quality AI background removal
```

For JavaScript:
```bash
npm install @google/genai
```

## Important Notes

- All generated images include a SynthID watermark
- The model uses a "thinking" process for complex prompts
- For best text rendering, generate text first, then request image with that text
- Images are not stored by the API - save outputs locally