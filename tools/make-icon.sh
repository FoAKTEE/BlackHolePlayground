#!/usr/bin/env bash
# make-icon.sh — (re)generate Resources/AppIcon.icns from Resources/C-logo.png.
#
# Composites the logo onto a dark "space" squircle and emits a full macOS .icns.
# Needs Python 3 with Pillow (`pip3 install pillow`; numpy optional for the gradient)
# and `iconutil` (ships with macOS). The build itself only needs the resulting .icns,
# so this is a one-off you run when the logo changes.

set -euo pipefail
cd "$(dirname "$0")/.."

SRC="Resources/C-logo.png"
OUT="Resources/AppIcon.icns"
[ -f "$SRC" ] || { echo "error: $SRC not found" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/AppIcon.iconset"

SRC="$SRC" WORK="$WORK" python3 - <<'PY'
import os
from PIL import Image, ImageDraw
src, work = os.environ["SRC"], os.environ["WORK"]
S = 1024
try:
    import numpy as np
    yy, xx = np.mgrid[0:S, 0:S]
    d = np.clip(np.sqrt((xx-S/2)**2 + (yy-S/2)**2) / (S*0.70), 0, 1)[..., None]
    rgb = (np.array([30,30,62])*(1-d) + np.array([8,8,18])*d).astype('uint8')
    a = np.full((S, S, 1), 255, 'uint8')
    bg = Image.fromarray(np.concatenate([rgb, a], axis=2), 'RGBA')
except Exception:
    bg = Image.new('RGBA', (S, S), (20, 20, 40, 255))

logo = Image.open(src).convert('RGBA')
margin = 70
tw = int((S - 2*margin) * 0.88)
logo = logo.resize((tw, int(logo.height * tw / logo.width)), Image.LANCZOS)
bg.alpha_composite(logo, ((S-logo.width)//2, (S-logo.height)//2))

mask = Image.new('L', (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle([margin, margin, S-margin, S-margin], radius=205, fill=255)
icon = Image.new('RGBA', (S, S), (0, 0, 0, 0))
icon.paste(bg, (0, 0), mask)

for px, name in [(16,'16x16'),(32,'16x16@2x'),(32,'32x32'),(64,'32x32@2x'),(128,'128x128'),
                 (256,'128x128@2x'),(256,'256x256'),(512,'256x256@2x'),(512,'512x512'),(1024,'512x512@2x')]:
    icon.resize((px, px), Image.LANCZOS).save(f"{work}/AppIcon.iconset/icon_{name}.png")
PY

iconutil -c icns "$WORK/AppIcon.iconset" -o "$OUT"
echo "wrote $OUT"
