#pragma once

// Show the overlay menu.
// This function:
//   1. Sends a pause signal to RetroArch (if running) via its FIFO
//   2. Initialises SDL2 with the KMS/DRM driver (causes VT switch — the
//      current DRM master gracefully loses the display)
//   3. Captures the current framebuffer as background (falls back to dark
//      gradient when not available)
//   4. Renders the interactive HUD menu
//   5. Tears down SDL2 (VT switches back — previous app regains display)
//   6. Sends a resume signal to RetroArch
void menu_show(void);

// Diagnostic: grab the input devices and print every raw evdev KEY/ABS event
// for `seconds`, so we can discover this controller's actual button/axis codes.
// Run via `cs-hud --inputdump` (no VT / SDL needed).
void menu_input_dump(int seconds);

// Show a full-screen warning (red background, two centred lines) for `seconds`,
// then tear down. Uses the same SDL2/KMSDRM path as menu_show() so it draws on
// top of EmulationStation / the console. Used by the low-battery auto-shutdown.
void menu_show_warning(const char *line1, const char *line2, int seconds);
