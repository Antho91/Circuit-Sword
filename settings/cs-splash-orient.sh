#!/bin/bash
# Point /etc/splashscreen.list at the image matching the display this boot will
# use (HDMI = upright kr_logo_hdmi.png, DPI handheld = pre-rotated kr_logo.png).
# Runs before asplashscreen reads the list. Unknown/absent HDMI defaults to the
# DPI image so the handheld panel is always right-side-up.
if [ "$(cat /sys/class/drm/card0-HDMI-A-1/status 2>/dev/null)" = "connected" ]; then
    echo /home/pi/Circuit-Sword/settings/kr_logo_hdmi.png > /etc/splashscreen.list
else
    echo /home/pi/Circuit-Sword/settings/kr_logo.png > /etc/splashscreen.list
fi
