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

# Restore DPI if a previous HDMI switch was interrupted mid-reboot.
# Only acts when CS CONFIG STATE is REBOOTING_TO_HDMI — safe to skip on first boot.
sudo /usr/bin/python3 /home/pi/Circuit-Sword/settings/reboot_to_hdmi.py --check || true

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
    emulationstation #auto
  fi

else

  echo "Starting EMULATIONSTATION.."
  emulationstation #auto

fi

# cs-hud is not a systemd service (conflicts with ES over DRM device).
# Start it here after ES exits, or it can be re-launched separately.

# If we reach here ES has exited (crashed or intentional quit).
# Drop to an interactive shell so the user can debug instead of letting
# the session end and triggering the auto-login loop again.
echo "EmulationStation exited. Dropping to shell. Type 'exit' to reboot or re-run ES."
exec bash
