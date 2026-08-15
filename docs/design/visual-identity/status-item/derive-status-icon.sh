#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(git -C "$script_dir" rev-parse --show-toplevel)"
source_png="$repo_root/docs/design/visual-identity/masters/rejected-viewfinder-ears.png"
master_dir="$script_dir/master"
export_dir="$script_dir/exports"
preview_dir="$script_dir/previews"
master_png="$master_dir/grab-rabbit-status-template-1024.png"
master_pdf="$master_dir/grab-rabbit-status-template.pdf"
scratch_dir="$(mktemp -d)"
png_options=(-strip -define png:exclude-chunks=date,time)

trap 'find "$scratch_dir" -type f -delete; find "$scratch_dir" -depth -type d -empty -delete' EXIT

command -v magick >/dev/null
python3 -c 'import reportlab' >/dev/null
test -f "$source_png"
mkdir -p "$master_dir" "$export_dir" "$preview_dir"

# Union the bright camera/rabbit artwork, then retain only the two details that
# survive menu-bar scale: the lens and the small viewfinder cutout.
magick "$source_png" \
  -colorspace HSL -channel B -separate +channel \
  -threshold 40% -type bilevel "$scratch_dir/outer-mask.png"
magick "$scratch_dir/outer-mask.png" \
  -fill black -stroke none \
  -draw 'circle 512,690 563,690' \
  -draw 'roundrectangle 225,433 301,476 20,20' \
  "$scratch_dir/detail-mask.png"
magick "$scratch_dir/detail-mask.png" \
  -trim +repage -filter Lanczos -resize 896x896 \
  -gravity center -background black -extent 1024x1024 \
  "$scratch_dir/normalized-mask.png"
magick "$scratch_dir/normalized-mask.png" \
  -alpha copy -channel RGB -fill black -colorize 100 +channel \
  "${png_options[@]}" \
  "$master_png"

render_export() {
  local name="$1"
  local pixels="$2"
  magick "$master_png" -filter Lanczos -resize "${pixels}x${pixels}!" \
    "${png_options[@]}" \
    "$export_dir/grab-rabbit-status-${name}.png"
}

render_export '16pt' 16
render_export '18pt' 18
render_export '22pt' 22
render_export '16pt@2x' 32
render_export '18pt@2x' 36
render_export '22pt@2x' 44

python3 - "$master_png" "$master_pdf" <<'PY'
import sys
from reportlab import rl_config
from reportlab.lib.utils import ImageReader
from reportlab.pdfgen import canvas

source, output = sys.argv[1:]
rl_config.useA85 = 0
pdf = canvas.Canvas(output, pagesize=(18, 18), pageCompression=1, invariant=1)
pdf.setAuthor("Grab Rabbit")
pdf.setTitle("Grab Rabbit status-item template")
pdf.drawImage(ImageReader(source), 0, 0, width=18, height=18, mask="auto")
pdf.showPage()
pdf.save()
PY

make_cell() {
  local input="$1"
  local background="$2"
  local foreground="$3"
  local output="$4"
  magick "$input" -channel RGB -fill "$foreground" -colorize 100 +channel \
    "$scratch_dir/tinted.png"
  magick -size 80x64 "xc:$background" "$scratch_dir/tinted.png" \
    -gravity center -compose over -composite \
    "${png_options[@]}" "$output"
}

make_inspection_cell() {
  local input="$1"
  local background="$2"
  local foreground="$3"
  local output="$4"
  magick "$input" -channel RGB -fill "$foreground" -colorize 100 +channel \
    -filter point -resize 176x176! "$scratch_dir/tinted-large.png"
  magick -size 184x184 "xc:$background" "$scratch_dir/tinted-large.png" \
    -gravity center -compose over -composite \
    -bordercolor '#94A3B8' -border 2 \
    "${png_options[@]}" "$output"
}

names=('16pt' '18pt' '22pt' '16pt@2x' '18pt@2x' '22pt@2x')
for name in "${names[@]}"; do
  input="$export_dir/grab-rabbit-status-${name}.png"
  make_cell "$input" '#ECECEC' '#202124' "$scratch_dir/light-${name}.png"
  make_cell "$input" '#252525' '#F5F5F5' "$scratch_dir/dark-${name}.png"
  make_inspection_cell "$input" '#ECECEC' '#202124' "$scratch_dir/light-inspect-${name}.png"
  make_inspection_cell "$input" '#252525' '#F5F5F5' "$scratch_dir/dark-inspect-${name}.png"
done

magick \
  "$scratch_dir/light-16pt.png" "$scratch_dir/light-18pt.png" "$scratch_dir/light-22pt.png" \
  "$scratch_dir/light-16pt@2x.png" "$scratch_dir/light-18pt@2x.png" "$scratch_dir/light-22pt@2x.png" \
  +append "$scratch_dir/light-sizes.png"
magick \
  "$scratch_dir/dark-16pt.png" "$scratch_dir/dark-18pt.png" "$scratch_dir/dark-22pt.png" \
  "$scratch_dir/dark-16pt@2x.png" "$scratch_dir/dark-18pt@2x.png" "$scratch_dir/dark-22pt@2x.png" \
  +append "$scratch_dir/dark-sizes.png"
magick "$scratch_dir/light-sizes.png" "$scratch_dir/dark-sizes.png" \
  -append "${png_options[@]}" "$preview_dir/exact-size-strip.png"

magick \
  "$scratch_dir/light-inspect-16pt.png" "$scratch_dir/light-inspect-18pt.png" "$scratch_dir/light-inspect-22pt.png" \
  "$scratch_dir/light-inspect-16pt@2x.png" "$scratch_dir/light-inspect-18pt@2x.png" "$scratch_dir/light-inspect-22pt@2x.png" \
  +append "$scratch_dir/light-inspection.png"
magick \
  "$scratch_dir/dark-inspect-16pt.png" "$scratch_dir/dark-inspect-18pt.png" "$scratch_dir/dark-inspect-22pt.png" \
  "$scratch_dir/dark-inspect-16pt@2x.png" "$scratch_dir/dark-inspect-18pt@2x.png" "$scratch_dir/dark-inspect-22pt@2x.png" \
  +append "$scratch_dir/dark-inspection.png"
magick "$scratch_dir/light-inspection.png" "$scratch_dir/dark-inspection.png" \
  -append "${png_options[@]}" "$preview_dir/pixel-inspection.png"

make_menu_bar() {
  local background="$1"
  local foreground="$2"
  local output="$3"
  magick "$export_dir/grab-rabbit-status-18pt@2x.png" \
    -channel RGB -fill "$foreground" -colorize 100 +channel \
    "$scratch_dir/status-glyph.png"
  magick -size 640x64 "xc:$background" \
    -fill none -stroke "$foreground" -strokewidth 3 \
    -draw 'circle 468,32 468,19' \
    -draw 'roundrectangle 520,21 568,43 7,7' \
    -draw 'rectangle 568,28 573,36' \
    -fill "$foreground" -stroke none \
    -draw 'circle 468,32 468,27' \
    -draw 'roundrectangle 525,26 555,38 4,4' \
    "$scratch_dir/menu-base.png"
  magick "$scratch_dir/menu-base.png" "$scratch_dir/status-glyph.png" \
    -geometry +398+14 -compose over -composite \
    "${png_options[@]}" "$output"
}

make_menu_bar '#ECECEC' '#202124' "$preview_dir/menu-bar-light.png"
make_menu_bar '#252525' '#F5F5F5' "$preview_dir/menu-bar-dark.png"
magick "$preview_dir/menu-bar-light.png" "$preview_dir/menu-bar-dark.png" \
  -append "${png_options[@]}" "$preview_dir/menu-bar-comparison.png"
