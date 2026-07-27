#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
label='com.cchainsm.apple-logo-wallpaper-server'
source_plist="$script_dir/launchd/$label.plist"
installed_plist="/Users/cchainsm/Library/LaunchAgents/$label.plist"
launch_domain="gui/$(id -u)"

plutil -lint "$source_plist"
launchctl bootout "$launch_domain/$label" 2>/dev/null || true
install -m 0644 "$source_plist" "$installed_plist"
launchctl bootstrap "$launch_domain" "$installed_plist"
launchctl kickstart -k "$launch_domain/$label"

# Plash must not reload the whole page; the wallpaper updates itself.
defaults delete com.sindresorhus.Plash reloadInterval 2>/dev/null || true
# Keep a full-height canvas; the page reserves its own configurable top inset.
defaults write com.sindresorhus.Plash extendPlashBelowMenuBar -bool true

sleep 2
curl --fail --silent --show-error http://127.0.0.1:8765/api/settings
open -g plash:reload
print '\nSettings: http://127.0.0.1:8765/settings/'
