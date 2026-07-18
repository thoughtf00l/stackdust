# dmgbuild settings for the Stackdust release DMG.
# Invoked as: dmgbuild -s scripts/dmg_settings.py -D app=<path to Stackdust.app> Stackdust <out.dmg>
import os.path

app = defines.get("app", "Stackdust.app")  # noqa: F821 — `defines` is injected by dmgbuild
appname = os.path.basename(app)

files = [app]
symlinks = {"Applications": "/Applications"}

badge_icon = os.path.join(app, "Contents", "Resources", "AppIcon.icns")

window_rect = ((200, 200), (540, 300))
icon_size = 96
text_size = 13
icon_locations = {
    appname: (140, 130),
    "Applications": (400, 130),
}

format = "UDZO"
