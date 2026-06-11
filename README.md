# Circuit Sword Software

Power management, an on-screen HUD/menu, and safe-shutdown software for the
Circuit Sword (Raspberry Pi **Compute Module 3** Game Boy mod kit). This repo
builds a custom SD-card image: **Raspberry Pi OS Trixie Lite 64-bit** + RetroPie +
a custom kernel + WiFi/BT drivers.

---

## Quick start — flashing a pre-built image

1. Flash `rpios-cs-final.img.xz` to an SD card with
   [Raspberry Pi Imager](https://www.raspberrypi.com/software/) or balenaEtcher
   (both read `.xz` directly — no need to unpack).
2. Open the boot partition (visible on any OS) and edit **`network-config`** —
   replace `JOUW_WIFI_NAAM` / `JOUW_WIFI_WACHTWOORD` with your WiFi SSID and
   password.
3. Insert the SD card and power on.
4. **First boot takes a few minutes (needs WiFi)** — automatically:
   - the root partition expands to fill the SD card,
   - runtime packages install via apt,
   - the WiFi (RTL8723BS) and battery (`cs_battery`) kernel modules are registered
     via **DKMS** so they survive kernel updates,
   - the board reboots once into the stock kernel.
5. After that EmulationStation starts automatically. In EmulationStation, press
   the **menu button** for the on-screen HUD (battery / WiFi / volume / brightness).

> `config-cs.txt` on the boot partition controls the boot mode without rebuilding
> the image.

---

## Default login

The image ships with the standard Raspberry Pi OS credentials:

- user **`pi`**, password **`raspberry`** (passwordless `sudo`)
- **SSH is enabled** out of the box
- the Samba shares (roms / configs / splashscreens) also use `pi` / `raspberry`

> The first boot warns you that the default password is unchanged. Log in and run
> `passwd` (and `sudo smbpasswd -a pi`) to set your own before putting the device
> on an untrusted network.

---

## Building the image yourself

### Requirements

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) on an
  **arm64 host** (Apple Silicon) — the image assembler runs as an arm64 container.
- ~15 GB free disk space
- `curl` and `xz` (`brew install curl xz` on macOS)

### First-time build (~1–2 hours)

```bash
./build.sh retropie   # download RPi OS + install RetroPie base (~1h, rarely needed)
./build.sh all        # kernel + WiFi + HUD + Bluetooth → assemble
```

The final image lands at `output/rpios-cs-final.img`.

### Iterative builds

| Changed | Command |
|---------|---------|
| Config / scripts only | `./build.sh software` |
| HUD source (`cs-hud_new/`) | `./build.sh hud && ./build.sh software` |
| Kernel config or branch | `./build.sh kernel && ./build.sh wifi && ./build.sh software` |
| WiFi driver only | `./build.sh wifi && ./build.sh software` |
| Bluetooth binary | `./build.sh bt && ./build.sh software` |

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `KERNEL_BRANCH` | `rpi-6.12.y` | RPi kernel branch to build |
| `KERNEL_NAME` | `kernel8` | Output kernel filename (no `.img`) |

---

## Hardware

- Raspberry Pi **Compute Module 3** (CM3, BCM2837, arm64, 1 GB RAM)
- RTL8723BS — WiFi (SDIO) + Bluetooth (UART)
- DPI display 640×480, rotated 180°
- USB audio (C-Media)
- Controls, battery ADC and LCD backlight via an on-board **Arduino Leonardo**
  (ATmega32u4) over serial (`/dev/ttyACM0`)

---

## What's working

**Everywhere** (handled by the Arduino, independent of what's on screen):

- Hardware shortcuts: **MODE + ↑/↓ = volume**, **MODE + ←/→ = brightness**
- Safe shutdown (power switch + low battery)

**In EmulationStation:**

- **cs-hud on-screen menu** — press the menu button for battery / WiFi toggle /
  volume / brightness (`cs-hud_new/`, SDL2 over KMS/DRM via a VT hand-off).

**In-game** (inside an emulator):

- The **visual cs-hud menu does NOT render** — on the 64-bit KMS stack a HUD
  cannot draw on top of a running emulator (there is no DispmanX overlay layer
  anymore). Only the **hardware Arduino buttons** above work in-game.
- **Battery + clock** are shown in **RetroArch's own menu**, fed by the
  `cs_battery` power-supply module.

**Build / system:**

- Custom 64-bit kernel (Trixie, `rpi-6.12.y`); WiFi (RTL8723BS) and the
  `cs_battery` module rebuild via **DKMS**, surviving an `apt full-upgrade`
- Bluetooth via `rtk_hciattach`; fan PWM control
- EmulationStation pixel theme + instant transitions; rotated boot splash
- First-boot partition resize + package install + one-time self-cleanup

## Known issues / not yet done

- No always-on battery overlay *on top of a running emulator* — the 64-bit KMS
  stack has no DispmanX overlay layer (the same reason
  [jecaro's NixOS port](https://github.com/jecaro/circuix-sword) has no HUD at
  all). In-game info comes from RetroArch's menu instead.
- Deferred ideas (Plymouth boot splash, analog-stick calibration) and a
  code-cleanup audit are tracked in [`FUTURE.md`](FUTURE.md).

---

## Related projects & releases

- [jecaro/circuix-sword](https://github.com/jecaro/circuix-sword) — a NixOS port
  for the same CM3 Circuit Sword hardware
- [Latest 1.4.x releases](https://github.com/weese/Circuit-Sword/releases)
- [Kite's original 1.3.x releases](https://github.com/kiteretro/Circuit-Sword/releases)
