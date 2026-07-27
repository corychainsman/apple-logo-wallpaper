#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
app_label='com.cchainsm.apple-logo-wallpaper-app'
launch_domain="gui/$(id -u)"
app_installed="$HOME/Library/LaunchAgents/$app_label.plist"
built_app="$script_dir/build/Apple Logo Wallpaper.app"
installed_app="$HOME/Applications/Apple Logo Wallpaper.app"

if [[ -z "$HOME" || "$HOME" == / ]]; then
  print -u2 'Refusing to install without a safe home directory.'
  exit 1
fi

npm run build --prefix "$script_dir"
"$script_dir/build-app.zsh"

mkdir -p "$HOME/Applications"
if [[ "$installed_app" != "$HOME/Applications/Apple Logo Wallpaper.app" ]]; then
  print -u2 'Unexpected installed application path.'
  exit 1
fi
launchctl bootout "$launch_domain/$app_label" 2>/dev/null || true
rm -f "$app_installed"
pkill -x AppleLogoWallpaper 2>/dev/null || true
rm -rf "$installed_app"
ditto "$built_app" "$installed_app"
codesign --verify --deep --strict "$installed_app"
open "$installed_app"

print '\nUse the pixelated Apple icon in the Menu Bar to open Settings.'
