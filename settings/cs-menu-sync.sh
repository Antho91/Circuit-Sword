#!/bin/bash
# cs-menu-sync — give Circuit Sword's EmulationStation "RetroPie" menu entries a
# friendly name/description/icon by (1) installing the icons into the retropiemenu
# romdir and (2) merging the gamelist.xml entries into the device's live retropie
# gamelist. Idempotent and safe to re-run; entries are matched by <path> so it
# never duplicates and never touches the built-in RetroPie entries.
#
# Used by the image assembler (build time, against the mounted image) and by
# cs-update (on device, after mirroring the .rp/.sh entries). Everything is
# overridable via env so the same script works in both contexts.
set -uo pipefail

ROMDIR="${CS_ROMDIR:-/home/pi/RetroPie/retropiemenu}"
GAMELIST="${CS_GAMELIST:-/home/pi/.emulationstation/gamelists/retropie/gamelist.xml}"
FRAGMENT="${CS_FRAGMENT:-/home/pi/Circuit-Sword/settings/retropiemenu/gamelist.xml}"
ICON_SRC="${CS_ICON_SRC:-/home/pi/Circuit-Sword/settings/retropiemenu/icons}"
OWNER="${CS_OWNER:-pi:pi}"

[ -f "$FRAGMENT" ] || exit 0
command -v python3 >/dev/null 2>&1 || { echo "[cs-menu-sync] python3 missing — skipping"; exit 0; }

# 1) Install icons into the romdir (alongside the built-in RetroPie icons).
if [ -d "$ICON_SRC" ] && ls "$ICON_SRC/"*.png >/dev/null 2>&1; then
    mkdir -p "$ROMDIR/icons"
    cp -f "$ICON_SRC/"*.png "$ROMDIR/icons/"
fi

# 2) Upsert each <game> from the fragment into the live gamelist (by <path>).
mkdir -p "$(dirname "$GAMELIST")"
python3 - "$GAMELIST" "$FRAGMENT" <<'PY'
import os, sys
import xml.etree.ElementTree as ET

live_path, frag_path = sys.argv[1], sys.argv[2]

def load(path):
    if os.path.exists(path) and os.path.getsize(path) > 0:
        try:
            return ET.parse(path).getroot()
        except ET.ParseError:
            pass
    return ET.Element('gameList')

def key(game):
    p = game.findtext('path')
    return p.strip() if p else None

live = load(live_path)
frag = load(frag_path)

index = {key(g): g for g in live.findall('game') if key(g)}
for g in frag.findall('game'):
    k = key(g)
    if not k:
        continue
    if k in index:
        live.remove(index[k])
    live.append(g)

ET.ElementTree(live).write(live_path, encoding='utf-8', xml_declaration=True)
PY

# 3) Ownership so EmulationStation (running as the user) can read/rewrite them.
if [ -n "$OWNER" ]; then
    chown "$OWNER" "$GAMELIST" 2>/dev/null || true
    [ -d "$ROMDIR/icons" ] && chown -R "$OWNER" "$ROMDIR/icons" 2>/dev/null || true
fi
