#include <SDL2/SDL.h>
#include <SDL2/SDL_ttf.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <linux/fb.h>
#include <linux/input.h>
#include <sys/mman.h>
#include <sys/ioctl.h>

#include "config.h"
#include "hardware.h"
#include "menu.h"

// Debounced menu-button state, maintained by the poll thread in main.c.
// menu_show() reads it to decide when the held button has been released.
extern volatile int g_menu_btn_down;

// ============================================================
// Types
// ============================================================

typedef enum {
    ITEM_WIFI = 0,
    ITEM_VOLUME,
    ITEM_BRIGHTNESS,
    ITEM_COUNT
} menu_item_t;

typedef enum {
    INPUT_NONE,
    INPUT_UP,
    INPUT_DOWN,
    INPUT_LEFT,
    INPUT_RIGHT,
    INPUT_CONFIRM,
    INPUT_CANCEL
} menu_input_t;

typedef struct {
    int    selected;       // currently highlighted item
    bool   wifi;
    int    volume;         // 0-100
    int    brightness;     // 0-100
    int    batt_pct;
    bool   charging;
    int    wifi_signal;
    double cpu_temp;       // degrees C, refreshed every ~2s in the menu loop
    bool   dirty;          // a value changed — needs hw write
    bool   open;
} menu_state_t;

// ============================================================
// Colors
// ============================================================

static const SDL_Color C_OVERLAY    = { 10, 10, 20, 200};
static const SDL_Color C_PANEL      = { 28, 28, 38, 252};
static const SDL_Color C_PANEL_HDR  = { 22, 22, 32, 255};  // header darker than body
static const SDL_Color C_BORDER     = { 60, 60, 90, 180};
static const SDL_Color C_SELECTED   = {  0,110,200, 175};
static const SDL_Color C_ICON_BG    = { 42, 42, 58, 255};  // icon tile background
static const SDL_Color C_TITLE      = {255,255,255, 255};
static const SDL_Color C_TEXT       = {240,240,248, 255};
static const SDL_Color C_SUBTEXT    = {150,150,170, 255};
static const SDL_Color C_BAR_BG     = { 55, 55, 75, 255};
static const SDL_Color C_BAR_VOL    = {  0,185,230, 255};  // cyan
static const SDL_Color C_BAR_BATT   = { 90,210, 80, 255};
static const SDL_Color C_BAR_LOW    = {230, 65, 55, 255};
static const SDL_Color C_WIFI_ON    = { 90,210, 80, 255};
static const SDL_Color C_WIFI_OFF   = {110,110,130, 255};
static const SDL_Color C_SEPARATOR  = { 48, 48, 68, 255};

// ============================================================
// Helpers
// ============================================================

static void set_color(SDL_Renderer *r, SDL_Color c) {
    SDL_SetRenderDrawColor(r, c.r, c.g, c.b, c.a);
}

static void fill_rect(SDL_Renderer *r, SDL_Color c, int x, int y, int w, int h) {
    SDL_SetRenderDrawBlendMode(r, SDL_BLENDMODE_BLEND);
    set_color(r, c);
    SDL_Rect rect = {x, y, w, h};
    SDL_RenderFillRect(r, &rect);
}

// Render UTF-8 text at (x, y) and return the rendered width
static int render_text(SDL_Renderer *r, TTF_Font *font,
                       const char *text, int x, int y, SDL_Color color) {
    if (!font || !text || text[0] == '\0') return 0;
    SDL_Surface *surf = TTF_RenderUTF8_Blended(font, text, color);
    if (!surf) return 0;
    SDL_Texture *tex = SDL_CreateTextureFromSurface(r, surf);
    int text_w = surf->w;
    if (tex) {
        SDL_Rect dst = {x, y, surf->w, surf->h};
        SDL_RenderCopy(r, tex, NULL, &dst);
        SDL_DestroyTexture(tex);
    }
    SDL_FreeSurface(surf);
    return text_w;
}

// Right-align text within a rect
static void render_text_right(SDL_Renderer *r, TTF_Font *font,
                               const char *text, int rx, int y, SDL_Color color) {
    if (!font || !text) return;
    int w = 0, h = 0;
    TTF_SizeUTF8(font, text, &w, &h);
    render_text(r, font, text, rx - w, y, color);
}

// ============================================================
// Font loading
// ============================================================

static TTF_Font *load_font(int size) {
    const char *paths[] = {
        FONT_PATH_1, FONT_PATH_2, FONT_PATH_3, FONT_PATH_4, FONT_PATH_5, NULL
    };
    for (int i = 0; paths[i]; i++) {
        TTF_Font *f = TTF_OpenFont(paths[i], size);
        if (f) return f;
    }
    fprintf(stderr, "[menu] Could not load any font at size %d\n", size);
    return NULL;
}

// ============================================================
// Framebuffer screenshot (background)
// ============================================================

// Try to read /dev/fb0 before SDL2 takes the display.
// Returns a heap-allocated RGBA buffer (caller frees), or NULL on failure.
static uint8_t *capture_framebuffer(int *out_w, int *out_h) {
    int fd = open("/dev/fb0", O_RDONLY);
    if (fd < 0) return NULL;

    struct fb_var_screeninfo vinfo;
    struct fb_fix_screeninfo finfo;

    if (ioctl(fd, FBIOGET_VSCREENINFO, &vinfo) < 0 ||
        ioctl(fd, FBIOGET_FSCREENINFO, &finfo) < 0) {
        close(fd);
        return NULL;
    }

    size_t fb_size = (size_t)finfo.line_length * vinfo.yres;
    uint8_t *fb = mmap(NULL, fb_size, PROT_READ, MAP_SHARED, fd, 0);
    if (fb == MAP_FAILED) { close(fd); return NULL; }

    int w = (int)vinfo.xres;
    int h = (int)vinfo.yres;
    int bpp = (int)vinfo.bits_per_pixel;

    uint8_t *rgba = malloc((size_t)(w * h * 4));
    if (!rgba) { munmap(fb, fb_size); close(fd); return NULL; }

    if (bpp == 32) {
        for (int i = 0; i < w * h; i++) {
            uint32_t px;
            memcpy(&px, fb + i * 4, 4);
            rgba[i*4+0] = (px >> 16) & 0xFF; // R
            rgba[i*4+1] = (px >>  8) & 0xFF; // G
            rgba[i*4+2] = (px >>  0) & 0xFF; // B
            rgba[i*4+3] = 255;
        }
    } else if (bpp == 16) {
        for (int i = 0; i < w * h; i++) {
            uint16_t px;
            memcpy(&px, fb + i * 2, 2);
            rgba[i*4+0] = ((px >> 11) & 0x1F) << 3;
            rgba[i*4+1] = ((px >>  5) & 0x3F) << 2;
            rgba[i*4+2] = ((px >>  0) & 0x1F) << 3;
            rgba[i*4+3] = 255;
        }
    } else {
        free(rgba);
        rgba = NULL;
    }

    munmap(fb, fb_size);
    close(fd);

    if (rgba) { *out_w = w; *out_h = h; }
    return rgba;
}

// ============================================================
// RetroArch FIFO control
// ============================================================

static void retroarch_send(const char *cmd) {
    int fd = open(RETROARCH_FIFO, O_WRONLY | O_NONBLOCK);
    if (fd < 0) return;
    write(fd, cmd, strlen(cmd));
    close(fd);
}

// ============================================================
// Input handling
// ============================================================

// Hold-to-repeat timing (a direction held): wait REPEAT_DELAY_MS before the
// first repeat, then one every REPEAT_RATE_MS.
#define REPEAT_DELAY_MS  400
#define REPEAT_RATE_MS    80

// An input event plus whether it is an auto-repeat (held) rather than a fresh
// press. Discrete actions (WiFi toggle, confirm, cancel) act only on fresh
// presses; the volume/brightness sliders also act on repeats so you can hold to
// scrub.
typedef struct {
    menu_input_t input;
    bool         repeat;
} input_ev_t;

// ---- Grabbed evdev input -------------------------------------------------
// We read the gamepad/keyboard DIRECTLY from /dev/input/event* and EVIOCGRAB
// them, so EmulationStation / the running emulator underneath do NOT also act
// on our presses while the overlay is up. This replaces the earlier attempt to
// SIGSTOP ES — freezing ES blanks the KMS display on this hardware, whereas a
// grab leaves ES running (display intact) while simply withholding its input.
// Closing the fds (on exit, even a crash) auto-releases the grab.
#define MAX_EVDEV 16
static int g_evdev_fd[MAX_EVDEV];
static int g_evdev_n = 0;

// Current held direction (from D-pad buttons, hat, or analog stick) and a
// one-slot queue for the latest discrete action (A/B/Start) press.
static menu_input_t g_dir     = INPUT_NONE;
static menu_input_t g_pending = INPUT_NONE;

static bool dev_has_ev(int fd, int type) {
    unsigned long bits[(EV_MAX / (8 * sizeof(long))) + 1];
    memset(bits, 0, sizeof(bits));
    if (ioctl(fd, EVIOCGBIT(0, sizeof(bits)), bits) < 0) return false;
    return (bits[type / (8 * sizeof(long))] >> (type % (8 * sizeof(long)))) & 1;
}

static void input_open_grab(void) {
    g_evdev_n = 0;
    g_dir = INPUT_NONE;
    g_pending = INPUT_NONE;
    for (int i = 0; i < 32 && g_evdev_n < MAX_EVDEV; i++) {
        char path[64];
        snprintf(path, sizeof(path), "/dev/input/event%d", i);
        int fd = open(path, O_RDONLY | O_NONBLOCK);
        if (fd < 0) continue;
        // Keep devices that emit keys/buttons or absolute axes (gamepad/keyboard).
        if (!dev_has_ev(fd, EV_KEY) && !dev_has_ev(fd, EV_ABS)) {
            close(fd);
            continue;
        }
        ioctl(fd, EVIOCGRAB, (void *)1);   // exclusive — withholds input from ES
        g_evdev_fd[g_evdev_n++] = fd;
    }
    fprintf(stderr, "[menu] grabbed %d input device(s)\n", g_evdev_n);
}

static void input_release(void) {
    for (int i = 0; i < g_evdev_n; i++) {
        ioctl(g_evdev_fd[i], EVIOCGRAB, (void *)0);
        close(g_evdev_fd[i]);
    }
    g_evdev_n = 0;
}

// Diagnostic dump — print raw KEY/ABS events so we can map this controller.
void menu_input_dump(int seconds) {
    input_open_grab();
    // Report each device's name so we know which is the gamepad.
    for (int i = 0; i < g_evdev_n; i++) {
        char name[128] = "?";
        ioctl(g_evdev_fd[i], EVIOCGNAME(sizeof(name)), name);
        printf("dev%d: %s\n", i, name);
    }
    printf("--- press D-pad UP/DOWN/LEFT/RIGHT, then A, B, START (%ds) ---\n",
           seconds);
    fflush(stdout);

    time_t end = time(NULL) + seconds;
    while (time(NULL) < end) {
        for (int i = 0; i < g_evdev_n; i++) {
            struct input_event ev;
            while (read(g_evdev_fd[i], &ev, sizeof(ev)) == (ssize_t)sizeof(ev)) {
                if (ev.type == EV_KEY)
                    printf("dev%d KEY code=%d (0x%03x) value=%d\n",
                           i, ev.code, ev.code, ev.value);
                else if (ev.type == EV_ABS)
                    printf("dev%d ABS code=%d (%s) value=%d\n",
                           i, ev.code,
                           ev.code == ABS_X ? "ABS_X" :
                           ev.code == ABS_Y ? "ABS_Y" :
                           ev.code == ABS_HAT0X ? "ABS_HAT0X" :
                           ev.code == ABS_HAT0Y ? "ABS_HAT0Y" : "ABS_other",
                           ev.value);
                fflush(stdout);
            }
        }
        usleep(5000);
    }
    input_release();
    printf("--- dump done ---\n");
}

// Set/clear the held direction from a button-style (on/off) source.
static void set_dir(menu_input_t d, bool down) {
    if (down)            g_dir = d;
    else if (g_dir == d) g_dir = INPUT_NONE;
}

// Drain all pending evdev events into g_dir / g_pending.
static void drain_events(void) {
    struct input_event ev;
    for (int i = 0; i < g_evdev_n; i++) {
        while (read(g_evdev_fd[i], &ev, sizeof(ev)) == (ssize_t)sizeof(ev)) {
            if (ev.type == EV_KEY) {
                bool down = (ev.value != 0);          // 1 = press, 2 = autorepeat
                switch (ev.code) {
                // D-pad as buttons
                case BTN_DPAD_UP:    set_dir(INPUT_UP,    down); break;
                case BTN_DPAD_DOWN:  set_dir(INPUT_DOWN,  down); break;
                case BTN_DPAD_LEFT:  set_dir(INPUT_LEFT,  down); break;
                case BTN_DPAD_RIGHT: set_dir(INPUT_RIGHT, down); break;
                // Keyboard arrows / WASD (testing + mapped keys)
                case KEY_UP:    case KEY_W: set_dir(INPUT_UP,    down); break;
                case KEY_DOWN:  case KEY_S: set_dir(INPUT_DOWN,  down); break;
                case KEY_LEFT:  case KEY_A: set_dir(INPUT_LEFT,  down); break;
                case KEY_RIGHT: case KEY_D: set_dir(INPUT_RIGHT, down); break;
                // Confirm = A. This controller (Arduino Leonardo) reports A as
                // BTN_TRIGGER (0x120); BTN_SOUTH (0x130) covers standard pads.
                case BTN_TRIGGER:                                // A (Circuit Sword)
                case BTN_SOUTH:                                  // A (standard pad)
                case KEY_ENTER: case KEY_Z: case KEY_SPACE:
                    if (ev.value == 1) g_pending = INPUT_CONFIRM;
                    break;
                // Cancel/close = B or Start. This controller: B=BTN_THUMB (0x121),
                // Start=BTN_TOP2 (0x124). BTN_EAST/BTN_START cover standard pads.
                case BTN_THUMB:                                  // B (Circuit Sword)
                case BTN_TOP2:                                   // Start (Circuit Sword)
                case BTN_EAST:                                   // B (standard pad)
                case BTN_START:                                  // Start (standard pad)
                case KEY_ESC: case KEY_X: case KEY_BACKSPACE:
                    if (ev.value == 1) g_pending = INPUT_CANCEL;
                    break;
                default: break;
                }
            } else if (ev.type == EV_ABS) {
                // ONLY the D-pad hat. We deliberately ignore ABS_X/ABS_Y: on the
                // Circuit Sword's Arduino, ABS_X is a free-floating/unused analog
                // input that streams ~3100-3300 nonstop — treating it as a stick
                // pinned the menu to one direction (volume ran to 100%).
                switch (ev.code) {
                case ABS_HAT0Y:   // D-pad vertical: -1 up, +1 down, 0 centre
                    if      (ev.value < 0) g_dir = INPUT_UP;
                    else if (ev.value > 0) g_dir = INPUT_DOWN;
                    else if (g_dir == INPUT_UP || g_dir == INPUT_DOWN) g_dir = INPUT_NONE;
                    break;
                case ABS_HAT0X:   // D-pad horizontal: -1 left, +1 right, 0 centre
                    if      (ev.value < 0) g_dir = INPUT_LEFT;
                    else if (ev.value > 0) g_dir = INPUT_RIGHT;
                    else if (g_dir == INPUT_LEFT || g_dir == INPUT_RIGHT) g_dir = INPUT_NONE;
                    break;
                default: break;
                }
            }
        }
    }
}

static input_ev_t poll_input(void) {
    drain_events();

    // Discrete action presses take priority and are always fresh edges.
    if (g_pending != INPUT_NONE) {
        menu_input_t p = g_pending;
        g_pending = INPUT_NONE;
        return (input_ev_t){p, false};
    }

    // Directional edge + hold-to-repeat synthesised from the held direction.
    static menu_input_t held       = INPUT_NONE;
    static Uint32       held_since  = 0;
    static Uint32       last_repeat = 0;

    Uint32 now = SDL_GetTicks();

    if (g_dir == INPUT_NONE) {
        held = INPUT_NONE;
        return (input_ev_t){INPUT_NONE, false};
    }
    if (g_dir != held) {                         // rising edge / direction change
        held        = g_dir;
        held_since  = now;
        last_repeat = now;
        return (input_ev_t){g_dir, false};
    }
    if (now - held_since >= REPEAT_DELAY_MS &&
        now - last_repeat >= REPEAT_RATE_MS) {    // sustained hold -> repeat
        last_repeat = now;
        return (input_ev_t){g_dir, true};
    }
    return (input_ev_t){INPUT_NONE, false};
}

// ============================================================
// Rendering
// ============================================================

// Fill a rectangle with rounded corners.
// Uses per-row horizontal line spans for speed (no per-pixel loops).
static void fill_rounded_rect(SDL_Renderer *r, SDL_Rect rect, int rad, SDL_Color c) {
    SDL_SetRenderDrawBlendMode(r, SDL_BLENDMODE_BLEND);
    SDL_SetRenderDrawColor(r, c.r, c.g, c.b, c.a);
    if (rad <= 0 || rect.w < 2*rad || rect.h < 2*rad) {
        SDL_RenderFillRect(r, &rect);
        return;
    }
    // Middle horizontal band
    SDL_Rect mid = {rect.x, rect.y + rad, rect.w, rect.h - 2*rad};
    SDL_RenderFillRect(r, &mid);
    // Top + bottom centre strips (excluding corner quadrants)
    SDL_Rect top = {rect.x + rad, rect.y,              rect.w - 2*rad, rad};
    SDL_Rect bot = {rect.x + rad, rect.y + rect.h - rad, rect.w - 2*rad, rad};
    SDL_RenderFillRect(r, &top);
    SDL_RenderFillRect(r, &bot);
    // Corner quadrants: one horizontal line per row, width from circle geometry
    for (int dy = 0; dy < rad; dy++) {
        int dx = 0;
        while ((dx+1)*(dx+1) + dy*dy <= rad*rad) dx++;
        // top-left
        SDL_RenderDrawLine(r, rect.x+rad-1-dx, rect.y+rad-1-dy, rect.x+rad-1, rect.y+rad-1-dy);
        // top-right
        SDL_RenderDrawLine(r, rect.x+rect.w-rad, rect.y+rad-1-dy, rect.x+rect.w-rad+dx, rect.y+rad-1-dy);
        // bottom-left
        SDL_RenderDrawLine(r, rect.x+rad-1-dx, rect.y+rect.h-rad+dy, rect.x+rad-1, rect.y+rect.h-rad+dy);
        // bottom-right
        SDL_RenderDrawLine(r, rect.x+rect.w-rad, rect.y+rect.h-rad+dy, rect.x+rect.w-rad+dx, rect.y+rect.h-rad+dy);
    }
}

// Draw a battery icon: body outline, terminal bump, fill proportional to pct.
static void draw_battery_icon(SDL_Renderer *r, int x, int y, int w, int h,
                               int pct, bool charging) {
    int term_w = 3, term_h = h / 3;
    int body_w = w - term_w;
    // Terminal
    SDL_SetRenderDrawBlendMode(r, SDL_BLENDMODE_BLEND);
    SDL_SetRenderDrawColor(r, C_TEXT.r, C_TEXT.g, C_TEXT.b, 160);
    SDL_Rect term = {x + body_w, y + (h - term_h)/2, term_w, term_h};
    SDL_RenderFillRect(r, &term);
    // Body outline
    SDL_Rect body = {x, y, body_w, h};
    SDL_SetRenderDrawColor(r, C_TEXT.r, C_TEXT.g, C_TEXT.b, 160);
    SDL_RenderDrawRect(r, &body);
    // Fill
    SDL_Color fc = (pct <= 20) ? C_BAR_LOW : C_BAR_BATT;
    int fw = ((body_w - 2) * pct) / 100;
    if (fw > 0) {
        SDL_SetRenderDrawColor(r, fc.r, fc.g, fc.b, fc.a);
        SDL_Rect fill = {x+1, y+1, fw, h-2};
        SDL_RenderFillRect(r, &fill);
    }
    // Charging: simple lightning bolt as two diagonal lines
    if (charging) {
        int cx = x + body_w/2, my = y + h/2;
        SDL_SetRenderDrawColor(r, 255, 220, 70, 255);
        SDL_RenderDrawLine(r, cx+2, y+1, cx-1, my-1);
        SDL_RenderDrawLine(r, cx-1, my,  cx+1, my);
        SDL_RenderDrawLine(r, cx+1, my,  cx-2, y+h-1);
    }
}

// Draw 4 stacked WiFi-style signal bars.
static void draw_wifi_bars(SDL_Renderer *r, int x, int y, int w, int h,
                            int bars, bool enabled) {
    int bw = w / 6;
    int gap = (w - 4*bw) / 3;
    for (int i = 0; i < 4; i++) {
        int bh = (h * (i+1)) / 4;
        int bx = x + i * (bw + gap);
        int by = y + h - bh;
        SDL_Color c = (!enabled || i >= bars) ? C_WIFI_OFF : C_WIFI_ON;
        fill_rect(r, c, bx, by, bw, bh);
    }
}

// Draw a rounded icon tile with a simple symbol inside.
// icon_type matches the ITEM_* enum values (0=WiFi, 1=Volume, 2=Brightness).
static void draw_icon_tile(SDL_Renderer *r, int x, int y, int size,
                            int icon_type, bool selected) {
    SDL_Rect tile = {x, y, size, size};
    fill_rounded_rect(r, tile, 8, selected ? (SDL_Color){20,70,160,255} : C_ICON_BG);

    int cx = x + size/2, cy = y + size/2;
    int pad = size / 5;

    SDL_SetRenderDrawBlendMode(r, SDL_BLENDMODE_BLEND);
    SDL_SetRenderDrawColor(r, C_TEXT.r, C_TEXT.g, C_TEXT.b, 220);

    if (icon_type == ITEM_WIFI) {
        // 4 signal-strength bars centred in tile
        int bw = 4, gap = 3;
        int total = 4*bw + 3*gap;
        int bx = cx - total/2;
        int base_y = y + size - pad;
        int max_h  = size - 2*pad;
        for (int i = 0; i < 4; i++) {
            int bh = (max_h * (i+1)) / 4;
            fill_rect(r, C_TEXT, bx + i*(bw+gap), base_y - bh, bw, bh);
        }
    } else if (icon_type == ITEM_VOLUME) {
        int bx = x + pad, bw = size/4, bh = size/3, by = cy - bh/2;
        // Speaker rectangle
        fill_rect(r, C_TEXT, bx, by, bw, bh);
        // Cone
        SDL_RenderDrawLine(r, bx+bw, by,       cx+size/8, y+pad);
        SDL_RenderDrawLine(r, bx+bw, by+bh,    cx+size/8, y+size-pad);
        SDL_RenderDrawLine(r, cx+size/8, y+pad, cx+size/8, y+size-pad);
        // Two sound waves
        int wx = cx + size/8 + 4;
        SDL_RenderDrawLine(r, wx, cy-4, wx+4, cy-8);
        SDL_RenderDrawLine(r, wx, cy+4, wx+4, cy+8);
    } else if (icon_type == ITEM_BRIGHTNESS) {
        int cr = size/7;
        // Filled circle (sun core)
        for (int dy = -cr; dy <= cr; dy++)
            for (int dx = -cr; dx <= cr; dx++)
                if (dx*dx + dy*dy <= cr*cr)
                    SDL_RenderDrawPoint(r, cx+dx, cy+dy);
        // 8 rays: 4 cardinal + 4 diagonal
        int rs = cr+3, re = cr+6;
        int d  = (rs*71)/100, de = (re*71)/100;
        SDL_RenderDrawLine(r, cx+rs, cy,   cx+re, cy);
        SDL_RenderDrawLine(r, cx-rs, cy,   cx-re, cy);
        SDL_RenderDrawLine(r, cx,  cy+rs,  cx,   cy+re);
        SDL_RenderDrawLine(r, cx,  cy-rs,  cx,   cy-re);
        SDL_RenderDrawLine(r, cx+d, cy+d,  cx+de, cy+de);
        SDL_RenderDrawLine(r, cx-d, cy+d,  cx-de, cy+de);
        SDL_RenderDrawLine(r, cx+d, cy-d,  cx+de, cy-de);
        SDL_RenderDrawLine(r, cx-d, cy-d,  cx-de, cy-de);
    }
}

// Draw the full menu frame.
static void render_menu(SDL_Renderer *r,
                        TTF_Font *font_title,
                        TTF_Font *font_item,
                        TTF_Font *font_small,
                        const menu_state_t *ms,
                        int sw, int sh) {

    int pw = (int)(sw * MENU_PANEL_W_RATIO);
    int ph = (int)(sh * MENU_PANEL_H_RATIO);
    int px = (sw - pw) / 2;
    int py = (sh - ph) / 2;

    int fh_title = TTF_FontHeight(font_title);
    int fh_item  = TTF_FontHeight(font_item);
    int fh_small = TTF_FontHeight(font_small);

    int hdr_h    = fh_title + 20;           // header row
    int footer_h = fh_small + 14;           // footer row
    int sep_h    = 1;
    int items_h  = ph - hdr_h - footer_h - 4 * sep_h;
    int item_h   = items_h / ITEM_COUNT;

    // --- Overlay ---
    fill_rect(r, C_OVERLAY, 0, 0, sw, sh);

    // --- Panel: 1px border ring then fill ---
    fill_rounded_rect(r, (SDL_Rect){px-1, py-1, pw+2, ph+2}, MENU_CORNER_RADIUS+1, C_BORDER);
    fill_rounded_rect(r, (SDL_Rect){px,   py,   pw,   ph},   MENU_CORNER_RADIUS,   C_PANEL);

    // --- Header ---
    {
        fill_rounded_rect(r, (SDL_Rect){px, py, pw, hdr_h}, MENU_CORNER_RADIUS, C_PANEL_HDR);

        // Title (left)
        render_text(r, font_title, "Circuit Sword",
                    px + MENU_PADDING, py + (hdr_h - fh_title) / 2, C_TITLE);

        int rx = px + pw - MENU_PADDING;  // right cursor

        // Battery icon + percentage
        int bi_w = 26, bi_h = 14;
        char pct_str[12];
        snprintf(pct_str, sizeof(pct_str), ms->charging ? "%d%%+" : "%d%%", ms->batt_pct);
        int tw = 0; TTF_SizeUTF8(font_small, pct_str, &tw, NULL);
        int batt_x = rx - bi_w - 4 - tw;
        int batt_y = py + (hdr_h - bi_h) / 2;
        draw_battery_icon(r, batt_x, batt_y, bi_w, bi_h, ms->batt_pct, ms->charging);
        render_text(r, font_small, pct_str, batt_x + bi_w + 4,
                    py + (hdr_h - fh_small) / 2, C_SUBTEXT);
        rx = batt_x - 12;

        // WiFi bars
        int wi_w = 20, wi_h = 16;
        int bars = 0;
        if (ms->wifi) {
            bars = ms->wifi_signal > 75 ? 4 :
                   ms->wifi_signal > 50 ? 3 :
                   ms->wifi_signal > 25 ? 2 :
                   ms->wifi_signal >  5 ? 1 : 0;
        }
        draw_wifi_bars(r, rx - wi_w, py + (hdr_h - wi_h) / 2, wi_w, wi_h, bars, ms->wifi);
        rx -= wi_w + 12;

        // CPU temperature — color shifts warm as it rises
        char temp_str[12];
        snprintf(temp_str, sizeof(temp_str), "%.0f\xc2\xb0""C", ms->cpu_temp);
        SDL_Color temp_col = ms->cpu_temp >= 75.0 ? C_BAR_LOW :
                             ms->cpu_temp >= 60.0 ? (SDL_Color){230, 130, 40, 255} : C_SUBTEXT;
        int ttw = 0; TTF_SizeUTF8(font_small, temp_str, &ttw, NULL);
        render_text(r, font_small, temp_str, rx - ttw,
                    py + (hdr_h - fh_small) / 2, temp_col);
    }

    // Separator after header
    int yc = py + hdr_h;
    fill_rect(r, C_SEPARATOR, px + MENU_CORNER_RADIUS, yc, pw - 2*MENU_CORNER_RADIUS, sep_h);
    yc += sep_h;

    // --- Items ---
    int icon_size = (item_h > 56) ? 40 : item_h - 16;
    int icon_x    = px + MENU_PADDING;
    int label_x   = icon_x + icon_size + 12;
    int right_x   = px + pw - MENU_PADDING;

    for (int i = 0; i < ITEM_COUNT; i++) {
        int  iy  = yc;
        bool sel = (ms->selected == i);

        // Row selection highlight
        if (sel) {
            fill_rounded_rect(r, (SDL_Rect){px+2, iy, pw-4, item_h}, 8, C_SELECTED);
        }

        // Icon tile (vertically centered)
        int icon_y = iy + (item_h - icon_size) / 2;
        draw_icon_tile(r, icon_x, icon_y, icon_size, i, sel);

        switch (i) {
        case ITEM_WIFI: {
            render_text(r, font_item, "WiFi",
                        label_x, iy + (item_h - fh_item) / 2, C_TEXT);
            // ON/OFF pill badge
            const char *badge_str = ms->wifi ? "ON" : "OFF";
            SDL_Color   badge_bg  = ms->wifi ? C_WIFI_ON : C_WIFI_OFF;
            int bw = 0, bh = 0;
            TTF_SizeUTF8(font_small, badge_str, &bw, &bh);
            bw += 16; bh += 6;
            int bx = right_x - bw;
            int by = iy + (item_h - bh) / 2;
            fill_rounded_rect(r, (SDL_Rect){bx, by, bw, bh}, bh/2, badge_bg);
            render_text(r, font_small, badge_str, bx + 8, by + 3,
                        (SDL_Color){15, 15, 20, 255});
            break;
        }
        case ITEM_VOLUME:
        case ITEM_BRIGHTNESS: {
            const char *label   = (i == ITEM_VOLUME) ? "Volume" : "Brightness";
            int         val     = (i == ITEM_VOLUME)  ? ms->volume : ms->brightness;
            SDL_Color   bar_col = (i == ITEM_VOLUME)
                                    ? C_BAR_VOL
                                    : (SDL_Color){220, 185, 50, 255};

            // Label + percentage in upper portion of row
            int top_y = iy + item_h/4 - fh_item/2;
            render_text(r, font_item, label, label_x, top_y, C_TEXT);
            char ps[8]; snprintf(ps, sizeof(ps), "%d%%", val);
            render_text_right(r, font_small, ps, right_x,
                              iy + item_h/4 - fh_small/2, C_SUBTEXT);

            // Rounded progress bar in lower portion
            int bar_y = iy + (item_h * 3) / 5;
            int bar_h = 10;
            int bar_w = right_x - label_x - 40;
            fill_rounded_rect(r, (SDL_Rect){label_x, bar_y, bar_w, bar_h},
                              bar_h/2, C_BAR_BG);
            int fw = (bar_w * val) / 100;
            if (fw > 0)
                fill_rounded_rect(r, (SDL_Rect){label_x, bar_y, fw, bar_h},
                                  bar_h/2, bar_col);
            break;
        }
        }

        yc += item_h;
        fill_rect(r, C_SEPARATOR, px + MENU_CORNER_RADIUS, yc, pw - 2*MENU_CORNER_RADIUS, sep_h);
        yc += sep_h;
    }

    // --- Footer ---
    {
        int fy = py + ph - footer_h;
        const char *hint = "A  Confirm    B  Close";
        int hw = 0; TTF_SizeUTF8(font_small, hint, &hw, NULL);
        render_text(r, font_small, hint, px + (pw - hw) / 2,
                    fy + (footer_h - fh_small) / 2, C_SUBTEXT);
    }
}

// ============================================================
// Main entry point
// ============================================================

void menu_show(void) {
    // 1. Pause RetroArch if running
    retroarch_send("PAUSE_TOGGLE\n");

    // 2. Try framebuffer capture BEFORE SDL2 takes the display
    int    cap_w = 0, cap_h = 0;
    uint8_t *cap_pixels = capture_framebuffer(&cap_w, &cap_h);

    // 3. SDL2 with KMS/DRM backend
    //    Setting the env var before SDL_Init makes SDL2 use the KMS backend.
    //    SDL2 will open a new VT, causing the current DRM master (RetroArch /
    //    EmulationStation) to lose the display gracefully via the kernel's
    //    VT-switch mechanism.
    setenv("SDL_VIDEODRIVER", "kmsdrm", 1);
    setenv("SDL_RENDER_DRIVER", "opengl", 1);

    // Video only — input comes from grabbed evdev devices, not SDL joystick.
    if (SDL_Init(SDL_INIT_VIDEO) < 0) {
        fprintf(stderr, "[menu] SDL_Init: %s\n", SDL_GetError());
        free(cap_pixels);
        retroarch_send("PAUSE_TOGGLE\n");
        return;
    }

    if (TTF_Init() < 0) {
        fprintf(stderr, "[menu] TTF_Init: %s\n", TTF_GetError());
        SDL_Quit();
        free(cap_pixels);
        retroarch_send("PAUSE_TOGGLE\n");
        return;
    }

    SDL_Window *win = SDL_CreateWindow(
        "cs-hud",
        SDL_WINDOWPOS_UNDEFINED, SDL_WINDOWPOS_UNDEFINED,
        0, 0,
        SDL_WINDOW_FULLSCREEN_DESKTOP | SDL_WINDOW_SHOWN
    );
    if (!win) {
        fprintf(stderr, "[menu] SDL_CreateWindow: %s\n", SDL_GetError());
        TTF_Quit();
        SDL_Quit();
        free(cap_pixels);
        retroarch_send("PAUSE_TOGGLE\n");
        return;
    }

    SDL_Renderer *r = SDL_CreateRenderer(win, -1,
        SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
    if (!r)
        r = SDL_CreateRenderer(win, -1, SDL_RENDERER_SOFTWARE);
    if (!r) {
        fprintf(stderr, "[menu] SDL_CreateRenderer: %s\n", SDL_GetError());
        SDL_DestroyWindow(win);
        TTF_Quit();
        SDL_Quit();
        free(cap_pixels);
        retroarch_send("PAUSE_TOGGLE\n");
        return;
    }

    SDL_SetRenderDrawBlendMode(r, SDL_BLENDMODE_BLEND);

    int sw, sh;
    SDL_GetWindowSize(win, &sw, &sh);

    // Load fonts — size scaled to screen height
    int sz_title = sh / 18;
    int sz_item  = sh / 20;
    int sz_small = sh / 26;
    if (sz_title < 16) sz_title = 16;
    if (sz_item  < 14) sz_item  = 14;
    if (sz_small < 11) sz_small = 11;

    TTF_Font *font_title = load_font(sz_title);
    TTF_Font *font_item  = load_font(sz_item);
    TTF_Font *font_small = load_font(sz_small);

    // Create background texture from captured framebuffer (if available)
    SDL_Texture *bg_tex = NULL;
    if (cap_pixels && cap_w > 0 && cap_h > 0) {
        SDL_Surface *bg_surf = SDL_CreateRGBSurfaceFrom(
            cap_pixels, cap_w, cap_h, 32, cap_w * 4,
            0x00FF0000, 0x0000FF00, 0x000000FF, 0xFF000000
        );
        if (bg_surf) {
            bg_tex = SDL_CreateTextureFromSurface(r, bg_surf);
            SDL_FreeSurface(bg_surf);
        }
    }

    // Grab the input devices: we read them directly and ES/RetroArch get nothing
    // while the overlay is up (see input_open_grab).
    input_open_grab();

    // Initialise menu state from hardware
    cs_hw_state_t hw = hardware_read_state();

    menu_state_t ms = {
        .selected    = ITEM_WIFI,
        .wifi        = hw.wifi_enabled,
        .volume      = hw.volume     >= 0 ? hw.volume     : 50,
        .brightness  = hw.brightness >= 0 ? hw.brightness : 80,
        .batt_pct    = hw.batt_percent,
        .charging    = hw.charging,
        .wifi_signal = hw.wifi_signal,
        .cpu_temp    = hardware_read_cpu_temp(),
        .dirty       = false,
        .open        = true,
    };

    // ---- Menu loop ----
    // The menu runs as its own short-lived process (launched on a fresh VT via
    // openvt so SDL/KMSDRM can become DRM master). It closes on B/Cancel, plus a
    // safety inactivity timeout so a stuck menu can never hold the display.
    Uint32 last_activity = SDL_GetTicks();
    while (ms.open) {
        input_ev_t   ev    = poll_input();
        menu_input_t input = ev.input;

        if (input != INPUT_NONE)
            last_activity = SDL_GetTicks();
        else if (SDL_GetTicks() - last_activity > MENU_INACTIVITY_TIMEOUT_MS)
            ms.open = false;   // safety: auto-close if left untouched

        switch (input) {
        // Navigation is edge-only (don't fly through the 3 items on a hold).
        case INPUT_UP:
            if (!ev.repeat)
                ms.selected = (ms.selected - 1 + ITEM_COUNT) % ITEM_COUNT;
            break;
        case INPUT_DOWN:
            if (!ev.repeat)
                ms.selected = (ms.selected + 1) % ITEM_COUNT;
            break;

        case INPUT_LEFT:
        case INPUT_RIGHT: {
            int delta = (input == INPUT_RIGHT) ? 5 : -5;
            switch (ms.selected) {
            case ITEM_WIFI:
                // A toggle must NOT auto-repeat — one flip per fresh press.
                if (!ev.repeat) {
                    ms.wifi  = !ms.wifi;
                    hardware_set_wifi(ms.wifi);
                    ms.dirty = true;
                }
                break;
            case ITEM_VOLUME:
                ms.volume += delta;             // sliders may repeat (hold to scrub)
                if (ms.volume < 0)   ms.volume = 0;
                if (ms.volume > 100) ms.volume = 100;
                hardware_set_volume(ms.volume);
                ms.dirty = true;
                break;
            case ITEM_BRIGHTNESS:
                ms.brightness += delta;
                if (ms.brightness < 5)   ms.brightness = 5;
                if (ms.brightness > 100) ms.brightness = 100;
                hardware_set_brightness(ms.brightness);
                ms.dirty = true;
                break;
            }
            break;
        }

        case INPUT_CONFIRM:
            // A on WiFi row toggles WiFi — edge-only.
            if (!ev.repeat && ms.selected == ITEM_WIFI) {
                ms.wifi = !ms.wifi;
                hardware_set_wifi(ms.wifi);
                ms.dirty = true;
            }
            break;

        case INPUT_CANCEL:
            if (!ev.repeat)
                ms.open = false;
            break;

        default:
            break;
        }

        // Refresh CPU temp + wifi signal every ~2 seconds
        {
            static Uint32 last_refresh = 0;
            Uint32 now_ms = SDL_GetTicks();
            if (now_ms - last_refresh >= 2000) {
                ms.cpu_temp    = hardware_read_cpu_temp();
                if (ms.wifi)
                    ms.wifi_signal = hardware_get_wifi_signal();
                last_refresh = now_ms;
            }
        }

        // Draw
        SDL_SetRenderDrawColor(r, 0, 0, 0, 255);
        SDL_RenderClear(r);

        // Background: captured frame or solid dark
        if (bg_tex) {
            SDL_RenderCopy(r, bg_tex, NULL, NULL);
        }

        render_menu(r, font_title, font_item, font_small, &ms, sw, sh);
        SDL_RenderPresent(r);

        SDL_Delay(MENU_LOOP_DELAY_MS);
    }

    // ---- Cleanup ----
    input_release();   // ungrab + close input devices (ES regains input)
    if (bg_tex) SDL_DestroyTexture(bg_tex);
    free(cap_pixels);
    if (font_title) TTF_CloseFont(font_title);
    if (font_item)  TTF_CloseFont(font_item);
    if (font_small) TTF_CloseFont(font_small);

    SDL_DestroyRenderer(r);
    SDL_DestroyWindow(win);
    TTF_Quit();
    SDL_Quit();

    // SDL2 KMSDRM has now released the VT — previous app regains the display.
    // Resume RetroArch if it was paused.
    retroarch_send("PAUSE_TOGGLE\n");
}

// ============================================================
// Full-screen warning (low-battery auto-shutdown)
// ============================================================

void menu_show_warning(const char *line1, const char *line2, int seconds) {
    setenv("SDL_VIDEODRIVER", "kmsdrm", 1);
    setenv("SDL_RENDER_DRIVER", "opengl", 1);

    if (SDL_Init(SDL_INIT_VIDEO) < 0) {
        fprintf(stderr, "[warn] SDL_Init: %s\n", SDL_GetError());
        return;
    }
    if (TTF_Init() < 0) {
        fprintf(stderr, "[warn] TTF_Init: %s\n", TTF_GetError());
        SDL_Quit();
        return;
    }

    SDL_Window *win = SDL_CreateWindow(
        "cs-hud-warning",
        SDL_WINDOWPOS_UNDEFINED, SDL_WINDOWPOS_UNDEFINED, 0, 0,
        SDL_WINDOW_FULLSCREEN_DESKTOP | SDL_WINDOW_SHOWN);
    if (!win) { TTF_Quit(); SDL_Quit(); return; }

    SDL_Renderer *r = SDL_CreateRenderer(win, -1, SDL_RENDERER_ACCELERATED);
    if (!r) r = SDL_CreateRenderer(win, -1, SDL_RENDERER_SOFTWARE);
    if (!r) { SDL_DestroyWindow(win); TTF_Quit(); SDL_Quit(); return; }

    SDL_SetRenderDrawBlendMode(r, SDL_BLENDMODE_BLEND);

    int sw, sh;
    SDL_GetWindowSize(win, &sw, &sh);

    int sz_big = sh / 8;  if (sz_big < 22) sz_big = 22;
    int sz_sm  = sh / 16; if (sz_sm  < 14) sz_sm  = 14;
    TTF_Font *fbig = load_font(sz_big);
    TTF_Font *fsm  = load_font(sz_sm);

    const SDL_Color bg    = {130, 20, 20, 255};
    const SDL_Color white = {255, 255, 255, 255};
    const SDL_Color pink  = {255, 225, 225, 255};

    Uint32 end = SDL_GetTicks() + (Uint32)seconds * 1000;
    while ((int)(end - SDL_GetTicks()) > 0) {
        fill_rect(r, bg, 0, 0, sw, sh);
        if (line1 && fbig) {
            int w = 0, h = 0; TTF_SizeUTF8(fbig, line1, &w, &h);
            render_text(r, fbig, line1, (sw - w) / 2, sh / 2 - h - 4, white);
        }
        if (line2 && fsm) {
            int w = 0, h = 0; TTF_SizeUTF8(fsm, line2, &w, &h);
            render_text(r, fsm, line2, (sw - w) / 2, sh / 2 + 4, pink);
        }
        SDL_RenderPresent(r);
        SDL_Delay(50);
    }

    if (fbig) TTF_CloseFont(fbig);
    if (fsm)  TTF_CloseFont(fsm);
    SDL_DestroyRenderer(r);
    SDL_DestroyWindow(win);
    TTF_Quit();
    SDL_Quit();
}
