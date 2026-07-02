# Continuous Integration

Three GitHub Actions workflows guard this repo. They are **purely additive** —
they do not change `build.sh`, the `docker/` build stages, or `cs-update.sh`
behavior. CI runs entirely off-device; see **the boundary at the bottom** before
trusting a green check.

## Workflows

### `lint.yml` — shell + workflow static analysis
Runs on every push and pull request.

- **shellcheck** on every tracked `*.sh` (discovered via `git ls-files '*.sh'`, so
  new scripts are covered automatically). Correctness-class findings (e.g. SC2086
  quoting) are fixed in the scripts; only *noisy stylistic* codes may be muted via
  `.shellcheckrc` at the repo root.
- **actionlint** on the workflow YAML itself (it also shellchecks the inline
  `run:` blocks).

### `hud-build.yml` — cs-hud compiles
Runs on push/PR that touch `cs-hud_new/**`.

- Builds in a `--platform linux/arm64` **Debian Trixie** container (via
  `docker/setup-qemu-action`) so the compiler/libraries match the target image.
- Dependencies mirror `docker/Dockerfile.hud` (`libsdl2-dev`, `libsdl2-ttf-dev`,
  `libdrm-dev`) **plus pigpio built from source at tag `v79`** — pigpio is not
  packaged in Debian and cs-hud links `-lpigpio`.
- **Warnings policy:** the build must be error-free (Trixie's gcc-14 already
  hard-errors the dangerous C classes). A follow-up step fails on a small curated
  set of high-signal warnings (implicit declaration, pointer/int conversions,
  missing return) and surfaces any other warnings informationally. A blanket
  `-Werror` is intentionally **not** enforced (too aggressive for existing code /
  library-version noise); revisit once the arm64 build is confirmed clean.

> Difference from the repo, noted deliberately: `docker/Dockerfile.hud` builds the
> HUD on `debian:bookworm-slim`; CI uses **Trixie** to match the shipped image's
> userland.

### `dkms-build.yml` — out-of-tree drivers still compile *(the important one)*
Runs weekly (`cron`), on manual dispatch, and on PRs touching `wifi-driver/**` or
`battery-driver/**`.

The recurring failure mode of this project is that **a kernel API change breaks the
out-of-tree drivers**, only discovered when a DKMS rebuild fails on-device after an
`apt full-upgrade`. This workflow cross-compiles both modules against a freshly
prepared Raspberry Pi kernel tree, exercising the **same code path as the on-device
DKMS rebuild**:

- **WiFi** (`wifi-driver/`): the `drivers/staging/rtl8723bs` snapshot is assembled
  exactly like `docker/scripts/build-wifi-module.sh` — staging copy → `Kbuild`,
  wrapper `Makefile`, `compat.h` force-included via `ccflags-y`, and the
  `fix-cfg80211-6.18.py` patch — then built with the wrapper Makefile (the same
  `make KSRC=…` line DKMS uses, and the same `compat.h` the `cs-dkms-refresh` hook
  writes).
- **battery** (`battery-driver/`): a plain out-of-tree module via its Makefile.

**Matrix** (`fail-fast: false`):

| leg | branch | meaning of a failure |
|-----|--------|----------------------|
| `pinned` | `rpi-6.18.y` (build.sh default) | **we broke something** → workflow goes red |
| `newest` | newest `rpi-6.*.y` on raspberrypi/linux | **early warning** a future kernel needs new shims |

The `newest` leg is `continue-on-error` (so a future-kernel break is not a
permanently-red check) and instead **opens or updates a deduped GitHub issue**
titled `compat: modules fail against <branch>` with the compiler-error excerpt.

**Cost control:** shallow clone, the prepared kernel tree is cached per
`branch + HEAD sha`, and only `modules_prepare` runs — never a full kernel build.

## Notes / deviations from the original task brief
Trusting the repo over the brief (and recorded here + in the PR):

- Kernel base config is **`bcm2711_defconfig`**, not `bcm2837_defconfig` — it is the
  official 64-bit config for all RPi arm64 boards (see `build-kernel.sh`).
- The WiFi driver source is **not** a self-contained module dir; it is assembled
  from the kernel staging tree plus `compat.h` + the cfg80211 patch.
- cs-hud needs **pigpio from source**; `Dockerfile.hud` targets bookworm, CI targets
  Trixie (see above).

## What CI does **not** verify

CI has no hardware. Per `CLAUDE.md` ("Testing & verification"), green CI proves the
code **compiles / lints**, not that it **works on the device**. These need on-device
validation and must never be claimed as "working" from a green check:

- DRM/KMS behavior and the VT hand-off the HUD relies on
- the Arduino serial protocol (`/dev/ttyACM0`)
- GPIO polarities (fan active-LOW, power switch GPIO 37 ON=HIGH are *assumptions*)
- SDIO WiFi stability, USB audio, and the whole first-boot flow

A module that **compiles** in `dkms-build` can still fail to **load or function** on
the CM3. Treat green CI as "did not regress the build," nothing more.
