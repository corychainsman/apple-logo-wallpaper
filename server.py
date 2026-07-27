#!/usr/bin/python3
import json
import os
import tempfile
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse


ROOT = Path(__file__).resolve().parent
SETTINGS_PATH = ROOT / "wallpaper-settings.json"
TRANSITIONS_PATH = ROOT / "transition-manifest.json"
HOST = "127.0.0.1"
PORT = int(os.environ.get("APPLE_LOGO_WALLPAPER_PORT", "8765"))
DEFAULTS = {
    "rows": 4,
    "columns": 8,
    "persistenceSeconds": 30,
    "fadeDurationSeconds": 0.42,
    "topInsetPixels": 28,
    "transitionStyle": "fade",
}


def load_transition_names():
    try:
        with TRANSITIONS_PATH.open("r", encoding="utf-8") as transitions_file:
            names = json.load(transitions_file)
        return frozenset(name for name in names if isinstance(name, str))
    except (FileNotFoundError, json.JSONDecodeError, OSError, TypeError):
        return frozenset({DEFAULTS["transitionStyle"]})


VALID_TRANSITIONS = load_transition_names()


def clamp(value, minimum, maximum):
    try:
        numeric = float(value)
    except (TypeError, ValueError):
        numeric = minimum
    return min(max(numeric, minimum), maximum)


def clamp_minimum(value, minimum):
    try:
        numeric = float(value)
    except (TypeError, ValueError):
        numeric = minimum
    return max(numeric, minimum)


def normalize_settings(candidate):
    if not isinstance(candidate, dict):
        candidate = {}
    transition_style = candidate.get("transitionStyle", DEFAULTS["transitionStyle"])
    if transition_style != "random" and transition_style not in VALID_TRANSITIONS:
        transition_style = DEFAULTS["transitionStyle"]
    requested_random_transitions = candidate.get("randomTransitionNames")
    if isinstance(requested_random_transitions, list):
        requested_names = frozenset(
            name for name in requested_random_transitions if isinstance(name, str)
        )
        random_transition_names = [
            name for name in sorted(VALID_TRANSITIONS) if name in requested_names
        ]
        if not random_transition_names:
            random_transition_names = [DEFAULTS["transitionStyle"]]
    else:
        random_transition_names = sorted(VALID_TRANSITIONS)
    return {
        "rows": round(clamp(candidate.get("rows", DEFAULTS["rows"]), 1, 20)),
        "columns": round(clamp(candidate.get("columns", DEFAULTS["columns"]), 1, 32)),
        "persistenceSeconds": clamp(
            candidate.get("persistenceSeconds", DEFAULTS["persistenceSeconds"]), 1, 86400
        ),
        "fadeDurationSeconds": clamp(
            candidate.get("fadeDurationSeconds", DEFAULTS["fadeDurationSeconds"]), 0, float("inf")
        ),
        "topInsetPixels": clamp(
            candidate.get("topInsetPixels", DEFAULTS["topInsetPixels"]), 0, 200
        ),
        "transitionStyle": transition_style,
        "randomTransitionNames": random_transition_names,
    }


def load_settings():
    try:
        with SETTINGS_PATH.open("r", encoding="utf-8") as settings_file:
            return normalize_settings(json.load(settings_file))
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return normalize_settings(DEFAULTS)


def save_settings(settings):
    normalized = normalize_settings(settings)
    descriptor, temporary_path = tempfile.mkstemp(
        prefix="wallpaper-settings-", suffix=".json", dir=ROOT
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as temporary_file:
            json.dump(normalized, temporary_file, indent=2)
            temporary_file.write("\n")
            temporary_file.flush()
            os.fsync(temporary_file.fileno())
        os.replace(temporary_path, SETTINGS_PATH)
    except Exception:
        try:
            os.unlink(temporary_path)
        except OSError:
            pass
        raise
    return normalized


class WallpaperRequestHandler(SimpleHTTPRequestHandler):
    def send_json(self, payload, status=200):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if urlparse(self.path).path == "/api/settings":
            self.send_json(load_settings())
            return
        super().do_GET()

    def do_POST(self):
        if urlparse(self.path).path != "/api/settings":
            self.send_error(404)
            return

        try:
            content_length = min(int(self.headers.get("Content-Length", "0")), 16384)
            payload = json.loads(self.rfile.read(content_length).decode("utf-8"))
            self.send_json(save_settings(payload))
        except (ValueError, json.JSONDecodeError):
            self.send_json({"error": "Invalid settings payload"}, status=400)
        except OSError as error:
            self.send_json({"error": str(error)}, status=500)

    def end_headers(self):
        path = urlparse(self.path).path
        if path.endswith((".html", ".js", ".css", ".json")) or path in ("/", "/settings/"):
            self.send_header("Cache-Control", "no-store")
        super().end_headers()


def main():
    handler = partial(WallpaperRequestHandler, directory=str(ROOT))
    server = ThreadingHTTPServer((HOST, PORT), handler)
    print("Serving Apple Logo Wallpaper at http://{}:{}/".format(HOST, PORT), flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
