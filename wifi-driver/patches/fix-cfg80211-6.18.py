#!/usr/bin/env python3
"""
Patch os_dep/ioctl_cfg80211.c for cfg80211 API changes in kernel 6.18.
Three ops gained extra link_id/link_mask parameters (MLO support).
"""
import sys

file_path = sys.argv[1]

with open(file_path, 'r') as f:
    content = f.read()

T = '\t'

patches = [
    # set_wiphy_params: gained int link_id before u32 changed
    (
        'static int cfg80211_rtw_set_wiphy_params(struct wiphy *wiphy, u32 changed)',
        '#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 18, 0)\n'
        'static int cfg80211_rtw_set_wiphy_params(struct wiphy *wiphy, int link_id, u32 changed)\n'
        '#else\n'
        'static int cfg80211_rtw_set_wiphy_params(struct wiphy *wiphy, u32 changed)\n'
        '#endif'
    ),
    # set_txpower: gained int link_id before enum nl80211_tx_power_setting
    # Indentation in staging source is 4 tabs + 4 spaces
    (
        f'static int cfg80211_rtw_set_txpower(struct wiphy *wiphy,\n{T*4}    struct wireless_dev *wdev,\n{T*4}    enum nl80211_tx_power_setting type, int mbm)',
        f'#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 18, 0)\n'
        f'static int cfg80211_rtw_set_txpower(struct wiphy *wiphy,\n{T*4}    struct wireless_dev *wdev,\n{T*4}    int link_id,\n{T*4}    enum nl80211_tx_power_setting type, int mbm)\n'
        f'#else\n'
        f'static int cfg80211_rtw_set_txpower(struct wiphy *wiphy,\n{T*4}    struct wireless_dev *wdev,\n{T*4}    enum nl80211_tx_power_setting type, int mbm)\n'
        f'#endif'
    ),
    # get_txpower: gained int link_id + unsigned int link_mask before int *dbm
    # Indentation in staging source is 4 tabs + 4 spaces
    (
        f'static int cfg80211_rtw_get_txpower(struct wiphy *wiphy,\n{T*4}    struct wireless_dev *wdev, int *dbm)',
        f'#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 18, 0)\n'
        f'static int cfg80211_rtw_get_txpower(struct wiphy *wiphy,\n{T*4}    struct wireless_dev *wdev,\n{T*4}    int link_id, unsigned int link_mask, int *dbm)\n'
        f'#else\n'
        f'static int cfg80211_rtw_get_txpower(struct wiphy *wiphy,\n{T*4}    struct wireless_dev *wdev, int *dbm)\n'
        f'#endif'
    ),
]

for old, new in patches:
    if old not in content:
        print(f"WARNING: pattern not found (already patched or source changed):\n  {old[:60]}...")
        continue
    content = content.replace(old, new)
    print(f"Patched: {old[:60].strip()}")

with open(file_path, 'w') as f:
    f.write(content)

print("Done.")
