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

# This file exists in '/opt/retropie/configs/all/autostart.sh'

# Log output for diagnostics
exec >>/home/pi/autostart.log 2>&1
echo "=== autostart.sh $(date) ==="

# Record the display we booted with. Both the DPI overlay and HDMI are ALWAYS
# active in config.txt (the DPI panel must stay driven or it shows stuck garbage),
# and a fresh boot reliably brings ES up on HDMI@1080p when the cable is present
# or DPI@640x480 when not — live-switching ES on KMS is unreliable. So on a real
# cable change the hotplug handler just reboots; it compares the live cable state
# against this recorded boot value to know when (and only when) that's needed.
HDMI=$(cat /sys/class/drm/card0-HDMI-A-1/status 2>/dev/null || echo unknown)
echo "$HDMI" | sudo tee /run/cs-hdmi-boot-state >/dev/null

# Match ES's render resolution to the active display, and on HDMI blank the DPI.
ES_CFG=/home/pi/.emulationstation/es_settings.cfg
set_es_res() {
    local w="$1" h="$2"
    [ -f "$ES_CFG" ] || return 0
    if grep -q 'name="ScreenWidth"' "$ES_CFG"; then
        sed -i -E "s#(name=\"ScreenWidth\" value=\")[0-9]+#\\1${w}#"  "$ES_CFG"
        sed -i -E "s#(name=\"ScreenHeight\" value=\")[0-9]+#\\1${h}#" "$ES_CFG"
    fi
    echo "set ES resolution -> ${w}x${h}"
}
if [ "$HDMI" = "connected" ]; then
    set_es_res 1920 1080
    # The DPI overlay stays active (panel always driven = no stuck artifacts), but
    # ES runs on HDMI so the DPI just mirrors the frozen tty1 console. Clear it +
    # hide the cursor so the handheld panel shows black instead of console text.
    printf '\033[2J\033[3J\033[H\033[?25l' > /dev/tty1 2>/dev/null || true
else
    set_es_res 640 480
fi

# Load config file and action
CONFIGFILE="/boot/firmware/config-cs.txt"
if [ -f $CONFIGFILE ]; then

  source $CONFIGFILE

  if [[ -n "$STARTUPEXEC" ]] ; then
    echo "Starting STARTUPEXEC.."
    $STARTUPEXEC &
  fi

  if [[ "$CLONER" == "ON" ]] ; then
    if [[ $(tvservice -s | grep LCD) ]] ; then
      echo "Starting CLONER.."
      sudo systemctl start dpi-cloner.service
    fi
  fi

  if [[ "$MODE" == "TESTER" && -n "$TESTER" ]] ; then
    echo "Starting TESTER.."
    python $TESTER
  elif [ "$MODE" == "SHELL" ] ; then
    echo "Starting SHELL.."
    exit 0
  else
    echo "Starting EMULATIONSTATION.."
    emulationstation >>/home/pi/es.log 2>&1 #auto
  fi

else

  echo "Starting EMULATIONSTATION.."
  emulationstation >>/home/pi/es.log 2>&1 #auto

fi

# ES exited — drop to a shell for debugging (HDMI changes reboot, so there is no
# re-exec flag to handle here anymore).
echo "EmulationStation exited. Dropping to shell. Type 'exit' to reboot or re-run ES."
exec bash
