//-----------------------------------------------------------------------------
// Headless stub for display_manager
//-----------------------------------------------------------------------------

#include <stdint.h>
#include <stdbool.h>

void display_manager_init() {}
void display_manager_unload() {}
void display_manager_clear() {}
void display_manager_set_refresh_speed(uint8_t speed) {}
void display_manager_process() {}

// Dummy structs en variabelen zodat code compileert
typedef struct {
    // leeg
} IMAGE_T;

typedef struct {
    IMAGE_T image;
} IMAGE_LAYER_T;

IMAGE_LAYER_T battery_layer;
IMAGE_LAYER_T debug_layer;
IMAGE_LAYER_T bg_layer;

// Dummy functies voor compatibiliteit
int draw_battery(int a, int b) { return 0; }
int draw_wifi(int a, int b) { return 0; }
int draw_mute(int a, int b) { return 0; }
int draw_volume(int a, int b) { return 0; }
int draw_brightness(int a, int b) { return 0; }
void draw_debug() {}
void draw_kb() {}
void draw_mode_info() {}
void process_top_bar() {}
void process_full_screen() {}
