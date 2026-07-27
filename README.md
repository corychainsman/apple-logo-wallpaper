# Apple Logo Grid Wallpaper

A local, live wallpaper page for [Plash](https://apps.apple.com/us/app/plash/id1494023538). It displays the JPEGs in `images/` as a responsive grid and crossfades one tile at a time.

The canvas is fixed at 3440 × 1440 for the Dell ultrawide. This avoids a Plash multi-display bug where the WebView can inherit the built-in Retina display's 1912 px height and crop lower grid rows.

## Refresh the image list

Run this whenever JPEGs are added, removed, or renamed:

```sh
./generate-image-manifest.zsh
```

## Local server

Plash does not load this project directly from a `file://` URL. A per-user launch agent serves it locally and starts automatically at login:

```text
~/Library/LaunchAgents/com.cchainsm.apple-logo-wallpaper-server.plist
```

The wallpaper URL in Plash is:

```text
http://127.0.0.1:8765/
```

Install or update the login-time server with:

```sh
./install-server.zsh
```

The default is an 8 × 4 grid. Every tile persists for 30 seconds, with their initial phases randomized so one tile crossfades at a time.

## Settings

Open the dependency-free settings page:

```text
http://127.0.0.1:8765/settings/
```

It controls rows, columns, the grid refresh cycle, transition duration, transition style, and the top margin reserved for the menu bar. Settings are stored in `wallpaper-settings.json` and applied live without reloading the Plash page.

The transition picker contains all 125 shaders from the MIT-licensed [GL Transitions](https://gl-transitions.com/) collection. Focus a transition choice and use the Up/Down arrow keys to preview adjacent transitions immediately. The adjacent checkbox column controls which shaders are eligible for **Random** mode; all 125 are included by default.

Fade duration is never shortened. Fades run one at a time, so a long fade can slow the overall rotation rate.

After changing JavaScript dependencies, rebuild the local browser bundle:

```sh
npm install
npm run build
```

Keep Plash's **Extend below menu bar** enabled and **Reload every** disabled. The wallpaper uses a configurable top margin while retaining Plash's full-height canvas, so every row remains visible without full-screen reload flashes.

## Health check

```sh
curl -I http://127.0.0.1:8765/
launchctl print gui/$(id -u)/com.cchainsm.apple-logo-wallpaper-server
```

Server logs are written to `~/Library/Logs/apple-logo-wallpaper-server-error.log`.
