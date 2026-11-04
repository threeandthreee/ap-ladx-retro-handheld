#!/bin/sh

# HELP: Patch and play Archipelago Links Awakening DX seeds, or generate a solo game. Runs the client in the background.
# ICON: apladx_icon
# GRID: AP LADX

. /opt/muos/script/var/func.sh

APP_BIN="muxterm"
SETUP_APP "$APP_BIN" ""

# -----------------------------------------------------------------------------
# Applications must use the bind-mounted runtime path, never /mnt/mmc or /mnt/sdcard
APP_DIR="/run/muos/storage/application/APLADX"

chmod +x "$APP_DIR/ap.sh"
sh "$APP_DIR/ap.sh"
