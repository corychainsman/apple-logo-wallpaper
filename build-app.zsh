#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
build_dir="$script_dir/build"
module_cache_dir="$build_dir/ModuleCache.noindex"
app_bundle="$build_dir/Apple Logo Wallpaper.app"
contents_dir="$app_bundle/Contents"
executable_path="$contents_dir/MacOS/AppleLogoWallpaper"
resources_dir="$contents_dir/Resources"
web_dir="$resources_dir/Web"

if [[ "$app_bundle" != "$script_dir/build/Apple Logo Wallpaper.app" ]]; then
  print -u2 'Unexpected application build path.'
  exit 1
fi

rm -rf "$app_bundle"
mkdir -p "$contents_dir/MacOS"
mkdir -p "$web_dir"
mkdir -p "$module_cache_dir"
install -m 0644 "$script_dir/macos/Info.plist" "$contents_dir/Info.plist"
install -m 0644 "$script_dir/index.html" "$web_dir/index.html"
install -m 0644 "$script_dir/styles.css" "$web_dir/styles.css"
install -m 0644 "$script_dir/image-manifest.js" "$web_dir/image-manifest.js"
install -m 0644 "$script_dir/wallpaper.bundle.js" "$web_dir/wallpaper.bundle.js"
install -m 0644 "$script_dir/transition-metadata.json" "$resources_dir/transition-metadata.json"
install -m 0644 "$script_dir/wallpaper-settings.json" "$resources_dir/DefaultSettings.json"
install -m 0644 "$script_dir/assets/AppIcon.icns" "$resources_dir/AppIcon.icns"
install -m 0644 "$script_dir/assets/MenuBarIcon.png" "$resources_dir/MenuBarIcon.png"
rsync -a --exclude='.DS_Store' "$script_dir/images/" "$web_dir/images/"
plutil -lint "$contents_dir/Info.plist"

CLANG_MODULE_CACHE_PATH="$module_cache_dir" SWIFT_MODULE_CACHE_PATH="$module_cache_dir" xcrun swiftc \
  -swift-version 5 \
  -O \
  -framework AppKit \
  -framework CoreGraphics \
  -framework ServiceManagement \
  -framework WebKit \
  "$script_dir/macos/DisplayConfigurationRetention.swift" \
  "$script_dir/macos/AppleLogoWallpaper.swift" \
  -o "$executable_path"

codesign --force --deep --sign - "$app_bundle"
print "$app_bundle"
