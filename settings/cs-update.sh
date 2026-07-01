#!/bin/bash
# cs-update — manual, user-triggered in-place updater for Circuit Sword.
#
# Pulls the latest repo from GitHub and re-applies the USERSPACE components
# (cs-hud + scripts + systemd units + settings + Bluetooth + config.txt's
# non-DPI blocks) WITHOUT a reflash. It never touches the kernel, the WiFi DKMS
# driver, or network-config, so a user's screen choice and WiFi credentials
# survive. Idempotent and safe to re-run; cs-hud is rolled back if it fails.
#
# Modes:
#   cs-update            interactive (check → show changes → ask → apply); ES menu
#   cs-update check      report only — exit 0 up-to-date, 10 update available, 1 error
#   cs-update apply      apply non-interactively
#
# Override the source with CS_REPO_URL / CS_REPO_BRANCH (or pass a branch as $2).

set -uo pipefail

REPO_URL="${CS_REPO_URL:-https://github.com/Antho91/Circuit-Sword.git}"
BRANCH="${2:-${CS_REPO_BRANCH:-master}}"
VERSION_FILE="/var/lib/cs-version"
REPO_ON_DEVICE="/home/pi/Circuit-Sword"

SRC=""; BACKUP=""; NEW_SHA=""; HUD_REBUILT=0
CHANGED=()

log() { echo "[cs-update] $*"; logger -t cs-update "$*" 2>/dev/null || true; }
die() { echo "[cs-update] ERROR: $*" >&2; logger -t cs-update "ERROR: $*" 2>/dev/null || true; exit 1; }

ensure_root() { [ "$(id -u)" -eq 0 ] || exec sudo -E "$0" "$@"; }
remote_sha()  { git ls-remote "$REPO_URL" "$BRANCH" 2>/dev/null | awk 'NR==1{print $1}'; }
local_sha()   { tr -d '[:space:]' < "$VERSION_FILE" 2>/dev/null; }

# ── check: is a newer revision available? ───────────────────────────────────
do_check() {
    local r l ldisp
    r=$(remote_sha) || true
    [ -n "$r" ] || { echo "Could not reach $REPO_URL ($BRANCH) — check your network."; return 1; }
    l=$(local_sha)
    if [ -n "$l" ] && [ "$r" = "$l" ]; then echo "Up to date (${l:0:8})."; return 0; fi
    ldisp=${l:0:8}; [ -n "$ldisp" ] || ldisp="(unknown)"
    echo "Update available: $ldisp -> ${r:0:8}"
    return 10
}

clone_repo() {
    command -v git >/dev/null 2>&1 || die "git not installed"
    SRC=$(mktemp -d /tmp/cs-update.XXXXXX)
    trap 'rm -rf "$SRC"' EXIT
    log "Cloning $REPO_URL ($BRANCH) ..."
    git clone --depth 50 --branch "$BRANCH" "$REPO_URL" "$SRC" >/dev/null 2>&1 || die "clone failed (network?)"
    NEW_SHA=$(git -C "$SRC" rev-parse HEAD)
}

# Short changelog: new commit subjects since the installed revision (or the last
# 10 if that revision isn't in the shallow history).
changes_since() {
    local l; l=$(local_sha)
    if [ -n "$l" ] && git -C "$SRC" cat-file -e "${l}^{commit}" 2>/dev/null; then
        git -C "$SRC" log --oneline --no-decorate "${l}..HEAD" 2>/dev/null | head -15
    else
        git -C "$SRC" log --oneline --no-decorate -10 2>/dev/null
    fi
}

# install_file SRC DEST [MODE] — backup + copy if SRC exists and differs.
install_file() {
    local src="$1" dest="$2" mode="${3:-644}"
    [ -f "$src" ] || return 0
    if [ -f "$dest" ] && cmp -s "$src" "$dest"; then return 0; fi
    mkdir -p "$(dirname "$dest")"
    [ -f "$dest" ] && cp -a "$dest" "$BACKUP/$(echo "$dest" | tr / _)" 2>/dev/null || true
    install -m "$mode" "$src" "$dest"
    CHANGED+=("$dest")
}

# Refresh config.txt from the repo but KEEP the device's existing DPI block (it
# is screen-specific). Never runs if the live file has no DPI block.
update_config_txt() {
    local live=/boot/firmware/config.txt new="$SRC/settings/boot/config.txt" dpi out
    [ -f "$new" ] && [ -f "$live" ] || return 0
    dpi=$(mktemp); out=$(mktemp)
    awk '/# CS START DPI SETTINGS/{f=1} f{print} /# CS END DPI SETTINGS/{f=0}' "$live" > "$dpi"
    if [ ! -s "$dpi" ]; then rm -f "$dpi" "$out"; return 0; fi
    awk -v dpifile="$dpi" '
        /# CS START DPI SETTINGS/ { while ((getline l < dpifile) > 0) print l; ind=1; next }
        /# CS END DPI SETTINGS/   { if (ind) { ind=0; next } }
        !ind { print }
    ' "$new" > "$out"
    if [ -s "$out" ] && ! cmp -s "$out" "$live"; then
        cp -a "$live" "$BACKUP/boot_config.txt" 2>/dev/null || true
        install -m 644 "$out" "$live"
        CHANGED+=("/boot/firmware/config.txt (DPI block preserved)")
    fi
    rm -f "$dpi" "$out"
}

# ── install: re-apply components from the clone, restart, write version ─────
do_install() {
    [ -n "$SRC" ] || die "no clone"
    # Runs as root (via do_apply → ensure_root). Create the rollback backup dir
    # here (needs root), not in clone_repo which may run as the menu user.
    BACKUP=$(mktemp -d /var/lib/cs-update-backup.XXXXXX)

    install_file "$SRC/settings/cs-hdmi-hotplug.sh"     /usr/local/bin/cs-hdmi-hotplug.sh        755
    install_file "$SRC/settings/99-cs-hdmi.rules"       /etc/udev/rules.d/99-cs-hdmi.rules       644
    install_file "$SRC/settings/cs-splash-orient.sh"    /usr/local/bin/cs-splash-orient.sh       755
    install_file "$SRC/settings/cs-splash-orient.service" /etc/systemd/system/cs-splash-orient.service 644
    install_file "$SRC/settings/cs-firstboot-wifi.sh"   /usr/local/bin/cs-firstboot-wifi.sh      755
    install_file "$SRC/settings/cs-update.sh"           /usr/local/bin/cs-update                 755
    install_file "$SRC/settings/cs_shutdown.sh"         /opt/cs_shutdown.sh                       755
    install_file "$SRC/settings/asound.conf"            /etc/asound.conf                         644
    install_file "$SRC/settings/alsa-base.conf"         /etc/modprobe.d/alsa-base.conf           644
    install_file "$SRC/settings/autostart.sh"           /opt/retropie/configs/all/autostart.sh   755
    install_file "$SRC/cs-hud_new/cs-hud.service"       /lib/systemd/system/cs-hud.service       644
    install_file "$SRC/bt-driver/rtl-bluetooth.service" /lib/systemd/system/rtl-bluetooth.service 644
    install_file "$SRC/bt-driver/rtk_hciattach"         /usr/bin/rtk_hciattach                    755

    # Bluetooth firmware (prebuilt in the repo; multiple files)
    if ls "$SRC"/bt-driver/rtlbt_* >/dev/null 2>&1; then
        mkdir -p /lib/firmware/rtl_bt
        for fw in "$SRC"/bt-driver/rtlbt_*; do
            install_file "$fw" "/lib/firmware/rtl_bt/$(basename "$fw")" 644
        done
    fi

    update_config_txt

    # ES "RetroPie" menu entries — mirror settings/retropiemenu/*.{rp,sh} so new
    # features dropped there deploy automatically. Custom launchers must be .sh:
    # the RetroPie launcher maps *.rp to scriptmodules and ignores their content,
    # but runs *.sh directly (as the user, with joy2key).
    if [ -d "$SRC/settings/retropiemenu" ]; then
        mkdir -p /home/pi/RetroPie/retropiemenu
        # Drop the obsolete .rp form of our entry (renamed to .sh).
        rm -f /home/pi/RetroPie/retropiemenu/cs-update.rp
        for entry in "$SRC"/settings/retropiemenu/*.rp "$SRC"/settings/retropiemenu/*.sh; do
            [ -f "$entry" ] || continue
            install_file "$entry" "/home/pi/RetroPie/retropiemenu/$(basename "$entry")" 755
        done
        chown -R pi:pi /home/pi/RetroPie/retropiemenu 2>/dev/null || true
        # Friendly name/description/icon for the entries (gamelist + icons).
        install_file "$SRC/settings/cs-menu-sync.sh" /usr/local/bin/cs-menu-sync 755
        CS_FRAGMENT="$SRC/settings/retropiemenu/gamelist.xml" \
        CS_ICON_SRC="$SRC/settings/retropiemenu/icons" \
            /usr/local/bin/cs-menu-sync 2>/dev/null || true
    fi

    # cs-hud: rebuild from source if it changed
    if [ -d "$SRC/cs-hud_new" ]; then
        log "Rebuilding cs-hud ..."
        if ! command -v sdl2-config >/dev/null 2>&1 || ! dpkg -s libsdl2-ttf-dev >/dev/null 2>&1; then
            log "Installing cs-hud build deps (one-time) ..."
            apt-get update -qq || true
            apt-get install -y --no-install-recommends \
                build-essential libsdl2-dev libsdl2-ttf-dev libdrm-dev >/dev/null 2>&1 \
                || log "WARNING: build deps incomplete — cs-hud rebuild may fail"
        fi
        if make -C "$SRC/cs-hud_new" >/tmp/cs-hud-build.log 2>&1 && [ -f "$SRC/cs-hud_new/cs-hud" ]; then
            cp -a /usr/local/bin/cs-hud "$BACKUP/cs-hud.bak" 2>/dev/null || true
            install -m 755 "$SRC/cs-hud_new/cs-hud" /usr/local/bin/cs-hud
            CHANGED+=("/usr/local/bin/cs-hud"); HUD_REBUILT=1
        else
            log "WARNING: cs-hud build failed (see /tmp/cs-hud-build.log) — keeping current binary"
        fi
    fi

    # Refresh the on-device repo copy (logos, theme refs, etc.)
    if [ -d "$REPO_ON_DEVICE" ]; then
        rsync -a --delete --exclude='.git/' "$SRC/" "$REPO_ON_DEVICE/" 2>/dev/null \
            && chown -R pi:pi "$REPO_ON_DEVICE" 2>/dev/null || true
    fi

    # Reload + restart affected services
    systemctl daemon-reload 2>/dev/null || true
    udevadm control --reload 2>/dev/null || true
    if [ "$HUD_REBUILT" = 1 ] || { [ "${#CHANGED[@]}" -gt 0 ] && printf '%s\n' "${CHANGED[@]}" | grep -q cs-hud; }; then
        log "Restarting cs-hud ..."
        if ! systemctl restart cs-hud.service; then
            log "cs-hud failed to start — rolling back binary"
            [ -f "$BACKUP/cs-hud.bak" ] && install -m 755 "$BACKUP/cs-hud.bak" /usr/local/bin/cs-hud
            systemctl restart cs-hud.service || true
            die "update applied but cs-hud rollback was needed — check 'journalctl -u cs-hud'"
        fi
    fi
    if [ "${#CHANGED[@]}" -gt 0 ] && printf '%s\n' "${CHANGED[@]}" | grep -qE 'rtl-bluetooth|rtk_hciattach|rtl_bt'; then
        log "Restarting rtl-bluetooth ..."
        systemctl restart rtl-bluetooth.service 2>/dev/null || true
    fi

    echo "$NEW_SHA" > "$VERSION_FILE"

    if [ "${#CHANGED[@]}" -eq 0 ]; then
        log "Already current — nothing changed (now at ${NEW_SHA:0:8})."
    else
        log "Updated to ${NEW_SHA:0:8}. Changed ${#CHANGED[@]} component(s):"
        printf '  %s\n' "${CHANGED[@]}"
    fi
}

do_apply() { ensure_root apply "$BRANCH"; clone_repo; do_install; }

# ── menu: interactive (used by the ES "Circuit Sword Updater" entry) ────────
msgbox() {
    if command -v whiptail >/dev/null 2>&1; then whiptail --title "Circuit Sword Updater" --msgbox "$1" 12 64
    else echo "$1"; sleep 2; fi
}

do_menu() {
    # Runs as the invoking user: the RetroPie retropiemenu launcher calls this
    # entry (cs-update.sh) via `sudo -u <user> bash`. Keep the whiptail UI OUT of
    # a root/sudo env so TERM + the tty survive (otherwise whiptail can't render
    # and the menu just flashes back to ES). Elevate only for the install itself.
    export TERM="${TERM:-linux}"
    local msg rc; msg=$(do_check); rc=$?
    if [ "$rc" -ne 10 ]; then msgbox "$msg"; return 0; fi   # up-to-date or error

    clone_repo
    local cl; cl=$(changes_since); [ -n "$cl" ] || cl="(changelog unavailable)"
    if command -v whiptail >/dev/null 2>&1; then
        whiptail --title "Circuit Sword Updater" --yesno \
            "An update is available.\n\nChanges:\n${cl}\n\nDownload and apply now? (a few minutes)" \
            22 74 --scrolltext || { msgbox "Cancelled — nothing changed."; return 0; }
    else
        echo "$msg"; echo "$cl"; read -r -p "Apply now? [y/N] " a; [ "$a" = y ] || { echo Cancelled; return 0; }
    fi

    # Elevate only for the install (writes system paths, apt, systemctl).
    if [ "$(id -u)" -eq 0 ]; then
        do_install
    else
        sudo "$0" apply "$BRANCH"
    fi
    echo; echo "Done. Press a button to return."; read -r -n1 -t 30 || true
}

case "${1:-menu}" in
    check)   do_check ;;
    apply)   do_apply ;;
    menu|"") do_menu ;;
    *) echo "usage: cs-update [check|apply|menu] [branch]"; exit 2 ;;
esac
# --- updater-test marker: 2026-07-01 — safe to delete this branch ---
