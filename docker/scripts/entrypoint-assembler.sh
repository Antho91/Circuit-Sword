#!/bin/bash
# ============================================================
# Image assembler entrypoint
# Runs inside Dockerfile.assembler (--privileged)
#
# What it does:
#  1. Copies the base RetroPie image to a working copy
#  2. Mounts it (loop device)
#  3. Injects the custom kernel + modules from /output/kernel/
#  4. Injects the cs-hud binary from /output/hud/
#  5. Runs the software configuration (3_install_additional_software.sh logic)
#  6. Unmounts cleanly
#  7. Outputs rpios-cs-final.img to /output/
#
# Expected files in /output/:
#   rpios-bookworm.img      — base RetroPie image (from stage 1)
#   kernel/                 — kernel artifacts (from kernel stage)
#   hud/cs-hud              — HUD binary (from hud stage)
# ============================================================
set -euo pipefail

OUTPUT=/output
WORKSPACE=/workspace
IMG_SRC="$OUTPUT/rpios-bookworm.img"
IMG_DST="$OUTPUT/rpios-cs-final.img"

MNT_BOOT=/mnt/cs-boot
MNT_ROOT=/mnt/cs-root

KERNEL_ARTIFACTS="$OUTPUT/kernel"
HUD_BINARY="$OUTPUT/hud/cs-hud"
WIFI_ARTIFACTS="$OUTPUT/wifi"
SOUND_ARTIFACTS="$OUTPUT/sound"
BT_BINARY="$OUTPUT/bt/rtk_hciattach"

KERNEL_NAME="${KERNEL_NAME:-kernel8}"
TARGET_ARCH="${TARGET_ARCH:-aarch64}"

cleanup() {
    echo "[assembler] Cleaning up mounts..."
    umount "$MNT_BOOT"         2>/dev/null || true
    umount "$MNT_ROOT"         2>/dev/null || true
    if [ -n "${LOOPDEV:-}" ]; then
        losetup -d "$LOOPDEV" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ---- Validation --------------------------------------------
echo "=== Image assembler ==="

[ -f "$IMG_SRC" ]            || { echo "ERROR: $IMG_SRC not found. Run 'retropie' stage first."; exit 1; }
[ -d "$KERNEL_ARTIFACTS" ]   || { echo "ERROR: $KERNEL_ARTIFACTS not found. Run 'kernel' stage first."; exit 1; }
[ -f "$HUD_BINARY" ]         || { echo "ERROR: $HUD_BINARY not found. Run 'hud' stage first."; exit 1; }
[ -f "$WIFI_ARTIFACTS/r8723bs.ko" ] \
                             || { echo "ERROR: $WIFI_ARTIFACTS/r8723bs.ko not found. Run 'wifi' stage first."; exit 1; }
# Sound artifact is no longer baked (we use the stock in-kernel snd-usb-audio —
# the patched volume-fix module is deferred; see FUTURE.md). Not required.
[ -f "$BT_BINARY" ] \
                             || { echo "ERROR: $BT_BINARY not found. Run 'bt' stage first."; exit 1; }
[ -f "$KERNEL_ARTIFACTS/${KERNEL_NAME}.img" ] \
                             || { echo "ERROR: ${KERNEL_NAME}.img missing from kernel artifacts."; exit 1; }

# ---- 1. Create working copy --------------------------------
echo "[assembler] Copying base image → $IMG_DST ..."
cp --sparse=always "$IMG_SRC" "$IMG_DST"

# ---- 2. Mount image ----------------------------------------
echo "[assembler] Mounting image..."
mkdir -p "$MNT_BOOT" "$MNT_ROOT"

LOOPDEV=$(losetup --partscan --find --show "$IMG_DST")
echo "[assembler] Loop device: $LOOPDEV"

mount "${LOOPDEV}p2" "$MNT_ROOT"

# Ensure /boot/firmware mountpoint exists inside rootfs
mkdir -p "$MNT_ROOT/boot/firmware"
mount "${LOOPDEV}p1" "$MNT_BOOT"

echo "[assembler] Mounted:"
echo "  BOOT → $MNT_BOOT"
echo "  ROOT → $MNT_ROOT"

# ---- 3. Inject kernel -------------------------------------
echo "[assembler] Installing kernel..."

# Backup original kernel (only if not done before)
[ -f "$MNT_BOOT/${KERNEL_NAME}-backup.img" ] || \
    cp "$MNT_BOOT/${KERNEL_NAME}.img" "$MNT_BOOT/${KERNEL_NAME}-backup.img"

cp "$KERNEL_ARTIFACTS/${KERNEL_NAME}.img" "$MNT_BOOT/${KERNEL_NAME}.img"
cp "$KERNEL_ARTIFACTS/"*.dtb              "$MNT_BOOT/"
cp "$KERNEL_ARTIFACTS/overlays/"*.dtb*    "$MNT_BOOT/overlays/"
cp "$KERNEL_ARTIFACTS/overlays/README"    "$MNT_BOOT/overlays/"


# Extract kernel modules into rootfs
echo "[assembler] Extracting kernel modules..."
tar xzf "$KERNEL_ARTIFACTS/modules.tar.gz" -C "$MNT_ROOT"
# In Bookworm /lib is a symlink to usr/lib. tar replaces it with a real
# directory when extracting modules. Move the content back and restore it.
if [ -d "$MNT_ROOT/lib" ] && [ ! -L "$MNT_ROOT/lib" ]; then
    cp -a "$MNT_ROOT/lib/." "$MNT_ROOT/usr/lib/"
    rm -rf "$MNT_ROOT/lib"
    ln -sf usr/lib "$MNT_ROOT/lib"
    echo "[assembler] Restored /lib -> usr/lib symlink (broken by tar)"
fi

# ---- 4. Inject cs-hud binary + pigpio runtime library -----
echo "[assembler] Installing cs-hud binary..."
cp "$HUD_BINARY"                           "$MNT_ROOT/usr/local/bin/cs-hud"
chmod 755                                  "$MNT_ROOT/usr/local/bin/cs-hud"

# cs-hud links against libpigpio.so.1, which the base image does not ship.
# Bake it into the multiarch lib dir so the dynamic linker finds it by SONAME.
# (Relying on a first-boot 'apt-get install pigpio' fails with no network.)
HUD_DIR="$(dirname "$HUD_BINARY")"
if ls "$HUD_DIR"/libpigpio.so* >/dev/null 2>&1; then
    cp -av "$HUD_DIR"/libpigpio.so* "$MNT_ROOT/usr/lib/aarch64-linux-gnu/"
    echo "[assembler] Installed libpigpio runtime library"
else
    echo "[assembler] WARNING: libpigpio.so not found next to HUD binary — cs-hud will not start"
fi

# ---- 5. Software configuration ----------------------------
# Run the software install script with the mounted paths
echo "[assembler] Running software configuration..."

# Use DEST / DESTBOOT variables that 3_install_additional_software.sh understands
export IMG="$IMG_DST"
export BASE_DIR="$WORKSPACE/build"
export START_FOLDER="$WORKSPACE/build"
export IMG_DIR="$(dirname "$IMG_DST")"
export MNT_BOOT="$MNT_BOOT"
export MNT_ROOT="$MNT_ROOT"

# CRITICAL: the RetroPie chroot build leaves the root directory '/' as 0700.
# That blocks every service running as a non-root User= (dbus->messagebus,
# polkit->polkitd, avahi) from chdir()-ing into '/', so they die with
# status=200/CHDIR. dbus failing then cascades into a dead system (no login,
# no network, bluetooth crash-loop). Normalize '/' to the standard 0755.
chmod 755 "$MNT_ROOT"
echo "[assembler] Set / to 0755 (RetroPie chroot leaves it 0700, which breaks dbus)"

mkdir -p "$MNT_ROOT/etc/systemd/system"
pi_uid=$(grep "^pi:" "$MNT_ROOT/etc/passwd" 2>/dev/null | cut -d: -f3 || echo 1000)
pi_gid=$(grep "^pi:" "$MNT_ROOT/etc/passwd" 2>/dev/null | cut -d: -f4 || echo 1000)

ln -sf /dev/null "$MNT_ROOT/etc/systemd/system/userconfig.service"

# DISABLE cloud-init entirely. It does nothing useful here (the user is baked in
# below, WiFi is handled by cs-firstboot-wifi), but its boot stages run slowly and
# hold up NetworkManager — adding ~2-3 minutes to boot before WiFi and cs-hud
# start. Everything cloud-init would do is baked in deterministically.
touch "$MNT_ROOT/etc/cloud/cloud-init.disabled"
rm -rf "$MNT_ROOT/var/lib/cloud/"
echo "[assembler] cloud-init disabled (slow boot stages; not needed)"

# Remove empty 90-NM-*.yaml stubs from netplan (harmless leftovers).
find "$MNT_ROOT/etc/netplan" -name '90-NM-*.yaml' -delete 2>/dev/null || true

# Set pi user password and sudo directly — cloud-init does not update existing users,
# and the pi user already exists in rpios-bookworm.img from the retropie build.
PI_HASH='$6$PgBUYJMZ/hp0yJ3/$KokEwM.wyRM9BKnzJs38Gz5s6a6M/LYfKhc3M2hWF7A2bajXZcqzhwTBWAs.ubUpLIIcL7bRuPyI/PGJDQZrJ.'
if grep -q "^pi:" "$MNT_ROOT/etc/shadow" 2>/dev/null; then
    sed -i "s|^pi:[^:]*:|pi:${PI_HASH}:|" "$MNT_ROOT/etc/shadow"
    echo "[assembler] pi password hash set in /etc/shadow"
fi

# Newer RPi OS base images ship the 'pi' user DISABLED — login shell set to
# /usr/sbin/nologin until first-boot user setup. We bypass that setup, so force a
# real login shell (replace pi's last passwd field); otherwise tty1 autologin (and
# SSH) fail with "This account is currently not available." and ES never starts.
sed -i '/^pi:/ s|:[^:]*$|:/bin/bash|' "$MNT_ROOT/etc/passwd"
echo "[assembler] pi login shell set to /bin/bash"

echo "pi ALL=(ALL) NOPASSWD:ALL" > "$MNT_ROOT/etc/sudoers.d/010_pi-nopasswd"
chmod 440 "$MNT_ROOT/etc/sudoers.d/010_pi-nopasswd"

# Enable SSH — set it now as a hard guarantee, cloud-init runcmd also enables it.
ln -sf /lib/systemd/system/ssh.service \
    "$MNT_ROOT/etc/systemd/system/multi-user.target.wants/ssh.service" 2>/dev/null || \
ln -sf /lib/systemd/system/sshd.service \
    "$MNT_ROOT/etc/systemd/system/multi-user.target.wants/sshd.service" 2>/dev/null || true
echo "[assembler] SSH enabled, pi sudo configured"

# Auto-login pi on tty1 (DPI display).
mkdir -p "$MNT_ROOT/etc/systemd/system/getty@tty1.service.d"
cat > "$MNT_ROOT/etc/systemd/system/getty@tty1.service.d/autologin.conf" << 'AUTOLOGIN'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin pi --noclear %I $TERM
AUTOLOGIN

# Explicitly enable getty@tty1 so it actually starts at boot. RetroPie's
# enable_autostart never ran in our chroot build, so getty@tty1 was left
# disabled and the autologin (and thus EmulationStation) never started.
mkdir -p "$MNT_ROOT/etc/systemd/system/getty.target.wants"
ln -sf /lib/systemd/system/getty@.service \
    "$MNT_ROOT/etc/systemd/system/getty.target.wants/getty@tty1.service"
echo "[assembler] tty1 autologin configured + getty@tty1 enabled"

# --- Boot speed: don't make EmulationStation wait for the network ----------
# The RTL8723BS WiFi driver takes several seconds to bring up wlan0, which
# NetworkManager (and thus network.target) waits for. Debian's
# systemd-user-sessions.service is ordered After=network.target, so the tty1
# autologin -> EmulationStation path was blocked on WiFi association (~16s).
# Drop that ordering so ES starts ~9s sooner; WiFi still comes up in the
# background. We override the shipped unit with a copy that has network.target
# removed (a drop-in After= reset did NOT take on systemd 257).
if [ -f "$MNT_ROOT/usr/lib/systemd/system/systemd-user-sessions.service" ]; then
    cp "$MNT_ROOT/usr/lib/systemd/system/systemd-user-sessions.service" \
       "$MNT_ROOT/etc/systemd/system/systemd-user-sessions.service"
    sed -i 's/ network.target//' \
       "$MNT_ROOT/etc/systemd/system/systemd-user-sessions.service"
    echo "[assembler] Decoupled systemd-user-sessions from network.target"
fi

# NetworkManager-wait-online blocks boot until the network is online — nothing on
# a handheld needs that. Mask it so network-online.target is reached promptly.
ln -sf /dev/null "$MNT_ROOT/etc/systemd/system/NetworkManager-wait-online.service"

# udisks2 (removable-media automounting) isn't needed on a fixed handheld; mask
# it (offline we can't know where it was enabled, so masking is definitive).
ln -sf /dev/null "$MNT_ROOT/etc/systemd/system/udisks2.service"
echo "[assembler] Boot-speed tweaks applied (wait-online masked, udisks2 off)"

PIHOMEDIR="$MNT_ROOT/home/pi"
BINDIR="$PIHOMEDIR/Circuit-Sword"
SYSTEMD="$MNT_ROOT/lib/systemd/system"

# Copy repo into image (exclude build outputs and large/unnecessary files)
rsync -a --delete \
    --exclude='output/' \
    --exclude='.git/' \
    --exclude='*.img' \
    --exclude='*.img.xz' \
    --exclude='rp_build_image/' \
    --exclude='docker/' \
    --exclude='build/' \
    --exclude='wifi-driver/' \
    --exclude='sound-module/' \
    --exclude='.claude/' \
    --exclude='docker-compose.yml' \
    --exclude='build.sh' \
    --exclude='build.log' \
    "$WORKSPACE/" "$BINDIR/"
# Fix ownership — Docker runs as root so /home/pi and its contents need explicit chown.
chown ${pi_uid}:${pi_gid} "$PIHOMEDIR"
chmod 755 "$PIHOMEDIR"
chown -R ${pi_uid}:${pi_gid} "$BINDIR"

# RetroPie autostart trigger. EmulationStation is started from
# /opt/retropie/configs/all/autostart.sh, which is launched by the pi user's
# ~/.bash_profile on tty1. The RetroPie 'enable_autostart' step never ran in the
# chroot build, so this file is missing and ES never starts. Create it here.
cat > "$PIHOMEDIR/.bash_profile" << 'BASHPROFILE'
# Bash reads .bash_profile for login shells and skips .profile entirely when
# .bash_profile exists. Source .profile here so .bashrc (colour prompt, aliases,
# etc.) is still loaded for SSH sessions and interactive use.
[ -f "$HOME/.profile" ] && . "$HOME/.profile"

# Launch EmulationStation on the console (tty1), not over SSH.
# On the very first boot the setup service hasn't run yet (no sentinel) — show
# the progress screen instead so the user knows what's happening.
if [ "$(tty)" = "/dev/tty1" ] && [ -z "$SSH_CONNECTION" ]; then
    if [ ! -f /var/lib/cs-firstboot.done ]; then
        /usr/local/bin/cs-firstboot-display.sh
    else
        /opt/retropie/configs/all/autostart.sh
    fi
fi
BASHPROFILE
chown ${pi_uid}:${pi_gid} "$PIHOMEDIR/.bash_profile"
chmod 644 "$PIHOMEDIR/.bash_profile"
echo "[assembler] Created /home/pi/.bash_profile (RetroPie autostart trigger)"

# Progress screen shown on tty1 during first-boot setup (runs instead of ES).
# Kills the fbi splash, prints a header, then streams [cs-firstboot] log lines
# live until the sentinel appears. The firstboot script reboots when done.
cat > "$MNT_ROOT/usr/local/bin/cs-firstboot-display.sh" << 'DISPLAYSCRIPT'
#!/bin/bash
LOGFILE=/boot/firmware/cs-firstboot.log
SENTINEL=/var/lib/cs-firstboot.done

pkill -x fbi 2>/dev/null || true   # release framebuffer from splash screen
sleep 0.5
clear
printf '\e[?25l'   # hide cursor

echo ""
echo "  =================================================="
echo "   Circuit Sword -- First Boot Setup"
echo "  =================================================="
echo ""
echo "   Setting up your device. This takes a few minutes."
echo "   This only happens once."
echo ""
echo "   Do NOT switch off the device!"
echo ""
echo "  --------------------------------------------------"
echo "   Progress:"
echo ""

touch "$LOGFILE" 2>/dev/null || true
tail -f "$LOGFILE" 2>/dev/null | grep --line-buffered '^\[cs-firstboot\]' | \
    while IFS= read -r line; do echo "   $line"; done &
TAIL_PID=$!

while [ ! -f "$SENTINEL" ]; do sleep 2; done
kill "$TAIL_PID" 2>/dev/null

echo ""
echo "  =================================================="
echo "   Setup done! Rebooting..."
echo "  =================================================="
printf '\e[?25h'   # restore cursor

# Do NOT exit — if this script returns, getty restarts the login and
# .bash_profile would launch ES before the reboot happens.
sleep infinity
DISPLAYSCRIPT
chmod +x "$MNT_ROOT/usr/local/bin/cs-firstboot-display.sh"
echo "[assembler] First-boot progress display script installed"

# zram swap (~1GB), the FAST primary swap. The CM3 has only 1GB RAM; compressed
# RAM swap gives headroom for heavier emulators (PSX/N64) and on-device
# kernel-module builds, with no SD-card wear. High swap-priority so it's used
# before the low-priority SD emergency swapfile (created by cs-firstboot-resize).
# Lives in RAM, not on disk — independent of the partition resize. Compressed
# (zstd) ~1GB of swap costs far less physical RAM than it provides.
# (Make sure the service isn't masked from an earlier build.)
rm -f "$MNT_ROOT/etc/systemd/system/systemd-zram-setup@.service"
# Use a high-numbered DROP-IN so our settings win over the base image's rpi-swap
# config (/usr/lib/systemd/zram-generator.conf.d/20-rpi-swap-zram0-ctrl.conf),
# which otherwise forces zram-size = RAM (~730M on the CM3). Drop-ins are sorted
# by filename, so 99- is applied last and wins — and /etc survives rpi-swap updates.
mkdir -p "$MNT_ROOT/etc/systemd/zram-generator.conf.d"
cat > "$MNT_ROOT/etc/systemd/zram-generator.conf.d/99-circuit-sword.conf" << 'ZRAM'
[zram0]
zram-size = 1024
compression-algorithm = zstd
swap-priority = 100
ZRAM
echo "[assembler] Enabled zram swap (1GB, zstd, pri=100) + SD backstop (pri=10)"

# Boot config
if [ ! -f "$MNT_BOOT/config_ORIGINAL.txt" ]; then
    cp "$MNT_BOOT/config.txt"            "$MNT_BOOT/config_ORIGINAL.txt"
    cp "$BINDIR/settings/boot/config.txt" "$MNT_BOOT/config.txt"
    cp "$BINDIR/settings/boot/.ssh"       "$MNT_BOOT/.ssh" 2>/dev/null || true
fi
if ! grep -q "CS CONFIG VERSION: 1.1" "$MNT_BOOT/config.txt"; then
    cp "$BINDIR/settings/boot/config.txt" "$MNT_BOOT/config.txt"
fi

# Hostname — bake it in.
echo "CircuitSword" > "$MNT_ROOT/etc/hostname"
sed -i 's/127.0.1.1.*/127.0.1.1\tCircuitSword/' "$MNT_ROOT/etc/hosts" 2>/dev/null || \
    echo -e "127.0.1.1\tCircuitSword" >> "$MNT_ROOT/etc/hosts"

# WiFi: only the network-config stays on the FAT boot partition so the end user
# can edit their SSID/password from any PC. cs-firstboot-wifi.service reads it and
# configures NetworkManager on every boot. (cloud-init is disabled — see above —
# so its user-data/meta-data are no longer written.)
cp "$BINDIR/settings/network-config" "$MNT_BOOT/network-config"
echo "[assembler] network-config copied to boot partition (read by cs-firstboot-wifi)"

# Circuit Sword runtime config (MODE, CLONER, TESTER, STARTUPEXEC)
# Sourced by autostart.sh on each boot. Edit to change boot mode.
cp "$BINDIR/settings/boot/config-cs.txt" "$MNT_BOOT/config-cs.txt"
echo "[assembler] Copied config-cs.txt to boot partition"

# Audio
cp "$BINDIR/settings/asound.conf"       "$MNT_ROOT/etc/asound.conf"
cp "$BINDIR/settings/alsa-base.conf"    "$MNT_ROOT/etc/modprobe.d/alsa-base.conf"

# Samba network shares for the RetroPie folders (roms/bios/configs).
# The samba package itself is installed by the cs-firstboot service (needs network);
# this just bakes in the share config so \\CircuitSword\roms etc. work once it's up.
mkdir -p "$MNT_ROOT/etc/samba"
cp "$BINDIR/settings/smb.conf"          "$MNT_ROOT/etc/samba/smb.conf"
echo "[assembler] Installed Samba share config (roms/bios/configs/splashscreens)"

# Autostart
mkdir -p "$MNT_ROOT/opt/retropie/configs/all"
if [ -f "$MNT_ROOT/opt/retropie/configs/all/autostart.sh" ] && \
   [ ! -f "$MNT_ROOT/opt/retropie/configs/all/autostart_ORIGINAL.sh" ]; then
    mv "$MNT_ROOT/opt/retropie/configs/all/autostart.sh" \
       "$MNT_ROOT/opt/retropie/configs/all/autostart_ORIGINAL.sh"
fi
cp "$BINDIR/settings/autostart.sh" \
   "$MNT_ROOT/opt/retropie/configs/all/autostart.sh"
chown "$pi_uid:$pi_gid" "$MNT_ROOT/opt/retropie/configs/all/autostart.sh"
cp "$BINDIR/settings/cs_shutdown.sh" "$MNT_ROOT/opt/cs_shutdown.sh"

# Boot splash: use our kr_logo.png (rotated 180° to match the DPI panel) as the
# RetroPie splash, exactly like the original install.sh did. Our Docker pipeline
# wasn't installing this, so fresh images fell back to retropie-default.png.
cp "$BINDIR/settings/splashscreen.list" "$MNT_ROOT/etc/splashscreen.list"
echo "[assembler] Boot splash set to kr_logo.png (via /etc/splashscreen.list)"

# Splash orientation: point /etc/splashscreen.list at the image matching the
# display this boot will use (HDMI = upright kr_logo_hdmi.png, DPI handheld =
# pre-rotated kr_logo.png). Runs BEFORE asplashscreen reads the list, so the
# splash is correct even after a power-cycle with a changed cable state (when no
# hotplug ran to set it). Unknown/absent HDMI defaults to the DPI image, so the
# handheld panel is always right-side-up.
cat > "$MNT_ROOT/usr/local/bin/cs-splash-orient.sh" << 'SPLASHORIENT'
#!/bin/bash
if [ "$(cat /sys/class/drm/card0-HDMI-A-1/status 2>/dev/null)" = "connected" ]; then
    echo /home/pi/Circuit-Sword/settings/kr_logo_hdmi.png > /etc/splashscreen.list
else
    echo /home/pi/Circuit-Sword/settings/kr_logo.png > /etc/splashscreen.list
fi
SPLASHORIENT
chmod +x "$MNT_ROOT/usr/local/bin/cs-splash-orient.sh"

cat > "$MNT_ROOT/etc/systemd/system/cs-splash-orient.service" << 'SPLASHORIENTSVC'
[Unit]
Description=Set Circuit Sword boot splash orientation to match the active display
DefaultDependencies=no
After=console-setup.service
Before=asplashscreen.service
ConditionPathExists=/usr/local/bin/cs-splash-orient.sh

[Service]
Type=oneshot
ExecStart=/usr/local/bin/cs-splash-orient.sh
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
SPLASHORIENTSVC
mkdir -p "$MNT_ROOT/etc/systemd/system/sysinit.target.wants"
ln -sf /etc/systemd/system/cs-splash-orient.service \
   "$MNT_ROOT/etc/systemd/system/sysinit.target.wants/cs-splash-orient.service"
echo "[assembler] Installed cs-splash-orient.service (boot splash follows the display)"

# Fix splashscreen sound
for f in "$MNT_ROOT/etc/init.d/asplashscreen" \
         "$MNT_ROOT/opt/retropie/supplementary/splashscreen/asplashscreen.sh"; do
    [ -f "$f" ] && sed -i 's/ *both/ alsa/' "$f"
done

# VICE audio
mkdir -p "$PIHOMEDIR/.vice/"
echo 'SoundOutput=2' > "$PIHOMEDIR/.vice/sdl-vicerc"
chown -R "$pi_uid:$pi_gid" "$PIHOMEDIR/.vice/"

# Pixel theme
if [ ! -f "$MNT_ROOT/etc/emulationstation/themes/pixel/system/theme.xml" ]; then
    mkdir -p "$MNT_ROOT/etc/emulationstation/themes"
    git clone --recursive --depth 1 --branch master \
        https://github.com/krextra/es-theme-pixel.git \
        "$MNT_ROOT/etc/emulationstation/themes/pixel"
fi

# EmulationStation defaults: select the pixel theme (cloned above) and use
# instant view transitions (snappier on the CM3). Pre-seed es_settings.cfg — ES
# reads these on first launch and rewrites the full file (preserving them) on
# exit. Patch existing keys in place, else append.
#
# IMPORTANT: /home/pi/.emulationstation is a SYMLINK to the absolute path
# /opt/retropie/configs/all/emulationstation, which only resolves inside the
# target system. From the build host that symlink is dangling, so we MUST write
# the real file under $MNT_ROOT directly (never through the symlink, or mkdir/sed
# operate on the host's filesystem and abort the build).
ES_CFG="$MNT_ROOT/opt/retropie/configs/all/emulationstation/es_settings.cfg"
if [ -d "$MNT_ROOT/opt/retropie/configs/all" ]; then
    mkdir -p "$(dirname "$ES_CFG")"
    [ -f "$ES_CFG" ] || printf '<?xml version="1.0"?>\n' > "$ES_CFG"
    es_set_string() { # name value
        if grep -q "name=\"$1\"" "$ES_CFG"; then
            sed -i "s|name=\"$1\" value=\"[^\"]*\"|name=\"$1\" value=\"$2\"|" "$ES_CFG"
        else
            echo "<string name=\"$1\" value=\"$2\" />" >> "$ES_CFG"
        fi
    }
    es_set_string ThemeSet       pixel
    es_set_string TransitionStyle instant
    chown "$pi_uid:$pi_gid" "$ES_CFG"
    echo "[assembler] ES defaults: theme=pixel, transitions=instant"
else
    echo "[assembler] WARNING: RetroPie configs dir missing — skipped ES defaults"
fi

# RetroArch autosave (file may not exist yet — created on first RetroArch run)
RA_CFG="$MNT_ROOT/opt/retropie/configs/all/retroarch.cfg"
if [ -f "$RA_CFG" ]; then
    sed -i 's/# autosave_interval =/autosave_interval = "30"/' "$RA_CFG" || true
    # Show battery + clock in the RetroArch menu bar. The clock works as-is; the
    # battery icon needs a /sys/class/power_supply provider that cs-hud feeds
    # (set up separately). For each key: drop any existing (commented or not)
    # line, then append the desired value (RetroArch honours the last occurrence).
    for kv in 'menu_battery_level_enable = "true"' 'menu_timedate_enable = "true"'; do
        key="${kv%% =*}"
        sed -i "/^[#[:space:]]*${key}[[:space:]]*=/d" "$RA_CFG"
        echo "$kv" >> "$RA_CFG"
    done
    echo "[assembler] RetroArch: battery + clock indicators enabled"
fi

# Bluetooth firmware
mkdir -p "$MNT_ROOT/lib/firmware/rtl_bt/"
cp "$BINDIR/bt-driver/rtlbt_"* "$MNT_ROOT/lib/firmware/rtl_bt/"

# Remove serial console (needed for Bluetooth UART)
sed -i 's/console=serial0,115200 //' "$MNT_BOOT/cmdline.txt" || true

# Fix hciuart service serial port reference (may not exist in all images)
sed -i 's/dev-serial1.device/dev-ttyAMA0.device/' \
    "$MNT_ROOT/lib/systemd/system/hciuart.service" 2>/dev/null || true

# Disable slow-boot services
rm -f "$MNT_ROOT/etc/systemd/system/dhcpcd.service.d/wait.conf"
rm -f "$MNT_ROOT/etc/systemd/system/multi-user.target.wants/wifi-country.service"
rm -f "$MNT_ROOT/etc/systemd/system/multi-user.target.wants/NetworkManager-wait-online.service"

# Ramdisk
if ! grep -q '/ramdisk' "$MNT_ROOT/etc/fstab"; then
    echo 'tmpfs    /ramdisk    tmpfs    defaults,noatime,nosuid,size=100k    0 0' \
        >> "$MNT_ROOT/etc/fstab"
fi

# Install + ENABLE the cs-hud service so the HUD runs from boot, concurrently
# with EmulationStation. The daemon only polls GPIO/serial in the background; it
# does NOT touch the DRM device until the menu is opened (menu_show does a VT
# switch to overlay on top of ES/RetroArch and hands the display back on close).
# Running it from boot is required for the power-switch + low-battery
# auto-shutdown to work even while a game is running.
mkdir -p "$SYSTEMD" "$MNT_ROOT/etc/systemd/system/multi-user.target.wants"
rm -f "$MNT_ROOT/etc/systemd/system/cs-hud.service"
cp "$BINDIR/cs-hud_new/cs-hud.service" "$SYSTEMD/cs-hud.service"
ln -sf "/lib/systemd/system/cs-hud.service" \
       "$MNT_ROOT/etc/systemd/system/multi-user.target.wants/cs-hud.service"

# Install + enable the WiFi setup service. cloud-init does not reliably render
# the network on this image, so this service configures WiFi from
# /boot/firmware/network-config via NetworkManager on every boot (idempotent,
# keeps WiFi editable on the boot partition).
cp "$BINDIR/settings/cs-firstboot-wifi.sh" "$MNT_ROOT/opt/cs-firstboot-wifi.sh"
chmod 755 "$MNT_ROOT/opt/cs-firstboot-wifi.sh"
cp "$BINDIR/settings/cs-firstboot-wifi.service" "$SYSTEMD/cs-firstboot-wifi.service"
ln -sf "/lib/systemd/system/cs-firstboot-wifi.service" \
       "$MNT_ROOT/etc/systemd/system/multi-user.target.wants/cs-firstboot-wifi.service"

# Install Bluetooth service
cp "$BINDIR/bt-driver/rtl-bluetooth.service" \
   "$MNT_ROOT/lib/systemd/system/rtl-bluetooth.service"
cp "$BT_BINARY" "$MNT_ROOT/usr/bin/rtk_hciattach"
chmod 755 "$MNT_ROOT/usr/bin/rtk_hciattach"
ln -sf "/lib/systemd/system/rtl-bluetooth.service" \
       "$MNT_ROOT/etc/systemd/system/rtl-bluetooth.service"
ln -sf "/lib/systemd/system/rtl-bluetooth.service" \
       "$MNT_ROOT/etc/systemd/system/multi-user.target.wants/rtl-bluetooth.service"

# Make bluetoothd power the adapter on at boot (the service above clears the
# rfkill soft-block; AutoEnable then powers it on, so a trusted controller
# reconnects without manual `bluetoothctl power on`).
BT_CONF="$MNT_ROOT/etc/bluetooth/main.conf"
if [ -f "$BT_CONF" ]; then
    if grep -qE '^[[:space:]]*#?[[:space:]]*AutoEnable' "$BT_CONF"; then
        sed -i -E 's/^[[:space:]]*#?[[:space:]]*AutoEnable[[:space:]]*=.*/AutoEnable=true/' "$BT_CONF"
    elif grep -q '^\[Policy\]' "$BT_CONF"; then
        sed -i '/^\[Policy\]/a AutoEnable=true' "$BT_CONF"
    else
        printf '\n[Policy]\nAutoEnable=true\n' >> "$BT_CONF"
    fi
    echo "[assembler] Set bluetooth AutoEnable=true"
fi

# HDMI hotplug: on a REAL cable change, reboot. A fresh boot reliably brings ES
# up on the right display (HDMI@1080p when plugged, DPI@640x480 when not) —
# live-switching ES is unreliable on SDL/KMSDRM (it keeps inheriting the DPI's
# 640x480). Both the DPI overlay and HDMI stay active in config.txt at all times,
# so the DPI panel is never left undriven (an undriven panel shows stuck garbage
# that only a power-cycle clears). We compare the live cable state against the
# value autostart.sh recorded at boot, so spurious DRM events and the already-
# matched state never trigger a reboot loop. The udev rule fires on any DRM HPD.
cat > "$MNT_ROOT/usr/local/bin/cs-hdmi-hotplug.sh" << 'HDMIHOTPLUG'
#!/bin/bash
# Skip during first-boot setup (sentinel absent = setup still running)
[ -f /var/lib/cs-firstboot.done ] || exit 0

# Debounce: ignore events within 8 seconds of the last run (HPD fires a burst)
LOCK=/run/cs-hdmi-switch.lock
NOW=$(date +%s)
if [ -f "$LOCK" ]; then
    LAST=$(cat "$LOCK" 2>/dev/null || echo 0)
    [ $((NOW - LAST)) -lt 8 ] && exit 0
fi
echo "$NOW" > "$LOCK"

# Act only on a real change away from what we booted with.
CUR=$(cat /sys/class/drm/card0-HDMI-A-1/status 2>/dev/null || echo unknown)
BOOT=$(cat /run/cs-hdmi-boot-state 2>/dev/null || echo unknown)
[ "$BOOT" = "unknown" ] && exit 0
[ "$CUR"  = "unknown" ] && exit 0
[ "$CUR"  = "$BOOT" ]   && exit 0

# Brief settle, then re-confirm the change is real and stable before rebooting.
sleep 1
CUR2=$(cat /sys/class/drm/card0-HDMI-A-1/status 2>/dev/null || echo unknown)
[ "$CUR2" != "$CUR" ]   && exit 0
[ "$CUR2" = "$BOOT" ]   && exit 0

# Splash orientation is set at boot by cs-splash-orient.service, so we don't
# touch /etc/splashscreen.list here.
logger -t cs-hdmi "HDMI changed ($BOOT -> $CUR2) — rebooting to switch display"
# Save a running game before the reboot.
[ -p /tmp/retroarch.fifo ] && { echo "SAVE_STATE" > /tmp/retroarch.fifo; sleep 0.5; }
sync
systemctl reboot
HDMIHOTPLUG
chmod +x "$MNT_ROOT/usr/local/bin/cs-hdmi-hotplug.sh"

mkdir -p "$MNT_ROOT/etc/udev/rules.d"
cat > "$MNT_ROOT/etc/udev/rules.d/99-cs-hdmi.rules" << 'UDEVRULE'
ACTION=="change", KERNEL=="card0", SUBSYSTEM=="drm", RUN+="/usr/local/bin/cs-hdmi-hotplug.sh"
UDEVRULE
echo "[assembler] HDMI hotplug handler installed"

# Re-enable first-boot root partition expansion.
#
# Bookworm uses init_resize.sh via init= in cmdline.txt (not resize2fs_once.service
# which was removed in Buster/Bullseye). The base image may have been booted once
# Install a self-contained first-boot resize service.
# Works regardless of RPi OS version — does not rely on init_resize.sh
# which may or may not be present in Bookworm images.
cat > "$MNT_ROOT/usr/local/bin/cs-firstboot-resize.sh" << 'RESIZE'
#!/bin/bash
# Expand root partition + filesystem to fill the SD card on first boot.
set -e
ROOT_DEV=$(findmnt -n -o SOURCE / 2>/dev/null || true)
[ -z "$ROOT_DEV" ] && exit 0

if [[ "$ROOT_DEV" == *mmcblk* ]]; then
    DISK="${ROOT_DEV%p[0-9]*}"
    PARTNUM="${ROOT_DEV##*p}"
else
    DISK="${ROOT_DEV%[0-9]}"
    PARTNUM="${ROOT_DEV##*[a-z]}"
fi

echo "[cs-resize] Expanding $DISK partition $PARTNUM..."
growpart "$DISK" "$PARTNUM" || true
echo "[cs-resize] Resizing filesystem on $ROOT_DEV..."
resize2fs "$ROOT_DEV" || true
echo "[cs-resize] Done."

# Small SD swap file as a LOW-priority emergency backstop (zram is the fast
# primary; this only kicks in when zram is exhausted, so the slow/wear-prone SD
# is barely touched). Created here — right after the resize — so there's space
# and it never bloats the shipped (minimised) image.
SWAPFILE=/swapfile
if [ ! -e "$SWAPFILE" ]; then
    echo "[cs-resize] Creating 512M SD emergency swap (pri=10)..."
    fallocate -l 512M "$SWAPFILE" 2>/dev/null || \
        dd if=/dev/zero of="$SWAPFILE" bs=1M count=512 2>/dev/null
    chmod 600 "$SWAPFILE"
    mkswap "$SWAPFILE" >/dev/null 2>&1
    grep -q "^$SWAPFILE " /etc/fstab 2>/dev/null || \
        echo "$SWAPFILE none swap sw,pri=10 0 0" >> /etc/fstab
    swapon "$SWAPFILE" 2>/dev/null || true
fi

# Self-remove so nothing lingers after the first boot (the open fd keeps this
# script readable until we exit, so deleting it mid-run is safe).
systemctl disable cs-firstboot-resize.service 2>/dev/null || true
rm -f /etc/systemd/system/multi-user.target.wants/cs-firstboot-resize.service \
      /lib/systemd/system/cs-firstboot-resize.service
systemctl daemon-reload 2>/dev/null || true
rm -f /usr/local/bin/cs-firstboot-resize.sh
RESIZE
chmod +x "$MNT_ROOT/usr/local/bin/cs-firstboot-resize.sh"

cat > "$MNT_ROOT/lib/systemd/system/cs-firstboot-resize.service" << 'SVC'
[Unit]
Description=Circuit Sword first-boot partition resize
DefaultDependencies=no
After=local-fs-pre.target
Before=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/cs-firstboot-resize.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVC

mkdir -p "$MNT_ROOT/etc/systemd/system/multi-user.target.wants"
ln -sf "/lib/systemd/system/cs-firstboot-resize.service" \
       "$MNT_ROOT/etc/systemd/system/multi-user.target.wants/cs-firstboot-resize.service"
echo "[assembler] First-boot resize service installed"

# ---- WiFi DKMS setup ------------------------------------
echo "[assembler] Installing RTL8723BS WiFi DKMS package..."

DKMS_NAME="rtl8723bs"
DKMS_VER="1.0.0"
DKMS_SRC="$MNT_ROOT/usr/src/${DKMS_NAME}-${DKMS_VER}"

# Extract kernel version from the modules tarball (not the directory listing,
# which may contain the base image's official kernel alongside our custom one).
KVER=$(tar -tzf "$KERNEL_ARTIFACTS/modules.tar.gz" \
    | sed -n 's|^\./lib/modules/\([^/]*\)/.*|\1|p' \
    | sort -u | head -1)
echo "[assembler] Target kernel: $KVER"

# Install DKMS source into the image
mkdir -p "$DKMS_SRC"
rsync -a --delete "$WIFI_ARTIFACTS/src/" "$DKMS_SRC/"
# dkms.conf + Makefile are config, not built artifacts — read them straight from
# the repo so 'build.sh software' picks up changes (e.g. BUILD_EXCLUSIVE_KERNEL)
# WITHOUT re-running the slow 'wifi' stage. Fall back to the artifact otherwise.
if [ -f "$BINDIR/wifi-driver/dkms.conf" ]; then
    cp "$BINDIR/wifi-driver/dkms.conf" "$DKMS_SRC/dkms.conf"
    cp "$BINDIR/wifi-driver/Makefile"  "$DKMS_SRC/Makefile"
else
    cp "$WIFI_ARTIFACTS/dkms.conf" "$DKMS_SRC/dkms.conf"
    cp "$WIFI_ARTIFACTS/Makefile"  "$DKMS_SRC/Makefile"
fi
chown -R root:root "$DKMS_SRC"

# Pre-install the compiled .ko from the modules tarball (built in-tree with
# CONFIG_RTL8723BS=m). DKMS will recompile for future kernels via firstboot service.
# Do NOT pre-create DKMS state — 'dkms add' on the Pi does this correctly.
mkdir -p "$MNT_ROOT/var/lib/dkms"
KO_STAGING="$MNT_ROOT/usr/lib/modules/$KVER/kernel/drivers/staging/rtl8723bs"
KO_SRC=$(find "$KO_STAGING" -name "r8723bs.ko*" 2>/dev/null | head -1)
KO_DEST_DIR="$MNT_ROOT/usr/lib/modules/$KVER/updates/dkms"
mkdir -p "$KO_DEST_DIR"
if [ -n "$KO_SRC" ]; then
    KO_EXT="${KO_SRC##*.ko}"
    cp "$KO_SRC" "$KO_DEST_DIR/r8723bs.ko${KO_EXT}"
    depmod -b "$MNT_ROOT" -a "$KVER" 2>/dev/null
    echo "[assembler] Pre-installed r8723bs.ko${KO_EXT} → updates/dkms/"
else
    echo "[assembler] WARNING: r8723bs.ko not found in modules — DKMS will build on first boot"
fi

# Ensure r8723bs loads on boot
echo "r8723bs" >> "$MNT_ROOT/etc/modules"
# Remove any blacklisting that might block it
sed -i '/blacklist r8723bs/d' \
    "$MNT_ROOT/etc/modprobe.d/raspi-blacklist.conf" 2>/dev/null || true

# RTL8723BS stability: disable power-save + cap to 20MHz (HT40 is unstable on
# this chip → intermittent drops). Module options + NetworkManager powersave off.
cp "$BINDIR/settings/r8723bs.conf" "$MNT_ROOT/etc/modprobe.d/r8723bs.conf"
mkdir -p "$MNT_ROOT/etc/NetworkManager/conf.d"
cp "$BINDIR/settings/wifi-powersave-off.conf" \
   "$MNT_ROOT/etc/NetworkManager/conf.d/wifi-powersave-off.conf"
echo "[assembler] Installed RTL8723BS stability config (20MHz + powersave off)"

# Stage the DKMS setup script. Registration runs once from the consolidated
# cs-firstboot service (below), which calls this and then self-deletes. The
# postinst hook this installs handles future kernel updates via AUTOINSTALL.
cp "$BINDIR/settings/cs-dkms-setup.sh" \
   "$MNT_ROOT/opt/cs-dkms-setup.sh"
chmod 755 "$MNT_ROOT/opt/cs-dkms-setup.sh"

echo "[assembler] WiFi DKMS setup staged (module: $KVER/updates/dkms/r8723bs.ko)"

# ---- cs_battery virtual-battery DKMS (RetroArch in-game OSD) -------------
# A tiny power_supply kernel module so RetroArch's battery indicator works
# in-game (a cs-hud overlay can't draw over a running emulator on KMS). cs-hud
# feeds it the live % via /sys/module/cs_battery/parameters. Registered at
# first boot alongside r8723bs; AUTOINSTALL rebuilds it on kernel updates.
BATT_NAME="cs-battery"
BATT_VER="0.1.0"
BATT_SRC="$MNT_ROOT/usr/src/${BATT_NAME}-${BATT_VER}"
if [ -d "$BINDIR/battery-driver" ]; then
    mkdir -p "$BATT_SRC"
    cp "$BINDIR/battery-driver/cs_battery.c" "$BATT_SRC/"
    cp "$BINDIR/battery-driver/Makefile"     "$BATT_SRC/"
    cp "$BINDIR/battery-driver/dkms.conf"    "$BATT_SRC/"
    chown -R root:root "$BATT_SRC"
    # Load on boot. On the transient first-boot custom kernel the .ko doesn't
    # exist yet (DKMS builds it for the stock kernel pulled during first boot);
    # the load simply no-ops until then. modules-load.d so a missing module is a
    # warning, not a boot failure.
    mkdir -p "$MNT_ROOT/etc/modules-load.d"
    echo "cs_battery" > "$MNT_ROOT/etc/modules-load.d/cs-battery.conf"
    echo "[assembler] cs_battery DKMS source staged + load-on-boot configured"
else
    echo "[assembler] WARNING: battery-driver/ not found — skipping cs_battery"
fi

# ---- snd-usb-audio: use the STOCK in-kernel module --------------------------
# We deliberately do NOT bake the patched "volume fix" snd-usb-audio.ko. The
# pre-built module had a vermagic/symbol mismatch with the running kernel
# ("snd_usb_audio: disagrees about version of symbol module_layout"), so the
# kernel refused to load it — and because it sat in updates/dkms/ (higher modprobe
# priority) it BLOCKED the working stock module too, killing ALL audio (the
# C-Media USB chip enumerated fine but no sound card appeared).
#
# The stock in-kernel snd-usb-audio drives the chip fine, just without the
# volume-range tweak. Re-introducing the volume fix needs the patch ported to the
# current kernel first (the snapshot also fails to build on 6.18: from_timer) —
# tracked in FUTURE.md. Onboard audio stays off (dtparam=audio=off); USB is the
# only sink.
echo "[assembler] Using stock in-kernel snd-usb-audio (volume-fix module NOT baked — see FUTURE.md)"


# One-time first-boot setup, consolidated into a single self-deleting service.
# Does the things that can only happen on the real Pi with a network (apt can't
# run in the ARM64 chroot — binfmt_misc loops): install samba + helpers, then
# register the WiFi DKMS module. On success it removes its own unit + script so
# NOTHING lingers after the first boot (no service quietly retrying every boot).
# (Partition resize and WiFi-from-network-config stay separate: resize must run
# early before apt has disk space, and WiFi is intentionally re-appliable.)
echo "[assembler] Installing one-time first-boot setup service..."

cat > "$MNT_ROOT/usr/local/bin/cs-firstboot.sh" << 'FBSCRIPT'
#!/bin/bash
# Circuit Sword one-time first-boot setup. Runs natively on the Pi, then deletes
# itself. Bails cleanly (no sentinel) if the network/apt isn't ready, so it
# retries on the next boot until it succeeds exactly once.
SENTINEL=/var/lib/cs-firstboot.done
[ -f "$SENTINEL" ] && exit 0

# Boot (FAT) partition — same place network-config lives, readable from any PC.
BOOTDIR=/boot/firmware
[ -d "$BOOTDIR" ] || BOOTDIR=/boot
WARNFILE="$BOOTDIR/WIFI-SETUP-NEEDED.txt"

# Log everything to the FAT boot partition so it's readable from any PC — even if
# WiFi never comes up. Appended per run; survives the self-delete + reboot.
LOGFILE="$BOOTDIR/cs-firstboot.log"
exec >> "$LOGFILE" 2>&1
echo ""
echo "######## cs-firstboot run: $(date) ########"

echo "[cs-firstboot] Waiting for network..."
NETWORK=0
for i in $(seq 1 15); do
    ping -c1 -W2 8.8.8.8 >/dev/null 2>&1 && NETWORK=1 && break
    sleep 2
done
if [ "$NETWORK" -eq 0 ]; then
    echo "[cs-firstboot] No network — first-boot setup (Samba etc.) NOT done yet."
    echo "[cs-firstboot] Configure WiFi in $BOOTDIR/network-config and reboot."
    # Drop a human-readable note next to network-config so the user understands
    # why nothing installed. Removed automatically once setup succeeds.
    cat > "$WARNFILE" 2>/dev/null << 'WARN'
==============================================================
  Circuit Sword - WiFi / network not available
==============================================================

First-boot setup could NOT reach the internet, so the
runtime packages (Samba network shares, etc.) have NOT been
installed yet.

WiFi is required for this one-time setup.

To fix:
  1. Open 'network-config' in THIS folder.
  2. Fill in your WiFi name (ssid) and password.
  3. Save, put the card back in the device, and reboot.

Setup retries automatically on every boot and this file
disappears by itself once it has succeeded.
==============================================================
WARN
    exit 0
fi

# The Pi has no RTC. If apt runs before NTP corrects the clock, the repo
# signatures fail OpenPGP verification ("not valid yet"). Wait for sync.
echo "[cs-firstboot] Waiting for clock sync..."
for i in $(seq 1 15); do
    [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "yes" ] && break
    sleep 2
done

echo "[cs-firstboot] Installing packages..."
# No terminal here, and the samba package ships its own default smb.conf as a
# conffile — without these flags dpkg would prompt about the conffile clash with
# the smb.conf we baked in. Run non-interactive and ALWAYS keep our existing
# config (confold) so our share definitions are never overwritten.
export DEBIAN_FRONTEND=noninteractive
APT_KEEPCONF='-o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef'
apt-get update -qq

# --- 1. Toolchain first (no kernel pulled) ----------------------------------
# dkms + a compiler. --no-install-recommends keeps it lean; build-essential's
# compiler is a Depends so the toolchain is still complete.
echo "[cs-firstboot] Installing dkms + toolchain..."
apt-get install -y --no-install-recommends $APT_KEEPCONF \
    dkms build-essential bc \
    || echo "[cs-firstboot] WARNING: dkms/toolchain incomplete"

# Cap DKMS build parallelism. The CM3 has only 1GB RAM; the default (-j nproc =
# -j4) OOM-kills cc1. -j2 fits with the zram headroom (-j3+ thrashes; drop to 1
# if a rebuild ever fails with "cc1 Killed").
if [ -f /etc/dkms/framework.conf ] && ! grep -q '^parallel_jobs=' /etc/dkms/framework.conf; then
    echo 'parallel_jobs=2' >> /etc/dkms/framework.conf
    echo "[cs-firstboot] set DKMS parallel_jobs=2"
fi

# --- 2. REGISTER the WiFi DKMS module BEFORE any kernel/headers come in ------
# CRITICAL ORDERING. Installing the kernel headers drags in a matching stock
# kernel (linux-headers co-versions linux-image). When that kernel installs, its
# postinst.d/dkms hook builds every REGISTERED dkms module for it. If rtl8723bs
# isn't registered yet it's skipped → the new kernel boots with NO WiFi driver.
# So register it (dkms add + the compat.h refresh hook) FIRST.
echo "[cs-firstboot] Registering RTL8723BS DKMS module..."
[ -x /opt/cs-dkms-setup.sh ] && /opt/cs-dkms-setup.sh || true

# Register cs_battery too, for the SAME reason: it must be known before the stock
# kernel installs so that kernel's postinst.d/dkms hook builds it → RetroArch's
# in-game battery indicator works on the upgraded kernel.
if command -v dkms >/dev/null 2>&1 && [ -d /usr/src/cs-battery-0.1.0 ]; then
    if ! dkms status cs-battery/0.1.0 2>/dev/null | grep -q '^cs-battery'; then
        echo "[cs-firstboot] Registering cs_battery DKMS module..."
        dkms add cs-battery/0.1.0 || true
    fi
fi

# --- 3. Kernel headers (may pull a stock kernel; dkms now builds r8723bs for it)
# The headers metapackages track the kernel ABI so future upgrades pull matching
# headers. If installing them pulls a stock kernel now, its postinst.d/dkms hook
# builds r8723bs for it (registered above) → WiFi works on the next boot.
echo "[cs-firstboot] Installing kernel headers..."
apt-get install -y --no-install-recommends $APT_KEEPCONF \
    linux-headers-rpi-v8 linux-headers-rpi-2712 \
    || echo "[cs-firstboot] WARNING: headers incomplete"

# (No explicit `dkms autoinstall` here: the kernel package's own postinst.d/dkms
# hook already builds r8723bs for each stock kernel as it installs above. Running
# autoinstall again only tries the running CUSTOM kernel — which has no headers
# package — and logs a harmless but confusing error.)

# --- 3b. Purge the stale base-image kernel(s) whose modules were stripped at
# build time (see /var/lib/cs-stale-kernels). Their packages are still registered
# in dpkg, so every later update-initramfs warns "missing /lib/modules/<ver>".
# Purging the packages cleans the dpkg state. SAFE: never the running kernel (we
# boot the custom kernel from kernel8.img), and a stock kernel was just installed
# above via the headers, so a valid apt-managed kernel exists.
if [ -s /var/lib/cs-stale-kernels ]; then
    PURGE=""
    while read -r kn; do
        [ -n "$kn" ] && [ "$kn" != "$(uname -r)" ] || continue
        dpkg -s "linux-image-$kn"   >/dev/null 2>&1 && PURGE="$PURGE linux-image-$kn"
        dpkg -s "linux-headers-$kn" >/dev/null 2>&1 && PURGE="$PURGE linux-headers-$kn"
    done < /var/lib/cs-stale-kernels
    if [ -n "$PURGE" ]; then
        echo "[cs-firstboot] Purging stale kernel packages:$PURGE"
        apt-get purge -y $APT_KEEPCONF $PURGE \
            || echo "[cs-firstboot] stale-kernel purge incomplete (non-fatal)"
    fi
    rm -f /var/lib/cs-stale-kernels
fi

# --- 4. Optional helpers + Samba --------------------------------------------
# kbd provides openvt, which the cs-hud daemon uses to launch its on-screen menu
# on a fresh VT (so SDL/KMSDRM can become DRM master and render over ES/RetroArch).
apt-get install -y --no-install-recommends $APT_KEEPCONF \
    rfkill kbd python3-serial avrdude libftdi1-2 libhidapi-libusb0 \
    || echo "[cs-firstboot] some optional packages unavailable (continuing)"

# Samba: gate on whether the PACKAGE installed (not apt's exit code — an unrelated
# failing trigger can make apt return non-zero even though samba installed fine).
apt-get install -y --no-install-recommends $APT_KEEPCONF samba || true
if ! dpkg -s samba >/dev/null 2>&1; then
    echo "[cs-firstboot] samba install failed — will retry on next boot."
    exit 0
fi
apt-get clean
rm -rf /var/lib/apt/lists/*
echo -e 'raspberry\nraspberry' | smbpasswd -a -s pi

# --- 5. Report state to the log (for diagnosis) -----------------------------
echo "[cs-firstboot] running kernel: $(uname -r)"
echo "[cs-firstboot] dkms status:"
dkms status || true
echo "[cs-firstboot] r8723bs module file:"
modinfo -F filename r8723bs 2>&1 || true

# --- 6. Done: mark done, self-remove, REBOOT --------------------------------
# Reboot so the device comes up in its FINAL state — e.g. on a freshly-pulled
# stock kernel WITH its DKMS-built WiFi module loaded. The log above stays on the
# boot partition for inspection.
echo "[cs-firstboot] Done — removing first-boot service and rebooting."
rm -f "$WARNFILE"
touch "$SENTINEL"
systemctl disable cs-firstboot.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/multi-user.target.wants/cs-firstboot.service \
      /lib/systemd/system/cs-firstboot.service \
      /opt/cs-dkms-setup.sh
# Do NOT call daemon-reload before reboot: deleting the unit file and
# reloading while the service is still active confuses systemd and causes
# systemctl reboot to fail. The sentinel prevents a re-run after reboot;
# systemd discovers the removed unit on the next startup automatically.
rm -f /usr/local/bin/cs-firstboot.sh
sync
systemctl reboot
sleep infinity
FBSCRIPT
chmod +x "$MNT_ROOT/usr/local/bin/cs-firstboot.sh"

cat > "$MNT_ROOT/lib/systemd/system/cs-firstboot.service" << 'SVC'
[Unit]
Description=Circuit Sword one-time first-boot setup (self-removing)
# WiFi is the gating factor: nothing can be installed until the network is up.
# Order after cs-firstboot-wifi so the connection is configured first, then wait
# for the network AND a correct clock (no RTC → apt rejects repo signatures as
# "not valid yet" before NTP syncs). The in-script ping/NTP loops are the real
# guards; these are ordering hints.
After=network-online.target time-sync.target cs-firstboot-wifi.service
Wants=network-online.target time-sync.target
ConditionPathExists=!/var/lib/cs-firstboot.done

[Service]
Type=oneshot
ExecStart=/usr/local/bin/cs-firstboot.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVC

mkdir -p "$MNT_ROOT/etc/systemd/system/multi-user.target.wants"
ln -sf "/lib/systemd/system/cs-firstboot.service" \
       "$MNT_ROOT/etc/systemd/system/multi-user.target.wants/cs-firstboot.service"
echo "[assembler] One-time first-boot setup service installed."


# ---- 6. Cleanup unnecessary files to reduce image size ------
echo "[assembler] Removing unnecessary files to reduce image size..."

# Old stock kernel modules — we boot our custom kernel only.
# Keep only the custom kernel's modules directory. Record each stripped kernel so
# the first-boot can PURGE its package too: otherwise dpkg keeps a "dangling"
# linux-image whose /lib/modules is gone, and every later update-initramfs (e.g.
# an apt full-upgrade) warns "missing /lib/modules/<ver>" for it. Harmless, but
# ugly on a distributed image — purging the package makes the dpkg state clean.
: > "$MNT_ROOT/var/lib/cs-stale-kernels"
for KDIR in "$MNT_ROOT/usr/lib/modules"/*/; do
    KNAME=$(basename "$KDIR")
    if [ "$KNAME" != "$KVER" ]; then
        echo "[assembler] Removing old kernel modules: $KNAME"
        rm -rf "$KDIR"
        echo "$KNAME" >> "$MNT_ROOT/var/lib/cs-stale-kernels"
    fi
done

# Old stock kernel headers from the base image (for old kernel, useless for us).
for HDIR in "$MNT_ROOT/usr/src"/linux-headers-* "$MNT_ROOT/usr/src"/linux-kbuild-*; do
    [ -e "$HDIR" ] || continue
    echo "[assembler] Removing old kernel headers: $(basename "$HDIR")"
    rm -rf "$HDIR"
done

# KEEP RetroPie-Setup: the EmulationStation "RetroPie" config menus (audio, wifi,
# bluetooth, retropie-setup, ...) call its scripts at runtime. Removing it makes
# those menu items fail and bounce straight back to the menu. Worth the disk space.

# APT cache and lists (save space, re-downloaded on first-boot if needed)
rm -rf "$MNT_ROOT/var/cache/apt/archives/"*.deb
rm -rf "$MNT_ROOT/var/lib/apt/lists/"*

echo "[assembler] Cleanup done."

# ---- 7. Unmount --------------------------------------------
echo "[assembler] Unmounting..."
sync
umount "$MNT_BOOT"
umount "$MNT_ROOT"
losetup -d "$LOOPDEV"
LOOPDEV=""

# ---- 8. Shrink image ---------------------------------------
# Shrink the root filesystem + partition to its minimum size.
# The cs-firstboot-resize.service expands it back to fill the SD card on
# first boot, so shrinking here is safe and makes flashing much faster.
echo "[assembler] Shrinking image..."

LOOPDEV=$(losetup --partscan --find --show "$IMG_DST")
echo "[assembler] Loop device for shrink: $LOOPDEV"

ROOT_PART="${LOOPDEV}p2"
BOOT_PART="${LOOPDEV}p1"

# Must fsck before resize
e2fsck -fy "$ROOT_PART"

# Shrink filesystem to minimum
resize2fs -M "$ROOT_PART"

# Get new filesystem size in 512-byte sectors (resize2fs works in 4k blocks)
FS_BLOCKS=$(tune2fs -l "$ROOT_PART" | grep "Block count:" | awk '{print $3}')
FS_BLOCK_SIZE=$(tune2fs -l "$ROOT_PART" | grep "Block size:" | awk '{print $3}')
FS_BYTES=$(( FS_BLOCKS * FS_BLOCK_SIZE ))
FS_SECTORS=$(( (FS_BYTES + 511) / 512 ))

# Get the start sector of partition 2
PART2_START=$(parted -s "$LOOPDEV" unit s print | awk '/^ *2 /{print $2}' | tr -d 's')

# New end sector (start + fs sectors + 2048 sectors safety margin)
NEW_END=$(( PART2_START + FS_SECTORS + 2048 ))

# Leave 2048 sectors (1 MB) of breathing room after the partition end.
NEW_SIZE=$(( (NEW_END + 2049) * 512 ))

# Resize the partition first (while the image file is still large enough),
# then truncate the file. Truncating before resizing would make the partition
# extend beyond the disk, causing parted to error.
echo "[assembler] Resizing partition 2 to end at sector $NEW_END"
echo "Yes" | parted ---pretend-input-tty "$LOOPDEV" resizepart 2 "${NEW_END}s"

losetup -d "$LOOPDEV"
LOOPDEV=""
truncate --size="$NEW_SIZE" "$IMG_DST"

ORIG_MB=$(du -m "$IMG_DST" | cut -f1)
echo "[assembler] Image shrunk to $(du -h "$IMG_DST" | cut -f1)"

echo ""
echo "=== Assembly complete ==="
echo "Output image: $IMG_DST"
ls -lh "$IMG_DST"
