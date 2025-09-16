//-----------------------------------------------------------------------------
/*
 * DRM/KMS-based display backend (drop-in replacement for DispmanX version)
 *
 * Works on Raspberry Pi OS Bookworm.
 *
 * License: GPLv3
 */
//-----------------------------------------------------------------------------

#include "display.h"

#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <sys/mman.h>
#include <drm/drm_fourcc.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

//-----------------------------------------------------------------------------
// PRIVATE VARIABLES

static int drm_fd = -1;
static drmModeModeInfo mode;
static uint32_t conn_id, crtc_id, fb_id;
static uint32_t width, height;

static void *fb_ptr = NULL;
static size_t fb_size = 0;

IMAGE_LAYER_T base_layer;

uint32_t display_number = 0;

RGBA8_T colour_black;
RGBA8_T colour_white;
RGBA8_T colour_red;
RGBA8_T colour_green;
RGBA8_T colour_blue;
RGBA8_T colour_clear;
RGBA8_T colour_bg_light;
RGBA8_T colour_bg_mlight;
RGBA8_T colour_bg_vlight;

//-----------------------------------------------------------------------------
// HELPERS

static void drm_init()
{
    drmModeRes *res = drmModeGetResources(drm_fd);
    if (!res) { perror("drmModeGetResources"); exit(EXIT_FAILURE); }

    drmModeConnector *conn = NULL;
    for (int i = 0; i < res->count_connectors; i++) {
        conn = drmModeGetConnector(drm_fd, res->connectors[i]);
        if (conn->connection == DRM_MODE_CONNECTED) {
            conn_id = conn->connector_id;
            break;
        }
        drmModeFreeConnector(conn);
        conn = NULL;
    }
    if (!conn) { fprintf(stderr, "No connected connector found\n"); exit(EXIT_FAILURE); }

    mode = conn->modes[0];
    width = mode.hdisplay;
    height = mode.vdisplay;

    drmModeEncoder *enc = drmModeGetEncoder(drm_fd, conn->encoder_id);
    if (!enc) { perror("drmModeGetEncoder"); exit(EXIT_FAILURE); }
    crtc_id = enc->crtc_id;

    drmModeFreeEncoder(enc);
    drmModeFreeConnector(conn);
    drmModeFreeResources(res);

    struct drm_mode_create_dumb creq = {0};
    creq.width = width;
    creq.height = height;
    creq.bpp = 32; // ARGB8888
    if (drmIoctl(drm_fd, DRM_IOCTL_MODE_CREATE_DUMB, &creq) < 0) {
        perror("DRM_IOCTL_MODE_CREATE_DUMB");
        exit(EXIT_FAILURE);
    }

    struct drm_mode_fb_cmd2 cmd = {0};
    cmd.width  = creq.width;
    cmd.height = creq.height;
    cmd.pixel_format = DRM_FORMAT_ARGB8888; // met alpha
    cmd.handles[0] = creq.handle;
    cmd.pitches[0] = creq.pitch;
    cmd.offsets[0] = 0;

    if (drmIoctl(drm_fd, DRM_IOCTL_MODE_ADDFB2, &cmd) < 0) {
        perror("DRM_IOCTL_MODE_ADDFB2");
        exit(EXIT_FAILURE);
    }
    fb_id = cmd.fb_id;
    fb_size = creq.size;

    struct drm_mode_map_dumb mreq = {0};
    mreq.handle = creq.handle;
    if (drmIoctl(drm_fd, DRM_IOCTL_MODE_MAP_DUMB, &mreq)) {
        perror("DRM_IOCTL_MODE_MAP_DUMB");
        exit(EXIT_FAILURE);
    }

    fb_ptr = mmap(0, creq.size, PROT_READ | PROT_WRITE, MAP_SHARED, drm_fd, mreq.offset);
    if (fb_ptr == MAP_FAILED) {
        perror("mmap dumb buffer");
        exit(EXIT_FAILURE);
    }

    // Let EmulationStation render as CRTC "background"
    if (drmModeSetCrtc(drm_fd, crtc_id, 0, 0, 0, &conn_id, 1, &mode)) {
        perror("drmModeSetCrtc");
        // Non-fatal: continue, HUD still usable
    }
}

//-----------------------------------------------------------------------------
// PUBLIC API

int display_get_width()  { return width;  }
int display_get_height() { return height; }
int display_get_start_x(){ return 0; }
int display_get_start_y(){ return 0; }
int display_get_end_x()  { return width; }
int display_get_end_y()  { return height; }

IMAGE_LAYER_T display_create_image_layer(uint32_t canvas_x, uint32_t canvas_y, uint32_t layer)
{
    IMAGE_LAYER_T new_layer;
    initImageLayer(&new_layer, canvas_x, canvas_y, VC_IMAGE_RGBA32);

    // Gebruik de dumb buffer als canvas
    new_layer.image.buffer = fb_ptr;
    new_layer.image.pitch  = width * 4;
    new_layer.image.width  = width;
    new_layer.image.height = height;

    // Vul initieel met transparant ipv zwart
    memset(new_layer.image.buffer, 0x00, fb_size);

    return new_layer;
}

void display_add_image_layer(IMAGE_LAYER_T layer, uint32_t offset_x, uint32_t offset_y)
{
    (void)layer; (void)offset_x; (void)offset_y;
}

void display_update_image_layer(IMAGE_LAYER_T *layer, uint32_t offset_x, uint32_t offset_y)
{
    (void)layer; (void)offset_x; (void)offset_y;
}

void display_remove_image_layer(IMAGE_LAYER_T *layer)
{
    (void)layer;
}

void display_set_display(uint32_t disp)
{
    display_number = disp;
}

void draw_splash(void)
{
    // Optioneel: leeg laten zodat er geen zwarte vulling komt
}

void display_init()
{
    printf("[i] display_init (DRM overlay)..\n");

    drm_fd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
    if (drm_fd < 0) { perror("open /dev/dri/card0"); exit(EXIT_FAILURE); }

    drm_init();

    colour_black      = display_int2rgba(0,   0,   0,   255);
    colour_white      = display_int2rgba(255, 255, 255, 255);
    colour_red        = display_int2rgba(255, 0,   0,   255);
    colour_green      = display_int2rgba(0,   255, 0,   255);
    colour_blue       = display_int2rgba(0,   0,   255, 255);
    colour_clear      = display_int2rgba(0,   0,   0,   0);
    colour_bg_light   = display_int2rgba(30,  30,  30,  198);
    colour_bg_mlight  = display_int2rgba(0,   0,   0,   198);
    colour_bg_vlight  = display_int2rgba(255, 255, 255, 198);

    base_layer = display_create_image_layer(display_get_width(), display_get_height(), 0);
}

void display_init_finalise()
{
    printf("[i] display_init_finalise (DRM overlay)..\n");
    draw_splash();
}

void display_unload()
{
    printf("[i] display_unload (DRM)..\n");
    if (fb_ptr) munmap(fb_ptr, fb_size);
    if (drm_fd >= 0) close(drm_fd);
}
