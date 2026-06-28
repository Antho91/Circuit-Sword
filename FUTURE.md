# Circuit Sword — Future features & deferred ideas

Ideas captured for later. Not blocking the current image.

## HDMI hotplug — DONE (reboot-based); seamless live-switch declined

Shipped: a real cable change triggers a reboot that brings the display up on the
right connector (`cs-hdmi-hotplug.sh` + a DRM `change` udev rule, installed by the
assembler; see the README "HDMI output / docking"). Plug in → reboot to 1080p
HDMI (DPI panel goes dark); unplug → reboot to the 640×480 DPI panel.

**Seamless live-switching will not be pursued.** The running app (ES/RetroArch)
holds the DRM master on a single KMS connector and won't migrate to a
newly-attached one, so a fresh boot — which always brings the display up
correctly — is used instead. Kept here only so the idea isn't re-opened.

---

## HUD menu overlay on KMS (hard problem — deferred)

The cs-hud **button is detected fine** and the daemon runs, but the SDL2 overlay
menu (`menu_show`) fails with `SDL_Init: kmsdrm not available` while
EmulationStation / RetroArch owns the display.

**Why:** with `vc4-kms-v3d`, the app on the active VT (ES on tty1) is the DRM
*master*. cs-hud runs as a headless systemd service with no VT/logind session, so
it cannot become DRM master to draw the overlay. Setting
`SDL_KMSDRM_REQUIRE_DRM_MASTER=0` did **not** help (you still can't mode-set
without master). The original cs-hud overlaid via the legacy graphics stack
(dispmanx/fb), which composited layers — that model is gone under full KMS.

**Options to try later:**
1. **VT switch with a real session:** give cs-hud its own VT/logind seat so it can
   switch VT → become DRM master → render → switch back (the dance `menu_show`
   already attempts but can't complete from a bare service).
2. **Launch cs-hud from the ES session** (autostart.sh on tty1) instead of a
   service — but then it doesn't run during boot/console (auto-shutdown gap).
   Could split: a headless service for power/fan/shutdown + a session-launched
   piece for the menu.
3. **Pivot the menu to RetroArch's own quick-menu** (map a hotkey) for
   volume/brightness, and keep cs-hud headless (battery sysfs, fan, shutdown).
   Brightness is already a hardware/MCU button. This sidesteps KMS entirely and
   is probably the most robust.

## WiFi driver: switch to the maintained rtw88 port (drop our compat.h shims)

**Goal:** stop hand-maintaining kernel-API compatibility for the WiFi driver.

**Today:** we build the in-kernel staging `rtl8723bs` driver (module `r8723bs`,
a FullMAC/cfg80211 driver) into our custom kernel, AND register the same staging
source as a DKMS module (`wifi-driver/`, `dkms.conf`) so it recompiles on kernel
updates. The catch: the staging snapshot needs **our own `compat.h` shims**
(`cs-dkms-refresh` postinst hook) for every new kernel API change (e.g. the
6.15 `del_timer_sync`/`from_timer`/`kzalloc_obj` renames, the 6.18 cfg80211
`link_id` params). Every new kernel risks a build break we have to patch.

**Candidate:** [`MocLG/rtw88-rtl8723bs`](https://github.com/MocLG/rtw88-rtl8723bs)
— a modern **mac80211/rtw88** port of the 8723BS (the Arch "[RFC] porting
RTL8723BS to upstream rtw88" effort). Actively maintained (commits within days),
DKMS-first (`AUTOINSTALL=yes`), mac80211-based so it tracks kernel APIs via the
maintainer instead of us. Module set is the `rtw_*` family (e.g. `rtw_sdio` +
the 8723 core), not `r8723bs`.

**Why it's NOT the fix for "WiFi survived a kernel update":** that failure was an
*environment* gap (no `linux-headers-*` installed → DKMS can't build anything),
already fixed in the first-boot installer. rtw88 would have failed the same way.
This swap is a *separate* win: it makes the rebuild **succeed on future kernels
without our maintenance**.

**What the swap entails (why it's deferred, not trivial):**
- **Blacklist the in-kernel `r8723bs`** (it's built into our custom kernel) or
  stop building it in — otherwise two drivers fight over the SDIO chip.
- **Bake in the firmware** (`make install_fw` → files under `/lib/firmware`).
- **modprobe.d** config to load the rtw88 SDIO module; check the SDIO device-tree
  overlay still applies (the repo ships no Pi-specific config).
- **Stability risk:** it's **RFC/testing** for SDIO — known for "bus timeouts and
  scanning failures." Trial it with the staging driver kept as a fallback before
  committing.

**Alternative considered:** [`MocLG/rtl8723bs-5.2.17`](https://github.com/MocLG/rtl8723bs-5.2.17)
— the classic vendor FullMAC driver. Closer to what we have, but still old-style
and needs its own compat shims, so it offers little over the staging driver.
Mainline rtw88 supports 8723**CS/DS** but **not** 8723**BS** (SDIO), so an
out-of-tree driver stays necessary either way.

## snd-usb-audio volume fix — RESOLVED, patch not needed (dropped)

Verified on hardware: the stock in-kernel `snd-usb-audio` module gives a fully
usable volume range on the C-Media USB chip (ALSA card 1, `PCM` control,
`amixer -c1 sget PCM` → range `0–9472`, ~`-27.75 dB` at 25%). The old 32-bit
build needed a patched module to widen a cramped range; the modern stock driver
does not. The patched module, the `sound` build stage, and the `sound-module/`
source have been **removed** from the repo. Audio just works on stock.

The remaining audio TODO is the cs-hud volume bug below (a software fix, not a
kernel module).

## VERIFY: DKMS build at -j2 survives an apt kernel upgrade

`parallel_jobs=2` is now set (`cs-firstboot.sh`), with zram (~1GB) + 512MB SD
swap for headroom. The memory math supports it (2× cc1 ≈ 750M vs 731M RAM →
light zram swap), but it has **not been validated on hardware** that an actual
`apt full-upgrade` rebuild completes at -j2 (only -j1 was proven). On the next
fresh image: after first boot, run `sudo apt full-upgrade` and confirm the
`rtl8723bs` DKMS rebuild finishes without `cc1 Killed`. If it OOMs, drop
`parallel_jobs` back to `1` in `cs-firstboot.sh` (proven safe). Do NOT go to -j3+
— three compiles exceed physical RAM and thrash on zram.

## On-device update script (refresh components without a reflash)

**Goal:** when we fix something in the repo (a cs-hud build, a systemd unit, a
config, the WiFi/BT driver), let a user update their *working* device in place
instead of re-flashing and redoing first-boot setup.

**Why:** a full reflash wipes ROMs, saves, configs and the user's WiFi
credentials, and repeats the slow first-boot DKMS install. For small fixes that
is overkill — an in-place updater keeps the device as-is and only swaps the
changed pieces.

**Scope to define — what an update may safely touch on a running system:**
- rebuild/replace `cs-hud` (binary + `cs-hud.service`),
- refresh systemd units + scripts under `/usr/local/bin` and `/etc/systemd`,
- update `settings/boot/config.txt` — **carefully**: a user may have switched the
  DPI block (e.g. to the 320 panel), so don't clobber local edits; diff/merge the
  `# CS ...`-managed regions only,
- rebuild the WiFi / `cs_battery` DKMS modules against the running kernel.

**Approach:** the device git-pulls this repo (or downloads a release tarball),
then runs an **idempotent** installer that re-applies only the changed pieces and
restarts the affected services. Needs per-component versioning (a
`CS CONFIG VERSION`-style marker) so it knows what to touch, and must be safe to
re-run. Roll back cleanly if a service fails to come up.

**Note:** the repo still ships Kite's old `update.sh` (root) — it stops the *old*
`cs-osd.service` and re-runs the obsolete manual install flow, so it is broken
against the current image. **Replace** it rather than extend it (it's also listed
as a dead-code cleanup candidate below).

## Cosmetic / minor (deferred)

- **Boot splash is upside down.** The DPI overlay uses `rotate=180`
  (`settings/boot/config.txt`). EmulationStation is KMS-aware and rotates
  correctly, but the early framebuffer splash (`asplashscreen`, fbi on /dev/fb0)
  ignores the KMS plane rotation. Fix options: `fbcon=rotate:2` in `cmdline.txt`
  for the text console, and/or pre-rotate the splash image 180°.

- **Screen flickers when HDMI display dims/blanks.** After an idle timeout the
  display power-management blanks/dims the screen; on wake the picture is fine,
  but the blank→wake transition flickers (a KMS mode re-set on the HDMI output).
  Everything works otherwise. Fix directions to try: disable console blanking
  (`consoleblank=0` in `cmdline.txt`, or `setterm -blank 0 -powerdown 0`),
  disable DPMS on the HDMI connector, and/or tune EmulationStation's screensaver
  so the OS-level blank never triggers.

- **Bluetooth — RESOLVED.** The RTL8723BS BT works: `rtl-bluetooth.service`
  (`rtk_hciattach`) attaches `hci0` and loads firmware, scanning/discovery works.
  The earlier `Failed to set mode (0x03)` was just the adapter coming up rfkill
  **soft-blocked**. Now handled in the build: `rtl-bluetooth.service` runs
  `rfkill unblock bluetooth` (ExecStartPost) and the assembler sets
  `AutoEnable=true` in `/etc/bluetooth/main.conf`, so bluetoothd powers the
  adapter on at boot and a `trust`ed controller reconnects automatically.

- **HUD hardware polarities to confirm on real hardware:** fan (active-LOW
  assumption in `hardware_set_fan`), power switch (GPIO 37 ON=HIGH assumption),
  menu button (serial `CMD_GET_STATUS` bit 0). Flip in code if a board behaves
  inverted.

- **cs-hud volume control doesn't change the USB audio.** Brightness works;
  volume doesn't. `hardware_get_volume`/`hardware_set_volume`
  (`cs-hud_new/src/hardware.c`) call `amixer sget/sset PCM` on the *default* card
  — which is the HDMI card (card 0). The C-Media USB chip is **ALSA card 1** and
  *does* expose a working `PCM` control (confirmed on hardware). Fix: point amixer
  at card 1, e.g. `amixer -c 1 sset PCM N%` / `amixer -c 1 sget PCM`. ~2-line
  change.

- **Laggy transitions in the RetroPie config menu (ES → audio/wifi/bluetooth).**
  Opening one config item, going back, then opening another (e.g. audio → back →
  bluetooth) is slow/glitchy: the *previous* item's screen (e.g. audio) lingers
  visibly before the new one (bluetooth) appears, and the system seems to "hang"
  during that gap (unconfirmed). Unclear whether pressing Cancel/Back actually
  closes the previous window/action or leaves it running. These items launch via
  RetroPie-Setup scripts / runcommand which tear down + re-init the display each
  time (DRM master handover — same class of cost as the HUD-overlay problem).
  Investigate: whether a leftover process/VT is left behind on Cancel, and whether
  the teardown can be sped up. Low priority (functional, just slow).

## Ideas / possible enhancements (not yet started)

Nice-to-haves for the handheld, in rough priority order. (Note: hardware
**volume** and **brightness** buttons already work out of the box via cs-hud —
not listed here.)

- **Controller autoconfig + RetroArch hotkeys.** Auto-map a paired BT / USB
  gamepad in EmulationStation + RetroArch, and wire up hotkeys (save/load state,
  quick-menu, exit) so a controller is plug-and-play. Most valuable for a
  handheld with wireless pads now that BT works.
- **Overclock / performance tuning.** The CM3 (Cortex-A53) is modest; a mild
  `arm_freq` / `over_voltage` bump in `config.txt` helps heavier cores (PSX, N64,
  some arcade). The fan + temperature hysteresis already handle the extra heat —
  tune conservatively and test stability.
- **Custom boot splash / branding.** Replace the default RetroPie splash with a
  Circuit Sword image (also fixes the "splash upside down" cosmetic item if the
  replacement is pre-rotated).
- **USB-stick automount for ROMs.** Auto-mount a plugged-in USB drive and expose
  its ROMs (RetroPie has `usbromservice` for exactly this) — handy for adding
  games without the network/Samba path.
- **Clock at first boot (no RTC).** The first-boot log showed an "Apr 13" date —
  the NTP-sync wait didn't fully land before apt ran (apt still succeeded). Could
  harden the `timedatectl` wait, or set a sane fallback date, so logs/timestamps
  are correct from the start. Cosmetic, low priority.

## Code cleanup / dead-code audit

A lot was iterated on quickly ("vibe coded") — worth a pass to delete what's no
longer used. Do this carefully (the build works); verify each before removing.

**Already cleaned this round:**
- The `sound` stage and `sound-module/` source are **removed** entirely
  (`build.sh` `sound` target, `build_sound`, `docker/Dockerfile.sound`,
  `docker/scripts/build-sound-module.sh`). Audio runs on the stock in-kernel
  `snd-usb-audio` driver; the patched volume-fix is confirmed unnecessary on this
  hardware (usable PCM range on card 1).

**Candidates to audit (verify references, then remove if dead):**
- **`build/` legacy scripts** (`1_build_retropie.sh`, `2_upgrade_patch_kernel_64bit.sh`,
  `3_install_additional_software.sh`) — the old *manual* build flow, fully
  superseded by the Docker pipeline (`docker/scripts/*` + `build.sh`). The
  `build/2` comment about the kernel is already stale/misleading. Likely deletable.
- **`update.sh`** (repo root) — Kite's old on-device updater: it stops
  `cs-osd.service` (the *old* HUD service name) and git-pulls + re-runs the manual
  install flow. Not used by the Docker-image pipeline and almost certainly broken
  against the current image. Verify, then likely remove.
- **The `minimal` build path** — ✅ REMOVED this session (with `custom.toml`,
  `docker/{Dockerfile.minimal,scripts/entrypoint-minimal.sh}`, and the minimal-only
  `settings/cs-firstboot-packages.*` + `settings/cs-dkms-firstboot.service`). The
  old 32-bit DispmanX `cs-hud/` was removed too — `cs-hud_new/` is the active HUD.
- **`settings/reboot_to_hdmi.*`** — check whether the reboot-to-HDMI flow is still
  wired up / wanted, vs. superseded by the (deferred) HDMI-hotplug idea.
- **Orphaned `settings/` files** — grep each `settings/*` against
  `entrypoint-assembler.sh`; anything not copied/referenced is a candidate.
- **Stale comments** — several were updated this session; a sweep for others that
  no longer match the code (e.g. references to removed services) is worth it.

## Analog thumbstick (PSP nub) — controller reference & calibration

Reference data captured while wiring a PSP-style analog nub to the controller.
Useful if anyone re-attempts the stick, and as the definitive input-code map for
the cs-hud menu.

**Controller:** `Arduino LLC Arduino Leonardo` (USB `2341:8036`), at
`/dev/input/event1` / `/dev/input/js0`. The cs-hud menu reads this directly via
grabbed evdev (`EVIOCGRAB`) — see `cs-hud_new/src/menu.c`.

**Button / axis codes (confirmed via `cs-hud --inputdump`):**
- A     = `BTN_TRIGGER` (0x120)   → menu CONFIRM
- B     = `BTN_THUMB`   (0x121)   → menu CANCEL/close
- Start = `BTN_TOP2`    (0x124)   → menu CANCEL/close
- D-pad = `ABS_HAT0X` / `ABS_HAT0Y` (values -1 / 0 / +1) → menu navigation
- (the MODE/menu button is NOT evdev — the board reports it over serial)

**Analog axes (`evtest /dev/input/event1`):** `ABS_X`/`ABS_Y`/`ABS_RX`/`ABS_RY`
report range **-32768..32767**, `Flat` (deadzone) **4095**, `Fuzz` 255.
`ABS_Z`/`ABS_RZ` are -128..127. The cs-hud menu deliberately **ignores** the
analog axes (only the hat/D-pad is used).

**Finding — the nub did not produce real movement.** On this unit `ABS_X` floats
and *jitters around ~3200* (±380) even untouched, and pushing the stick to the
extremes left min ≈ center ≈ max ≈ ~3200 (jscal coefficients `3165, 3311, …`);
`ABS_Y` stayed pinned at 0. So min/center/max are indistinguishable → the stick
is not electrically moving the axis. This is a **wiring/firmware** issue (a
floating ADC pin), not software — calibration can't fix a stick that doesn't
move. Re-check the nub's solder/wiring to the Arduino analog pins, and whether
the firmware maps those pins.

**Calibrating (only meaningful once the stick actually swings to ±~20000):**
```
sudo apt install -y joystick evtest      # jstest/jscal/jscal-store + evtest
sudo evtest /dev/input/event1            # inspect raw values + Min/Max/Flat
jscal -c /dev/input/js0                  # interactive: min/center/max per axis
sudo jscal-store /dev/input/js0          # persist -> /var/lib/joystick/joystick.state
```
Persists across boots via `jscal-restore` (udev rule from the `joystick`
package). **TODO if the stick is ever made to work:** verify that udev
rule/`jscal-restore` is present on our image (else calibration won't auto-apply),
consider adding `joystick`+`evtest` to the first-boot package list, and add stick
navigation to the cs-hud menu using `EVIOCGABS` (centre = (min+max)/2, deadzone =
`Flat`) so it doesn't jitter.

## Plymouth boot splash (KMS) — tested, deferred

A nicer, KMS-native boot splash than the RetroPie `fbi`/asplashscreen one. We
got it **working on this hardware** but deferred it — see the trade-offs below.

**What worked (verified on 6.18.33 stock kernel, Trixie 64-bit):**
- Plymouth renders on our KMS DPI setup, ES comes up afterwards (no black
  screen — the DRM-master handoff Plymouth→ES works here), and it renders the
  **right way up automatically** (KMS respects the panel `rotate=180`, unlike
  `fbi` which needs a pre-rotated image).

**Why it's deferred (real costs on a keyboard-less handheld):**
- **Boot text is hidden.** With `quiet splash` you can't see a boot hang. To see
  it you'd press **ESC** (needs a keyboard — the gamepad has none), SSH in, or
  pull the SD card and remove `quiet splash` from `cmdline.txt`. Bad for a device
  still under development.
- **The autologin line still flashes.** Plymouth quits at `multi-user.target`,
  and the getty autologin draws its line before ES starts — so it does **not**
  fully solve the login flash. A seamless Plymouth→ES handoff (hold Plymouth
  until ES) is fiddly and brittle.

So Plymouth buys a prettier splash but doesn't fix the login flash AND makes
hang-debugging harder. Revisit only if the look matters more than debuggability.

**Setup (exact steps that worked):**
```bash
sudo apt install -y plymouth plymouth-themes        # pix-plym-splash optional (Pi desktop theme)
# cmdline.txt (single line!): remove plymouth.enable=0, add the splash opts
sudo sed -i 's/ *plymouth.enable=0//' /boot/firmware/cmdline.txt
sudo sed -i 's/$/ quiet splash plymouth.ignore-serial-consoles/' /boot/firmware/cmdline.txt
# config.txt must load the initramfs (ours already has it):
grep -q auto_initramfs=1 /boot/firmware/config.txt || echo 'auto_initramfs=1' | sudo tee -a /boot/firmware/config.txt
# theme — the -R flag rebuilds the initramfs (theme is baked INTO the initramfs!):
plymouth-set-default-theme --list
sudo plymouth-set-default-theme -R spinner          # or another
# stop the fbi splash so the two don't fight:
sudo systemctl disable asplashscreen.service
sudo reboot
```

**Gotchas:**
- **Theme lives in the initramfs** → after any theme change run
  `plymouth-set-default-theme -R <name>` (or `update-initramfs -u`), else it
  won't take.
- Installing plymouth runs `update-initramfs` for ALL kernels; the stale
  `6.12.47+rpt-rpi-{v8,2712}` packages (no `/lib/modules`) emit harmless
  `depmod: could not open directory` warnings. The RUNNING kernel's initramfs
  builds fine. (Optional: purge the stale linux-image-6.12.47 packages to silence
  them.)
- A custom **Circuit Sword theme** = a Plymouth "image"/"script" theme in
  `/usr/share/plymouth/themes/` showing `kr_logo.png` centred. Themes:
  https://github.com/HerbFargus/plymouth-themes · scripting: http://brej.org/blog/?p=158

**To bake it (if ever revisited):** assembler installs plymouth + theme, patches
cmdline (drop `plymouth.enable=0`, add `quiet splash plymouth.ignore-serial-consoles`),
disables `asplashscreen.service`, and ships a custom theme dir. `auto_initramfs=1`
is already in our config.txt.

**Revert (back to the fbi kr_logo splash):**
```bash
sudo sed -i 's/ quiet splash plymouth.ignore-serial-consoles//' /boot/firmware/cmdline.txt
sudo systemctl enable asplashscreen.service
sudo apt purge -y plymouth plymouth-themes plymouth-label pix-plym-splash
sudo update-initramfs -u && sudo reboot
```
