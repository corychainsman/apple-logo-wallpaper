# Apple Logo Wallpaper

Apple Logo Wallpaper presents a changing grid of Apple event artwork as the desktop across one or more Mac displays.

## Language

**Wallpaper Surface**:
The desktop-level window that renders one display's animated image grid.
_Avoid_: Wallpaper window, web view

**Display Configuration**:
The remembered enabled state and grid dimensions associated with one physical display identity.
_Avoid_: Monitor settings, screen config

**Transition**:
The selected GL shader and parameters used to animate one tile from its current image to its next image.
_Avoid_: Effect, animation style

**Application Preferences**:
The app-level choices for Launch at Login, Dock visibility, Menu Bar visibility, and Dock icon cycling.
_Avoid_: Global settings, app settings

**Settings Presentation**:
The user intent to open, foreground, and focus the native Settings window.
_Avoid_: Open settings, window activation

## Relationships

- Each enabled **Display Configuration** produces one **Wallpaper Surface** while its display is connected.
- A **Wallpaper Surface** uses the shared **Transition** timing and selection.
- **Application Preferences** determine how **Settings Presentation** can be reached from the Dock, App Switcher, and Menu Bar.

## Example dialogue

> **Dev:** "What happens when a display is reattached?"
> **Domain expert:** "Its **Display Configuration** is restored, and an enabled configuration creates a new **Wallpaper Surface** using the shared **Transition**."

## Flagged ambiguities

- "Settings" previously referred to both wallpaper behavior and app visibility; **Display Configuration**, **Transition**, and **Application Preferences** now name those concerns explicitly.
