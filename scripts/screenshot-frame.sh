#!/usr/bin/env bash
#
# Floats a window screenshot on the branded backdrop used by docs/screenshots.
#
#   scripts/screenshot-frame.sh in.png out.png [margin-fraction] [corner-radius]
#
# Capture the window on its own first, so it comes with a transparent
# background and rounded corners:
#
#   screencapture -x -o -l <window-id> -t png window.png
#
# Window ids come from `CGWindowListCopyWindowInfo`; `screencapture -w` picks one
# interactively. Pass a corner radius when the input is a plain rectangular crop
# (a full-screen grab, say) that still needs its corners rounded.
#
# Requires ImageMagick (`brew install imagemagick`).
set -euo pipefail

if [ $# -lt 2 ]; then
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
  exit 1
fi

IN="$1"
OUT="$2"
FRAC="${3:-0.11}"
RADIUS="${4:-0}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SRC="$IN"
if [ "$RADIUS" -gt 0 ]; then
  w=$(magick identify -format '%w' "$IN")
  h=$(magick identify -format '%h' "$IN")
  magick -size "${w}x${h}" xc:black -fill white \
    -draw "roundrectangle 0,0,$((w - 1)),$((h - 1)),$RADIUS,$RADIUS" "$WORK/mask.png"
  magick "$IN" "$WORK/mask.png" -alpha off -compose CopyOpacity -composite "$WORK/rounded.png"
  SRC="$WORK/rounded.png"
fi

W=$(magick identify -format '%w' "$SRC")
H=$(magick identify -format '%h' "$SRC")
M=$(python3 -c "print(int(max($W, $H) * $FRAC))")
CW=$((W + 2 * M))
CH=$((H + 2 * M))

# Deep indigo base with a violet glow top-left and a blue one bottom-right.
magick -size "${CW}x${CH}" gradient:'#06022B-#010016' \
  \( -size "${CW}x${CH}" xc:black \
     -fill '#33096B' -draw "translate $((CW * 22 / 100)),$((CH * 18 / 100)) scale 1,0.8 circle 0,0 $((CW * 30 / 100)),0" \
     -blur "0x$((CW / 12))" \) -compose screen -composite \
  \( -size "${CW}x${CH}" xc:black \
     -fill '#0B2560' -draw "translate $((CW * 88 / 100)),$((CH * 62 / 100)) scale 1,1.15 circle 0,0 $((CW * 26 / 100)),0" \
     -blur "0x$((CW / 12))" \) -compose screen -composite \
  \( -size "${CW}x${CH}" xc:black \
     -fill '#1B0742' -draw "translate $((CW * 6 / 100)),$((CH * 92 / 100)) scale 1.2,1 circle 0,0 $((CW * 22 / 100)),0" \
     -blur "0x$((CW / 14))" \) -compose screen -composite \
  "$WORK/backdrop.png"

# Cool rim glow, then a drop shadow, then the window itself.
magick "$WORK/backdrop.png" \
  \( "$SRC" -background '#8FB6FF' -shadow "45x$((CW / 90))+0+0" \) -gravity center -composite \
  \( "$SRC" -background black -shadow "55x$((CW / 70))+0+$((CH / 45))" \) -gravity center -composite \
  \( "$SRC" \) -gravity center -composite \
  -resize 1500x -strip -depth 8 -define png:compression-level=9 \
  "$OUT"

echo "wrote $OUT ($(magick identify -format '%wx%h' "$OUT"), $(du -h "$OUT" | cut -f1))"
