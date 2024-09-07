#!/bin/bash

# 
# This file originates from Kite's Circuit Sword control board project.
# Author: Kite (Giles Burgess)
# 
# THIS HEADER MUST REMAIN WITH THIS FILE AT ALL TIMES
#
# This firmware is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This firmware is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this repo. If not, see <http://www.gnu.org/licenses/>.
#
# Check for root privileges
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (sudo)"
  exit 1
fi

# Check for valid number of arguments
if [ $# -lt 1 ] || [ $# -gt 4 ]; then
  echo "Usage: $0 YES [branch] [fat32 root] [ext4 root]"
  exit 1
fi

# Variables
DESTBOOT=${3:-"/boot"}
DEST=${4:-""}
GITHUBPROJECT="Circuit-Sword"
GITHUBURL="https://github.com/Antho91/$GITHUBPROJECT"
PIHOMEDIR="$DEST/home/pi"
BINDIR="$PIHOMEDIR/$GITHUBPROJECT"
USER=1000
POSTINSTALL="/usr/local/sbin/post-install.sh"
BRANCH=${2:-"master"}

# Functions
execute() {
  cmd=$1
  echo "[*] EXECUTE: [$cmd]"
  eval "$cmd"
  ret=$?
  if [ $ret != 0 ]; then
    echo "ERROR: Command exited with [$ret]"
    exit 1
  fi
}

exists() {
  file=$1
  [ -f $file ]
}

# Main logic
echo "INSTALLING..."

# Clone repository if not already present
if ! exists "$BINDIR/LICENSE"; then
  execute "git clone --recursive --depth 1 --branch $BRANCH $GITHUBURL $BINDIR"
fi
execute "chown -R $USER:$USER $BINDIR"

# Copy config.txt and other boot files
if ! exists "$DESTBOOT/config_ORIGINAL.txt"; then
  execute "cp $DESTBOOT/config.txt $DESTBOOT/config_ORIGINAL.txt"
  execute "cp $BINDIR/settings/boot/* $DESTBOOT/"
fi

# Update config.txt if needed
if ! grep -q "CS CONFIG VERSION: 1.0" "$DESTBOOT/config.txt"; then
  execute "cp $BINDIR/settings/boot/config.txt $DESTBOOT/config.txt"
fi

# Copy necessary files to /
execute "cp $BINDIR/settings/asound.conf $DEST/etc/asound.conf"
execute "cp $BINDIR/settings/alsa-base.conf $DEST/etc/modprobe.d/alsa-base.conf"
execute "cp $BINDIR/settings/autostart.sh $DEST/opt/retropie/configs/all/autostart.sh"
execute "chown $USER:$USER $DEST/opt/retropie/configs/all/autostart.sh"
execute "cp $BINDIR/settings/cs_shutdown.sh $DEST/opt/cs_shutdown.sh"

# Fix splashscreen sound
if exists "$DEST/etc/init.d/asplashscreen"; then
  execute "sed -i 's/ *both/ alsa/' $DEST/etc/init.d/asplashscreen"
fi
if exists "$DEST/opt/retropie/supplementary/splashscreen/asplashscreen.sh"; then
  execute "sed -i 's/ *both/ alsa/' $DEST/opt/retropie/supplementary/splashscreen/asplashscreen.sh"
fi

# Fix Mupen64Plus audio
if exists "$DEST/opt/retropie/emulators/mupen64plus/bin/mupen64plus.sh"; then
  execute "sed -i 's/mupen64plus-audio-omx/mupen64plus-audio-sdl/' $DEST/opt/retropie/emulators/mupen64plus/bin/mupen64plus.sh"
fi

# Bluetooth audio fix
cat << EOF >> $DEST/opt/retropie/configs/all/runcommand-onstart.sh
#!/bin/bash
set -e
index=\$(pacmd list-cards | grep bluez_card -B1 | grep index | awk '{print \$2}')
pacmd set-card-profile \$index off
pacmd set-card-profile \$index a2dp_sink
EOF

# Install RTL Bluetooth service
execute "cp $BINDIR/bt-driver/rtl-bluetooth.service $DEST/lib/systemd/system/rtl-bluetooth.service"
execute "cp $BINDIR/bt-driver/rtk_hciattach $DEST/usr/bin/rtk_hciattach"
execute "ln -s $DEST/lib/systemd/system/rtl-bluetooth.service $DEST/etc/systemd/system/rtl-bluetooth.service"
execute "ln -s $DEST/lib/systemd/system/rtl-bluetooth.service $DEST/etc/systemd/system/multi-user.target.wants/rtl-bluetooth.service"

# Install the pixel theme
if ! exists "$DEST/etc/emulationstation/themes/pixel/system/theme.xml"; then
  execute "mkdir -p $DEST/etc/emulationstation/themes"
  execute "rm -rf $DEST/etc/emulationstation/themes/pixel"
  execute "git clone --recursive --depth 1 --branch master https://github.com/krextra/es-theme-pixel.git $DEST/etc/emulationstation/themes/pixel"
  execute "cp -p $BINDIR/settings/es_settings.cfg $DEST/opt/retropie/configs/all/emulationstation/es_settings.cfg"
  execute "sed -i 's/carbon/pixel/' $DEST/opt/retropie/configs/all/emulationstation/es_settings.cfg"
fi

# Enable 30-second autosave
execute "sed -i 's/# autosave_interval =/autosave_interval = \"30\"/' $DEST/opt/retropie/configs/all/retroarch.cfg"

# Remove wait for network on boot
execute "rm -f $DEST/etc/systemd/system/dhcpcd.service.d/wait.conf"

# Remove wifi country disabler
execute "rm -f $DEST/etc/systemd/system/multi-user.target.wants/wifi-country.service"

# Copy wifi firmware
execute "mkdir -p $DEST/lib/firmware/rtlwifi/"
execute "cp $BINDIR/wifi-firmware/rtl* $DEST/lib/firmware/rtlwifi/"

# Install wiringPi
install "settings/deb/wiringpi_3.8_armhf.deb"

# Install services and enable them
SYSTEMD_DIR=${DEST}/lib/systemd/system
execute "cp $BINDIR/cs-hud/cs-hud.service $SYSTEMD_DIR/cs-hud.service"
execute "ln -s $SYSTEMD_DIR/cs-hud.service $DEST/etc/systemd/system/cs-hud.service"
execute "ln -s $SYSTEMD_DIR/cs-hud.service $DEST/etc/systemd/system/multi-user.target.wants/cs-hud.service"
execute "systemctl daemon-reload"

echo "DONE!"
