#!/usr/bin/env python3
"""Remove chroma key background from images and output transparent PNG."""

import argparse
import sys
from pathlib import Path


def hex_to_hsv_hue(hex_color: str) -> float:
    """Convert hex color to HSV hue in degrees (0-360)."""
    hex_color = hex_color.lstrip("#")
    if len(hex_color) not in (6, 8):
        raise ValueError(f"Invalid hex color: #{hex_color}. Expected 6 or 8 hex digits (e.g. #00FF00).")
    r, g, b = (int(hex_color[i : i + 2], 16) / 255.0 for i in (0, 2, 4))
    max_c = max(r, g, b)
    min_c = min(r, g, b)
    diff = max_c - min_c
    if diff == 0:
        return 0.0
    if max_c == r:
        hue = 60.0 * (((g - b) / diff) % 6)
    elif max_c == g:
        hue = 60.0 * (((b - r) / diff) + 2)
    else:
        hue = 60.0 * (((r - g) / diff) + 4)
    return hue % 360


def hex_to_rgb(hex_color: str) -> tuple:
    """Convert hex color string to (R, G, B) tuple of ints."""
    hex_color = hex_color.lstrip("#")
    if len(hex_color) not in (6, 8):
        raise ValueError(f"Invalid hex color: #{hex_color}. Expected 6 or 8 hex digits (e.g. #FFFFFF).")
    return tuple(int(hex_color[i : i + 2], 16) for i in (0, 2, 4))


def color_distance_remove(input_path, output_path, chroma_color, near_threshold, far_threshold, despill_strength, gaussian_blur):
    """Remove background using green-screen matting with proper alpha recovery.

    Uses the key-channel excess method for accurate alpha computation on
    chroma key backgrounds, then recovers true foreground colors via the
    Smith-Blinn matting equation: I = αF + (1-α)B.

    This correctly handles semi-transparent gradient edges (e.g., glows, auras)
    that blend into the chroma key background.
    """
    import numpy as np
    from PIL import Image

    img = Image.open(input_path).convert("RGBA")
    data = np.array(img, dtype=np.float64)

    # Parse chroma key background color
    hex_c = chroma_color.lstrip("#")
    bg_r, bg_g, bg_b = (int(hex_c[i : i + 2], 16) for i in (0, 2, 4))
    bg = np.array([bg_r, bg_g, bg_b], dtype=np.float64)

    R = data[:, :, 0]
    G = data[:, :, 1]
    B = data[:, :, 2]
    rgb = data[:, :, :3]

    # --- Auto-detect actual background color from corner samples ---
    h, w = R.shape
    corner_size = max(5, min(h, w) // 20)
    corners = np.concatenate([
        rgb[:corner_size, :corner_size].reshape(-1, 3),
        rgb[:corner_size, -corner_size:].reshape(-1, 3),
        rgb[-corner_size:, :corner_size].reshape(-1, 3),
        rgb[-corner_size:, -corner_size:].reshape(-1, 3),
    ], axis=0)
    actual_bg = np.median(corners, axis=0)  # robust to outliers

    # Determine key channel (the dominant channel of the chroma color)
    bg_channels = [bg_r, bg_g, bg_b]
    key_idx = int(np.argmax(bg_channels))

    channels = [R, G, B]
    key_ch = channels[key_idx]
    non_key_chs = [channels[i] for i in range(3) if i != key_idx]

    # --- Alpha computation using key-channel excess ---
    # For green screen: excess = G - max(R, B)
    # Normalize by the actual background's excess (not theoretical 255)
    actual_key = actual_bg[key_idx]
    actual_non_key_max = max(actual_bg[i] for i in range(3) if i != key_idx)
    bg_excess = actual_key - actual_non_key_max  # e.g., ~240 for real green bg

    max_non_key = np.maximum(non_key_chs[0], non_key_chs[1])
    key_excess = key_ch - max_non_key

    # Normalize against actual background excess
    # excess ≥ bg_excess → alpha=0 (background)
    # excess ≤ 0 → alpha=1 (foreground)
    alpha = 1.0 - np.clip(key_excess / max(bg_excess, 1.0), 0.0, 1.0)

    # Hard cutoff: pixels very close to actual background → fully transparent
    dist_to_actual_bg = np.sqrt(np.sum((rgb - actual_bg) ** 2, axis=2))
    alpha = np.where(dist_to_actual_bg < near_threshold, 0.0, alpha)

    # Also force alpha=0 for pixels with very high key excess (clearly background)
    alpha = np.where(key_excess > bg_excess * 0.7, 0.0, alpha)

    # Optional gaussian blur to smooth alpha edges
    if gaussian_blur > 0:
        from scipy.ndimage import gaussian_filter
        alpha = gaussian_filter(alpha, sigma=gaussian_blur)

    alpha = np.clip(alpha, 0.0, 1.0)

    # --- Foreground recovery via matting equation ---
    # F = (I - (1-α)B) / α
    # This removes background color bleed from semi-transparent pixels
    alpha_3ch = np.stack([alpha] * 3, axis=2)
    safe_alpha = np.where(alpha_3ch > 0.02, alpha_3ch, 1.0)
    fg = (rgb - (1.0 - alpha_3ch) * bg) / safe_alpha
    fg = np.clip(fg, 0, 255)

    # Apply recovered foreground to all non-fully-transparent pixels
    has_alpha = alpha > 0.01
    for c in range(3):
        data[:, :, c] = np.where(has_alpha, fg[:, :, c], 0)

    # Apply alpha channel
    data[:, :, 3] = np.clip(alpha * 255.0, 0, 255)

    result = Image.fromarray(data.astype(np.uint8), "RGBA")
    result.save(output_path, "PNG")
    print(f"Saved transparent PNG (color-distance matting): {output_path}")


def chroma_key_remove(input_path, output_path, chroma_color, hue_tolerance, saturation_min, gaussian_blur):
    """Remove background using HSV chroma key (legacy binary threshold mode)."""
    import numpy as np
    from PIL import Image

    img = Image.open(input_path).convert("RGBA")
    data = np.array(img)

    # Extract RGB and convert to HSV-like space using vectorized ops
    r, g, b, a = data[:, :, 0], data[:, :, 1], data[:, :, 2], data[:, :, 3]
    r_f, g_f, b_f = r / 255.0, g / 255.0, b / 255.0

    max_c = np.maximum(np.maximum(r_f, g_f), b_f)
    min_c = np.minimum(np.minimum(r_f, g_f), b_f)
    diff = max_c - min_c

    # Hue calculation (0-360 degrees)
    hue = np.zeros_like(diff)
    # Mutually exclusive masks to avoid overlapping assignments on tied channels
    mask_r = (max_c == r_f) & (diff > 0)
    mask_g = (max_c == g_f) & ~mask_r & (diff > 0)
    mask_b = (max_c == b_f) & ~mask_r & ~mask_g & (diff > 0)
    hue[mask_r] = 60.0 * (((g_f[mask_r] - b_f[mask_r]) / diff[mask_r]) % 6)
    hue[mask_g] = 60.0 * (((b_f[mask_g] - r_f[mask_g]) / diff[mask_g]) + 2)
    hue[mask_b] = 60.0 * (((r_f[mask_b] - g_f[mask_b]) / diff[mask_b]) + 4)
    hue = hue % 360

    # Saturation (0-255 scale)
    saturation = np.where(max_c > 0, (diff / max_c) * 255, 0).astype(np.uint8)

    # Value (0-255)
    value = (max_c * 255).astype(np.uint8)

    # Target hue from chroma color
    target_hue = hex_to_hsv_hue(chroma_color)

    # Background mask: hue match + high saturation + not too dark
    hue_diff = np.abs(hue - target_hue)
    hue_diff = np.minimum(hue_diff, 360 - hue_diff)  # wrap-around
    bg_mask = (hue_diff <= hue_tolerance) & (saturation >= saturation_min) & (value >= 40)

    # Edge gradient: dilate mask slightly for anti-aliasing
    from scipy.ndimage import binary_dilation, gaussian_filter
    dilated = binary_dilation(bg_mask, iterations=2)
    edge_band = dilated & ~bg_mask

    # Build alpha channel
    new_alpha = np.where(bg_mask, 0, 255).astype(np.float64)
    new_alpha[edge_band] = 128  # partial transparency at edges

    # Gaussian blur on alpha for smooth edges
    if gaussian_blur > 0:
        new_alpha = gaussian_filter(new_alpha, sigma=gaussian_blur)

    new_alpha = np.clip(new_alpha, 0, 255).astype(np.uint8)
    data[:, :, 3] = new_alpha

    result = Image.fromarray(data, "RGBA")
    result.save(output_path, "PNG")
    print(f"Saved transparent PNG: {output_path}")


def triangulation_matting(bg1_path, bg2_path, output_path, bg1_color="#FFFFFF", bg2_color="#000000", alpha_threshold=0.01):
    """Compute exact alpha using triangulation matting from two background images.

    Generalized Smith & Blinn compositing equation: I = αF + (1-α)B
    Given the same subject on two known backgrounds B1 and B2:
      I_bg1 = αF + (1-α)*B1
      I_bg2 = αF + (1-α)*B2
    Therefore:
      I_bg1 - I_bg2 = (1-α)*(B1 - B2)
      α = 1 - (I_bg1 - I_bg2) / (B1 - B2)    per channel
      F = (I_bg2 - (1-α)*B2) / α               foreground recovery

    Supports any two background colors (not just white+black).
    """
    import numpy as np
    from PIL import Image

    img1 = np.array(Image.open(bg1_path).convert("RGB"), dtype=np.float64)
    img2 = np.array(Image.open(bg2_path).convert("RGB"), dtype=np.float64)

    # Ensure same dimensions
    if img1.shape != img2.shape:
        h, w = img1.shape[:2]
        img2 = np.array(Image.open(bg2_path).convert("RGB").resize((w, h), Image.LANCZOS), dtype=np.float64)

    # Parse background colors
    b1 = np.array(hex_to_rgb(bg1_color), dtype=np.float64)  # e.g., [255, 255, 255]
    b2 = np.array(hex_to_rgb(bg2_color), dtype=np.float64)  # e.g., [0, 0, 0]
    bg_diff = b1 - b2  # e.g., [255, 255, 255] for white-black

    # Compute alpha per channel: α = 1 - (I1 - I2) / (B1 - B2)
    pixel_diff = img1 - img2  # (1-α) * (B1 - B2) per channel

    # Avoid division by zero on channels where B1 == B2
    safe_bg_diff = np.where(np.abs(bg_diff) > 1e-6, bg_diff, 1.0)
    alpha_per_ch = 1.0 - pixel_diff / safe_bg_diff

    # Only average over channels where B1 != B2 (those carry alpha info)
    valid_channels = np.abs(bg_diff) > 1e-6
    if valid_channels.sum() == 0:
        raise ValueError(f"bg1_color {bg1_color} and bg2_color {bg2_color} are identical")
    alpha = np.mean(alpha_per_ch[:, :, valid_channels], axis=2)
    alpha = np.clip(alpha, 0.0, 1.0)

    # Suppress noise
    alpha = np.where(alpha < alpha_threshold, 0.0, alpha)

    # Recover foreground: F = (I2 - (1-α)*B2) / α
    alpha_3ch = np.stack([alpha] * 3, axis=2)
    safe_alpha = np.where(alpha_3ch > alpha_threshold, alpha_3ch, 1.0)
    fg = (img2 - (1.0 - alpha_3ch) * b2) / safe_alpha
    fg = np.clip(fg, 0, 255)

    # Transparent pixels → black
    fg = np.where(alpha_3ch > alpha_threshold, fg, 0)

    # Build RGBA output
    result = np.zeros((*img1.shape[:2], 4), dtype=np.uint8)
    result[:, :, :3] = fg.astype(np.uint8)
    result[:, :, 3] = (alpha * 255).astype(np.uint8)

    Image.fromarray(result, "RGBA").save(output_path, "PNG")
    print(f"Saved transparent PNG (triangulation matting): {output_path}")


def rembg_remove(input_path, output_path):
    """Remove background using rembg AI model."""
    try:
        from rembg import remove
    except ImportError:
        print("ERROR: rembg is not installed. Install with: pip install rembg", file=sys.stderr)
        print("Tip: falling back to HSV chroma key mode (omit --use-rembg).", file=sys.stderr)
        sys.exit(1)

    from PIL import Image

    img = Image.open(input_path).convert("RGB")
    result = remove(img, alpha_matting=True)
    result.save(output_path, "PNG")
    print(f"Saved transparent PNG (rembg): {output_path}")


def main():
    parser = argparse.ArgumentParser(description="Remove chroma key background and output transparent PNG.")
    parser.add_argument("input_path", help="Path to the input image")
    parser.add_argument("output_path", help="Path for the output transparent PNG")
    parser.add_argument("--chroma-color", default="#00FF00", help="Chroma key hex color (default: #00FF00)")
    parser.add_argument("--use-rembg", action="store_true", help="Use rembg AI model instead of HSV chroma key")
    parser.add_argument("--color-distance", action="store_true",
                        help="Use color-distance matting (Smith-Blinn) for smooth gradient edges")
    parser.add_argument("--triangulation", action="store_true",
                        help="Use triangulation matting from two background images (best quality)")
    parser.add_argument("--bg2", default=None,
                        help="Path to second background image (required for --triangulation)")
    parser.add_argument("--black-bg", default=None,
                        help="Deprecated alias for --bg2")
    parser.add_argument("--bg1-color", default="#FFFFFF",
                        help="Hex color of first background / input_path image (default: #FFFFFF)")
    parser.add_argument("--bg2-color", default="#000000",
                        help="Hex color of second background / --bg2 image (default: #000000)")
    parser.add_argument("--alpha-threshold", type=float, default=0.01,
                        help="Alpha threshold below which pixels become fully transparent (default: 0.01)")
    parser.add_argument("--hue-tolerance", type=float, default=30, help="Hue tolerance in degrees (default: 30)")
    parser.add_argument("--saturation-min", type=int, default=80, help="Min saturation 0-255 (default: 80)")
    parser.add_argument("--gaussian-blur", type=float, default=0.5, help="Alpha channel blur sigma (default: 0.5)")
    parser.add_argument("--near-threshold", type=float, default=30,
                        help="Color distance below this → fully transparent (default: 30)")
    parser.add_argument("--far-threshold", type=float, default=120,
                        help="Color distance above this → fully opaque (default: 120)")
    parser.add_argument("--despill", type=float, default=0.8,
                        help="Despill strength 0-1 to remove bg color bleed (default: 0.8)")
    args = parser.parse_args()

    if not Path(args.input_path).exists():
        print(f"ERROR: Input file not found: {args.input_path}", file=sys.stderr)
        sys.exit(1)

    if args.triangulation:
        bg2_path = args.bg2 or args.black_bg
        if not bg2_path:
            print("ERROR: --bg2 is required when using --triangulation", file=sys.stderr)
            sys.exit(1)
        if not Path(bg2_path).exists():
            print(f"ERROR: Second background image not found: {bg2_path}", file=sys.stderr)
            sys.exit(1)
        triangulation_matting(
            args.input_path, bg2_path, args.output_path,
            bg1_color=args.bg1_color, bg2_color=args.bg2_color,
            alpha_threshold=args.alpha_threshold,
        )
    elif args.use_rembg:
        rembg_remove(args.input_path, args.output_path)
    elif args.color_distance:
        color_distance_remove(
            args.input_path,
            args.output_path,
            args.chroma_color,
            args.near_threshold,
            args.far_threshold,
            args.despill,
            args.gaussian_blur,
        )
    else:
        chroma_key_remove(
            args.input_path,
            args.output_path,
            args.chroma_color,
            args.hue_tolerance,
            args.saturation_min,
            args.gaussian_blur,
        )


if __name__ == "__main__":
    main()
