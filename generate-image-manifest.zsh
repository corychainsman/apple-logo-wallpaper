#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
output_file="$script_dir/image-manifest.js"
temporary_file=$(mktemp)
sources=("$script_dir"/images/*.jpg(Nn))

{
  print 'window.WALLPAPER_IMAGES = ['
  for source in "${sources[@]}"; do
    relative_path=${source#"$script_dir"/}
    printf '  "%s",\n' "$relative_path"
  done
  print '];'
} > "$temporary_file"

mv "$temporary_file" "$output_file"
print "Wrote ${#sources[@]} images to $output_file"
