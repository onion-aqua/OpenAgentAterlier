"""Opt-in icon generation from an explicitly supplied new image (Pillow).

The app currently has no custom launcher icon. This helper does not enable
Manifest/resource references; those must be reviewed separately if needed.
"""
import argparse
from pathlib import Path

from PIL import Image, ImageOps


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True,
                        help='New authorized image; no historical character default')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    source = Image.open(args.source).convert("RGB")
    square = ImageOps.fit(source, (1024, 1024), Image.Resampling.LANCZOS)
    res = root / "android/app/src/main/res"
    for density, size, foreground in (
        ("mdpi", 48, 108), ("hdpi", 72, 162), ("xhdpi", 96, 216),
        ("xxhdpi", 144, 324), ("xxxhdpi", 192, 432),
    ):
        for folder, name, pixels in (
            (f"mipmap-{density}", "ic_launcher.png", size),
            (f"drawable-{density}", "ic_launcher_foreground.png", foreground),
        ):
            target = res / folder / name
            target.parent.mkdir(parents=True, exist_ok=True)
            square.resize((pixels, pixels), Image.Resampling.LANCZOS).save(target)
    windows = root / "windows/runner/resources"
    if windows.exists():
        square.save(windows / "app_icon.ico", sizes=[(s, s) for s in (16, 24, 32, 48, 64, 128, 256)])


if __name__ == "__main__":
    main()
