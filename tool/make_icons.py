"""Vygeneruje ikonu aplikace a obrázky loga z původního loga HINKredience°.

Použití:  python3 tool/make_icons.py cesta/k/logu.png
Zjednodušená ikona = samotná kuchařská čepice z loga na tmavém pozadí.
"""
import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
BG = (11, 11, 13)  # 0B0B0D


def feathered(crop: Image.Image, feather: int) -> Image.Image:
    """Vrátí výřez s okraji plynule přecházejícími do průhledna."""
    mask = Image.new("L", crop.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (feather, feather, crop.width - feather, crop.height - feather),
        radius=feather * 2,
        fill=255,
    )
    mask = mask.filter(ImageFilter.GaussianBlur(feather / 1.6))
    out = crop.convert("RGBA")
    out.putalpha(mask)
    return out


def icon_master(src: Image.Image, size: int, scale: float) -> Image.Image:
    hat = feathered(src.crop((255, 55, 1005, 575)), 46)
    canvas = Image.new("RGBA", (size, size), BG + (255,))
    width = int(size * scale)
    height = int(width * hat.height / hat.width)
    hat = hat.resize((width, height), Image.LANCZOS)
    canvas.alpha_composite(hat, ((size - width) // 2, (size - height) // 2))
    return canvas


def main() -> None:
    src = Image.open(sys.argv[1]).convert("RGB")

    # Obrázky pro aplikaci
    images = ROOT / "assets" / "images"
    images.mkdir(parents=True, exist_ok=True)
    src.resize((1080, 1080), Image.LANCZOS).save(images / "logo_full.jpg", quality=88)
    mark = feathered(src.crop((255, 55, 1005, 575)), 46)
    mark.resize((600, int(600 * mark.height / mark.width)), Image.LANCZOS).save(
        images / "logo_mark.png", optimize=True
    )

    master = icon_master(src, 1024, 0.86)

    # Android – klasické ikony
    res = ROOT / "android" / "app" / "src" / "main" / "res"
    for name, px in {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}.items():
        master.resize((px, px), Image.LANCZOS).convert("RGB").save(
            res / f"mipmap-{name}" / "ic_launcher.png"
        )
    # Android – adaptivní ikona (popředí má bezpečnou zónu 66 %)
    foreground = icon_master(src, 432, 0.60)
    drawable = res / "drawable"
    drawable.mkdir(exist_ok=True)
    foreground.convert("RGB").save(drawable / "ic_launcher_foreground.png")
    anydpi = res / "mipmap-anydpi-v26"
    anydpi.mkdir(exist_ok=True)
    (anydpi / "ic_launcher.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@color/ic_launcher_background"/>\n'
        '    <foreground android:drawable="@drawable/ic_launcher_foreground"/>\n'
        "</adaptive-icon>\n",
        encoding="utf-8",
    )
    (res / "values" / "ic_launcher_background.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        "<resources>\n"
        '    <color name="ic_launcher_background">#0B0B0D</color>\n'
        "</resources>\n",
        encoding="utf-8",
    )

    # iOS – velikosti podle Contents.json
    appicon = ROOT / "ios" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
    contents = json.loads((appicon / "Contents.json").read_text())
    for entry in contents["images"]:
        base = float(entry["size"].split("x")[0])
        px = round(base * int(entry["scale"].rstrip("x")))
        master.resize((px, px), Image.LANCZOS).convert("RGB").save(appicon / entry["filename"])


if __name__ == "__main__":
    main()
