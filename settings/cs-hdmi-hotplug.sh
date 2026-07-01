#!/bin/bash
# HDMI hotplug handler — on a REAL cable change, reboot so a fresh boot brings ES
# up on the right display. Installed to /usr/local/bin/ and triggered by the
# 99-cs-hdmi.rules udev rule. (Single source of truth: the image builder and
# cs-update both install this file.)

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
