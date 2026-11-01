#!/usr/bin/env python3
"""Generate the Jdev ai launcher icons and splash artwork for every target.

Design: an indigo-to-violet gradient with a white `</>` mark.

Requires Pillow (``python -m pip install pillow``). Run from anywhere:

    python offline-coding-assistant/tools/generate_icons.py

Everything is derived from one supersampled renderer, so the output is
deterministic and can be regenerated after tweaking the constants below.
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

# --- Brand -----------------------------------------------------------------
COLOR_TOP = (49, 46, 129)  # #312E81 indigo-900
COLOR_BOTTOM = (124, 58, 237)  # #7C3AED violet-600
COLOR_SHADOW = (14, 10, 42)
GLYPH = (255, 255, 255)

# --- Geometry (fractions of the canvas) ------------------------------------
STROKE = 0.054
CHEVRON_LEFT = [(0.375, 0.32), (0.225, 0.50), (0.375, 0.68)]
CHEVRON_RIGHT = [(0.625, 0.32), (0.775, 0.50), (0.625, 0.68)]
SLASH = [(0.545, 0.315), (0.455, 0.685)]
CORNER_RADIUS = 0.225

SUPERSAMPLE = 4
MASTER = 1024

FLUTTER_APP = Path(__file__).resolve().parents[1] / "flutter_app"
RES = FLUTTER_APP / "android" / "app" / "src" / "main" / "res"
IOS_ICONS = FLUTTER_APP / "ios" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
IOS_LAUNCH = FLUTTER_APP / "ios" / "Runner" / "Assets.xcassets" / "LaunchImage.imageset"
WINDOWS_ICON = FLUTTER_APP / "windows" / "runner" / "resources" / "app_icon.ico"
BRANDING = FLUTTER_APP / "assets" / "branding"


def _gradient(size: int) -> Image.Image:
    """Diagonal gradient, built small and upscaled to keep this fast."""
    small = 512
    img = Image.new("RGB", (small, small))
    px = img.load()
    for y in range(small):
        for x in range(small):
            t = (x + y) / (2 * (small - 1))
            px[x, y] = tuple(
                round(a + (b - a) * t) for a, b in zip(COLOR_TOP, COLOR_BOTTOM)
            )
    return img.resize((size, size), Image.BICUBIC)


def _rounded_mask(size: int, radius: float) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, size - 1, size - 1), radius=radius, fill=255
    )
    return mask


def _draw_glyph(
    draw: ImageDraw.ImageDraw,
    size: int,
    color,
    width: int,
    scale: float = 1.0,
) -> None:
    half = width / 2

    def point(p):
        x, y = p
        return ((0.5 + (x - 0.5) * scale) * size, (0.5 + (y - 0.5) * scale) * size)

    def cap(p):
        x, y = p
        draw.ellipse((x - half, y - half, x + half, y + half), fill=color)

    for shape in (CHEVRON_LEFT, CHEVRON_RIGHT):
        pts = [point(p) for p in shape]
        draw.line(pts, fill=color, width=width, joint="curve")
        cap(pts[0])
        cap(pts[-1])

    pts = [point(p) for p in SLASH]
    draw.line(pts, fill=color, width=width)
    cap(pts[0])
    cap(pts[-1])


def render(
    size: int = MASTER,
    *,
    rounded: bool = True,
    glyph_scale: float = 1.0,
    background: bool = True,
):
    """Render the icon at ``size`` px.

    ``rounded`` gives the standalone app icon, ``glyph_scale`` shrinks the mark
    for the adaptive-icon safe zone, and ``background=False`` returns a
    transparent canvas holding only the mark.
    """
    s = size * SUPERSAMPLE

    if background:
        base = _gradient(s).convert("RGBA")

        # Soft light from the top-left corner.
        glow = Image.new("L", (s, s), 0)
        gd = ImageDraw.Draw(glow)
        r = int(s * 0.55)
        gd.ellipse((-r // 2, -r // 2, r, r), fill=34)
        glow = glow.filter(ImageFilter.GaussianBlur(s * 0.14))
        base = Image.composite(
            Image.new("RGBA", (s, s), (255, 255, 255, 255)), base, glow
        )

        # Gentle vignette keeps the corners from looking flat.
        shade = Image.new("L", (s, s), 0)
        sd = ImageDraw.Draw(shade)
        sd.ellipse((-s * 0.10, -s * 0.10, s * 1.10, s * 1.10), fill=255)
        shade = shade.filter(ImageFilter.GaussianBlur(s * 0.20))
        base = Image.composite(
            base, Image.new("RGBA", (s, s), (*COLOR_SHADOW, 255)), shade
        )

        if rounded:
            base.putalpha(_rounded_mask(s, CORNER_RADIUS * s))
    else:
        base = Image.new("RGBA", (s, s), (0, 0, 0, 0))

    width = max(2, round(STROKE * s * glyph_scale))

    # Drop shadow under the mark, then the mark itself.
    shadow = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    _draw_glyph(ImageDraw.Draw(shadow), s, (*COLOR_SHADOW, 110), width, glyph_scale)
    shadow = shadow.filter(ImageFilter.GaussianBlur(s * 0.018))
    base.alpha_composite(shadow, (0, int(s * 0.012 * glyph_scale)))

    _draw_glyph(ImageDraw.Draw(base), s, GLYPH, width, glyph_scale)

    return base.resize((size, size), Image.LANCZOS)


def main() -> None:
    BRANDING.mkdir(parents=True, exist_ok=True)
    render(MASTER).save(BRANDING / "app_icon.png")
    render(MASTER, rounded=False).convert("RGB").save(BRANDING / "app_icon_square.png")

    # --- Android legacy launcher icons -------------------------------------
    densities = {
        "mdpi": 48,
        "hdpi": 72,
        "xhdpi": 96,
        "xxhdpi": 144,
        "xxxhdpi": 192,
    }
    for name, px in densities.items():
        out = RES / f"mipmap-{name}" / "ic_launcher.png"
        out.parent.mkdir(parents=True, exist_ok=True)
        render(px).save(out)

    # --- Android adaptive foreground (108dp canvas, 72dp safe zone) --------
    adaptive = {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}
    for name, px in adaptive.items():
        out = RES / f"mipmap-{name}" / "ic_launcher_foreground.png"
        render(px, background=False, glyph_scale=0.72).save(out)

    # --- Android splash mark (140dp) ---------------------------------------
    for name, px in {"mdpi": 140, "hdpi": 210, "xhdpi": 280, "xxhdpi": 420, "xxxhdpi": 560}.items():
        out = RES / f"drawable-{name}" / "splash_logo.png"
        out.parent.mkdir(parents=True, exist_ok=True)
        render(px, background=False, glyph_scale=0.86).save(out)

    # --- iOS ----------------------------------------------------------------
    ios_sizes = {
        "Icon-App-20x20@1x.png": 20,
        "Icon-App-20x20@2x.png": 40,
        "Icon-App-20x20@3x.png": 60,
        "Icon-App-29x29@1x.png": 29,
        "Icon-App-29x29@2x.png": 58,
        "Icon-App-29x29@3x.png": 87,
        "Icon-App-40x40@1x.png": 40,
        "Icon-App-40x40@2x.png": 80,
        "Icon-App-40x40@3x.png": 120,
        "Icon-App-60x60@2x.png": 120,
        "Icon-App-60x60@3x.png": 180,
        "Icon-App-76x76@1x.png": 76,
        "Icon-App-76x76@2x.png": 152,
        "Icon-App-83.5x83.5@2x.png": 167,
        "Icon-App-1024x1024@1x.png": 1024,
    }
    for name, px in ios_sizes.items():
        # iOS masks the corners itself and rejects alpha channels.
        render(px, rounded=False).convert("RGB").save(IOS_ICONS / name)

    for name, px in {"LaunchImage.png": 120, "LaunchImage@2x.png": 240, "LaunchImage@3x.png": 360}.items():
        render(px, background=False, glyph_scale=0.92).save(IOS_LAUNCH / name)

    # --- Windows ------------------------------------------------------------
    WINDOWS_ICON.parent.mkdir(parents=True, exist_ok=True)
    render(256).save(
        WINDOWS_ICON,
        format="ICO",
        sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)],
    )

    print(f"Wrote {MASTER}px master to {BRANDING / 'app_icon.png'}")


if __name__ == "__main__":
    main()
