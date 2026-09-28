# dmgbuild settings for the Pollymetric installer (scripts/release.sh passes the -D values).
# The window and icon positions match InstallerArt.swift's background.
import os.path

app = defines["app"]
format = "ULFO"                      # LZFSE: smallest, macOS 10.11+
filesystem = "APFS"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines["volume_icon"]        # the mounted volume's icon on the desktop
background = defines["background"]

window_rect = ((200, 140), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
icon_size = 128
text_size = 13
arrange_by = None
# No hide_extensions: it stores a Finder flag on the app bundle itself, which breaks
# strict code-signature verification. Finder hides ".app" by default anyway.
icon_locations = {
    os.path.basename(app): (170, 190),
    "Applications": (490, 190),
}
