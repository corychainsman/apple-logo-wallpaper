#!/bin/zsh
set -euo pipefail

app_path=${1:-"$HOME/Applications/Apple Logo Wallpaper.app"}
iterations=${2:-3}

close_settings_and_focus_finder() {
  osascript \
    -e 'tell application "System Events" to tell process "AppleLogoWallpaper" to if exists window "Apple Logo Wallpaper Settings" then click button 1 of window "Apple Logo Wallpaper Settings"' \
    -e 'tell application "Finder" to activate' >/dev/null
  sleep 0.3
}

assert_settings_frontmost() {
  local state
  state=$(osascript -e 'tell application "System Events" to tell process "AppleLogoWallpaper" to return ((exists window "Apple Logo Wallpaper Settings") as text) & ":" & ((value of attribute "AXMain" of window "Apple Logo Wallpaper Settings") as text) & ":" & ((value of attribute "AXFocused" of window "Apple Logo Wallpaper Settings") as text)')
  [[ "$state" == "true:true:true" ]] || {
    print -u2 "Settings Presentation failed: $state"
    return 1
  }
}

open -a "$app_path"
sleep 0.5

for _ in {1..$iterations}; do
  close_settings_and_focus_finder
  osascript -e 'tell application id "com.cchainsm.apple-logo-wallpaper" to activate' >/dev/null
  sleep 0.5
  assert_settings_frontmost
done

for _ in {1..$iterations}; do
  close_settings_and_focus_finder
  osascript -e 'tell application "System Events" to tell process "AppleLogoWallpaper" to click menu bar item 1 of menu bar 1' >/dev/null
  sleep 0.5
  assert_settings_frontmost
done

print "Settings Presentation regression: PASS"
