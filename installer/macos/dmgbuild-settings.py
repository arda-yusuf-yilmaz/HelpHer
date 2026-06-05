"""dmgbuild configuration for HelpHer.

Usage (from repo root):
  python3 -m dmgbuild -s installer/macos/dmgbuild-settings.py \
    -D app=build/macos/Build/Products/Release/HelpHer.app \
    "HelpHer" dist/HelpHer.dmg
"""
import os

application = defines.get("app", "build/macos/Build/Products/Release/HelpHer.app")
appname = os.path.basename(application)

format = "UDBZ"
size = None

files = [application]
symlinks = {"Applications": "/Applications"}

icon_locations = {
    appname:        (165, 195),
    "Applications": (495, 195),
}

background = "installer/macos/dmg-background.png"

show_status_bar   = False
show_tab_view     = False
show_toolbar      = False
show_pathbar      = False
show_sidebar      = False
sidebar_width     = 180

window_rect       = ((200, 120), (660, 400))
default_view      = "icon-view"
show_icon_preview = False

icon_size         = 128
text_size         = 12
