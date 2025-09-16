#!/bin/bash

# === BASISCONFIG ===
IMG="rpios-bookworm64bit.img"
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
START_FOLDER="$BASE_DIR/build"
IMG_DIR="$START_FOLDER/img"
MNT_BOOT="$IMG_DIR/mnt_boot"
MNT_ROOT="$IMG_DIR/mnt_root"

PIHOMEDIR="$MNT_ROOT/home/pi"
GITHUBPROJECT="Circuit-Sword"
BINDIR="$PIHOMEDIR/$GITHUBPROJECT"
SYSTEMD="$MNT_ROOT/lib/systemd/system"

# === Unmount old mounts ===
echo "🧹 Unmount old mounts..."
dev=$(losetup -j "$IMG" | cut -d: -f1)
[ -n "$dev" ] && sudo kpartx -dv "$dev" 2>/dev/null
sudo umount "$MNT_BOOT" 2>/dev/null
sudo umount "$MNT_ROOT" 2>/dev/null
sudo losetup -D 2>/dev/null

# === 1. Mount image ===
echo "Mounting image..."
loopdev=$(sudo losetup --partscan --find --show "$IMG")
bootp="${loopdev}p1"
rootp="${loopdev}p2"

sudo mount "$rootp" "$MNT_ROOT"
sudo mount "$bootp" "$MNT_BOOT"

echo "✅ Mounted drives:"
echo "  BOOT: $bootp"
echo "  ROOT: $rootp"

# === Handige helperfunctie ===
execute() {
    echo "➡️  $1"
    eval "$1"
}

exists() {
    [ -e "$1" ]
}

# === FIX: ensure /boot/firmware mountpoint exists in rootfs ===
if [ ! -d "$MNT_ROOT/boot/firmware" ]; then
  echo "📂 Creating /boot/firmware mountpoint in rootfs..."
  sudo mkdir -p "$MNT_ROOT/boot/firmware"
fi

# Copy the entire folder Circuit-Sword to $PIHOMEDIR
execute "mkdir -p $PIHOMEDIR"
execute "cp -r ./Circuit-Sword $PIHOMEDIR/"
# Make sure the owner is 'pi' (UID/GID resolved dynamically)
pi_uid=$(stat -c "%u" "$MNT_ROOT/home/pi")
pi_gid=$(stat -c "%g" "$MNT_ROOT/home/pi")
execute "chown -R $pi_uid:$pi_gid $PIHOMEDIR/Circuit-Sword"

# === CONFIG COPY STAP 1 ===
if ! exists "$MNT_BOOT/config_ORIGINAL.txt"; then
  execute "cp $MNT_BOOT/config.txt $MNT_BOOT/config_ORIGINAL.txt"
  execute "cp $BINDIR/settings/boot/* $MNT_BOOT/"
fi

if ! grep -q "CS CONFIG VERSION: 1.0" "$MNT_BOOT/config.txt"; then
  execute "cp $BINDIR/settings/boot/config.txt $MNT_BOOT/config.txt"
fi

# === AUDIO / AUTOSTART / SPLASH ===
execute "cp $BINDIR/settings/asound.conf $MNT_ROOT/etc/asound.conf"
execute "cp $BINDIR/settings/alsa-base.conf $MNT_ROOT/etc/modprobe.d/alsa-base.conf"

if ! exists "$MNT_ROOT/opt/retropie/configs/all/autostart_ORIGINAL.sh"; then
  execute "mv $MNT_ROOT/opt/retropie/configs/all/autostart.sh $MNT_ROOT/opt/retropie/configs/all/autostart_ORIGINAL.sh"
  execute "cp $BINDIR/settings/splashscreen.list $MNT_ROOT/etc/splashscreen.list"
fi
execute "cp $BINDIR/settings/autostart.sh $MNT_ROOT/opt/retropie/configs/all/autostart.sh"
execute "chown $pi_uid:$pi_gid $MNT_ROOT/opt/retropie/configs/all/autostart.sh"

execute "cp $BINDIR/settings/cs_shutdown.sh $MNT_ROOT/opt/cs_shutdown.sh"

if exists "$MNT_ROOT/etc/init.d/asplashscreen"; then
  execute "sed -i 's/ *both/ alsa/' $MNT_ROOT/etc/init.d/asplashscreen"
fi
if exists "$MNT_ROOT/opt/retropie/supplementary/splashscreen/asplashscreen.sh"; then
  execute "sed -i 's/ *both/ alsa/' $MNT_ROOT/opt/retropie/supplementary/splashscreen/asplashscreen.sh"
fi

# === EXTRA CONFIG (AUDIO, BLUETOOTH, THEMES) ===

# 1. Audio config
if ! exists "$PIHOMEDIR/.vice/sdl-vicerc"; then
  execute "mkdir -p $PIHOMEDIR/.vice/"
  execute "echo 'SoundOutput=2' > $PIHOMEDIR/.vice/sdl-vicerc"
  execute "chown -R $pi_uid:$pi_gid $PIHOMEDIR/.vice/"
fi

# 2. Bluetooth audio fix
execute "cat << EOF > $MNT_ROOT/opt/retropie/configs/all/runcommand-onstart.sh
#!/bin/bash
set -e
index=\$(pacmd list-cards | grep bluez_card -B1 | grep index | awk '{print \\$2}')
pacmd set-card-profile \\$index off
pacmd set-card-profile \\$index a2dp_sink
EOF"

# 3. Pixel theme
if ! exists "$MNT_ROOT/etc/emulationstation/themes/pixel/system/theme.xml"; then
  execute "mkdir -p $MNT_ROOT/etc/emulationstation/themes"
  execute "rm -rf $MNT_ROOT/etc/emulationstation/themes/pixel"
  execute "git clone --recursive --depth 1 --branch master https://github.com/krextra/es-theme-pixel.git $MNT_ROOT/etc/emulationstation/themes/pixel"
  execute "cp -p $BINDIR/settings/es_settings.cfg $MNT_ROOT/opt/retropie/configs/all/emulationstation/es_settings.cfg"
  execute "sed -i 's/carbon/pixel/' $MNT_ROOT/opt/retropie/configs/all/emulationstation/es_settings.cfg"
fi

# 4. 'Failed to find mixer elements' fix
if exists "$MNT_ROOT/opt/retropie/configs/all/emulationstation/es_settings.cfg"; then
  execute "echo '<string name=\"AudioDevice\" value=\"PCM\" />' >> $MNT_ROOT/opt/retropie/configs/all/emulationstation/es_settings.cfg"
fi

# 5. Reboot to HDMI
execute "cp $BINDIR/settings/reboot_to_hdmi.sh $PIHOMEDIR/RetroPie/retropiemenu/reboot_to_hdmi.sh"
execute "cp -p $BINDIR/settings/reboot_to_hdmi.png $PIHOMEDIR/RetroPie/retropiemenu/icons/reboot_to_hdmi.png"
if ! grep -q "reboot_to_hdmi" "$MNT_ROOT/opt/retropie/configs/all/emulationstation/gamelists/retropie/gamelist.xml"; then
  execute "sed -i 's|</gameList>|  <game>\\n    <path>./reboot_to_hdmi.sh</path>\\n    <name>One Time Reboot to HDMI</name>\\n    <desc>Enable HDMI and automatically reboot for it to apply. The subsequent power cycle will revert back to the internal screen. It is normal when enabled for the internal screen to remain grey/white.</desc>\\n    <image>/home/pi/RetroPie/retropiemenu/icons/reboot_to_hdmi.png</image>\\n  </game>\\n</gameList>|g' $MNT_ROOT/opt/retropie/configs/all/emulationstation/gamelists/retropie/gamelist.xml"
fi

# 6. Autosave aanzetten
execute "sed -i 's/# autosave_interval =/autosave_interval = \"30\"/' $MNT_ROOT/opt/retropie/configs/all/retroarch.cfg"

# Other tweaks


# 7. Systeemspecifieke tweaks
execute "mkdir -p $MNT_ROOT/lib/firmware/rtl_bt/"
execute "cp $BINDIR/bt-driver/rtlbt_* $MNT_ROOT/lib/firmware/rtl_bt/"
execute "sed -i 's/console=serial0,115200 //' $MNT_BOOT/cmdline.txt || true"

# Disable 'wait for network' on boot
execute "rm -f $MNT_ROOT/etc/systemd/system/dhcpcd.service.d/wait.conf"

# Remove wifi country disabler
execute "rm -f $MNT_ROOT/etc/systemd/system/multi-user.target.wants/wifi-country.service"

# Remove Symlink for NetworkManager-wait-online
execute "rm -f $MNT_ROOT/etc/systemd/system/multi-user.target.wants/NetworkManager-wait-online.service"


execute "sed -i 's/dev-serial1.device/dev-ttyAMA0.device/' $MNT_ROOT/lib/systemd/system/hciuart.service"

# 8. Ramdisk fstab entry
if ! grep -q '/ramdisk' "$MNT_ROOT/etc/fstab"; then
  execute "echo 'tmpfs    /ramdisk    tmpfs    defaults,noatime,nosuid,size=100k    0 0' >> $MNT_ROOT/etc/fstab"
fi

# 9. HUD en BT services
execute "rm -f $MNT_ROOT/etc/systemd/system/cs-hud.service"
execute "rm -f $MNT_ROOT/etc/systemd/system/multi-user.target.wants/cs-hud.service"
execute "rm -f $SYSTEMD/cs-hud.service"
execute "rm -f $SYSTEMD/dpi-cloner.service"

execute "cp $BINDIR/cs-hud/cs-hud.service $SYSTEMD/cs-hud.service"
execute "cp $BINDIR/bt-driver/rtl-bluetooth.service $MNT_ROOT/lib/systemd/system/rtl-bluetooth.service"
execute "cp $BINDIR/bt-driver/rtk_hciattach $MNT_ROOT/usr/bin/rtk_hciattach"
execute "chmod 755 $MNT_ROOT/usr/bin/rtk_hciattach"

# Maak symlinks relatief binnen de image
execute "ln -sf /lib/systemd/system/cs-hud.service $MNT_ROOT/etc/systemd/system/cs-hud.service"
execute "ln -sf /lib/systemd/system/cs-hud.service $MNT_ROOT/etc/systemd/system/multi-user.target.wants/cs-hud.service"
execute "ln -sf /lib/systemd/system/rtl-bluetooth.service $MNT_ROOT/etc/systemd/system/rtl-bluetooth.service"
execute "ln -sf /lib/systemd/system/rtl-bluetooth.service $MNT_ROOT/etc/systemd/system/multi-user.target.wants/rtl-bluetooth.service"

#execute "cp $BINDIR/dpi-cloner/dpi-cloner.service $SYSTEMD/dpi-cloner.service"

# Vervang chroot systemctl enable door handmatige symlink
if [ ! -e "$MNT_ROOT/etc/systemd/system/multi-user.target.wants/resize2fs_once.service" ]; then
  execute "ln -sf /lib/systemd/system/resize2fs_once.service $MNT_ROOT/etc/systemd/system/multi-user.target.wants/resize2fs_once.service"
fi

# === ADD SAMBA USER ===
echo "🔑 Samba user toevoegen..."
execute "chroot $MNT_ROOT bash -c \"echo -e 'raspberry\nraspberry' | smbpasswd -a -s pi\""

# === Unmount mounts ===
echo "🧹 Unmount mounts..."
sudo umount "$MNT_BOOT" 2>/dev/null
sudo umount "$MNT_ROOT" 2>/dev/null
dev=$(losetup -j "$IMG" | cut -d: -f1)
[ -n "$dev" ] && sudo kpartx -dv "$dev" 2>/dev/null
sudo losetup -D 2>/dev/null

echo "✅ Alles geïnstalleerd en geconfigureerd!"
