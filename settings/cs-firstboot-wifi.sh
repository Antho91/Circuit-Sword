#!/bin/bash
# Configure WiFi from /boot/firmware/network-config using NetworkManager.
#
# This replaces cloud-init's (unreliable) network rendering. It runs on every
# boot and is idempotent, so editing network-config on the FAT boot partition
# and rebooting re-applies the settings — the WiFi stays user-editable from any
# PC without re-flashing.
NETCFG=/boot/firmware/network-config

log() { echo "[cs-wifi] $*"; logger -t cs-wifi "$*" 2>/dev/null || true; }

[ -f "$NETCFG" ] || { log "no network-config — skipping"; exit 0; }

# Parse SSID (first quoted string under access-points:) and password.
SSID=$(grep -A3 'access-points:' "$NETCFG" | grep -oE '"[^"]+"' | head -1 | tr -d '"')
PSK=$(grep 'password:' "$NETCFG" | head -1 | sed -E 's/.*password:[[:space:]]*//' | tr -d '"')

if [ -z "$SSID" ] || [ "$SSID" = "YOUR_WIFI_NAME" ]; then
    log "no real SSID set in network-config — skipping"
    exit 0
fi

# Fast path: if network-config is unchanged since we last applied it AND the
# cs-wifi connection still exists, there's nothing to do — NetworkManager
# autoconnects it on its own. This skips the ~4s wlan0 wait + connection rebuild
# on every boot. (nmcli connection show does not wait for the radio/device.)
STAMP=/var/lib/cs-wifi.applied
CUR_HASH=$(sha256sum "$NETCFG" 2>/dev/null | cut -d' ' -f1)
if [ -n "$CUR_HASH" ] && [ "$CUR_HASH" = "$(cat "$STAMP" 2>/dev/null)" ] && \
   nmcli -t -f NAME connection show 2>/dev/null | grep -qx 'cs-wifi'; then
    log "network-config unchanged and cs-wifi exists — skipping"
    exit 0
fi

# wlan0 comes up rfkill-soft-blocked ('unavailable' in nmcli) until the radio is
# explicitly enabled. nmcli does the rfkill unblock for us.
nmcli radio wifi on 2>/dev/null || true

# Wait for NetworkManager to see wlan0.
for _ in $(seq 1 15); do
    nmcli -t -f DEVICE device 2>/dev/null | grep -q '^wlan0$' && break
    sleep 1
done

# Re-create the connection from the current network-config (idempotent).
nmcli connection delete cs-wifi >/dev/null 2>&1 || true
if nmcli connection add type wifi con-name cs-wifi ifname wlan0 ssid "$SSID" \
        wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$PSK" \
        connection.autoconnect yes >/dev/null 2>&1; then
    nmcli connection up cs-wifi >/dev/null 2>&1 || true
    echo "$CUR_HASH" > "$STAMP" 2>/dev/null || true   # remember what we applied
    log "configured WiFi for SSID '$SSID'"
else
    log "ERROR: failed to add WiFi connection for '$SSID'"
fi
exit 0
