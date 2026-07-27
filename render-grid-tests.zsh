#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
source_dir="$script_dir/images"
output_dir="$script_dir/grid-tests"
background='#F8F8F8'

mkdir -p "$output_dir"
sources=("$source_dir"/*.jpg(Nn))

render_grid() {
  local columns=$1
  local rows=$2
  local cell_width=$((3440 / columns))
  local cell_height=$((1440 / rows))
  local count=$((columns * rows))
  local output="$output_dir/grid-${columns}x${rows}.jpg"

  magick montage "${sources[@]:0:$count}" \
    -auto-orient \
    -thumbnail "${cell_width}x${cell_height}" \
    -font /System/Library/Fonts/Helvetica.ttc \
    -background "$background" \
    -gravity center \
    -geometry "${cell_width}x${cell_height}+0+0" \
    -tile "${columns}x${rows}" \
    "$output"
}

render_grid 5 3
render_grid 8 4
render_grid 16 9
