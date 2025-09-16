#include "gpio_in.h"

volatile uint32_t allstate = 0;
int allgpios[16];
uint8_t gpio_count = 0;

//-----------------------------------------------------------------------------
// PRIVATE CALLBACK
void gpio_generic_callback(int gpio, int level, uint32_t tick)
{
    for (uint8_t i = 0; i < gpio_count; i++) {
        if (allgpios[i] == gpio) {
            allstate = (allstate & ~(1 << i)) | ((!gpioRead(gpio)) << i);
            break;
        }
    }
}

//-----------------------------------------------------------------------------
// METHODS

uint32_t gpio_in_state()
{
    return allstate;
}

void gpio_in_init(int *data, uint8_t count)
{
    printf("[i] gpio_in_init..\n");

    gpio_count = count;

    if (gpioInitialise() < 0) {
        fprintf(stderr, "[!] pigpio init failed\n");
        return;
    }

    for (uint8_t i = 0; i < count; i++) {
        allgpios[i] = data[i];

        if (allgpios[i] > -1) {
            printf("[i] gpio_in_init pin %d as callback %d..\n", data[i], i);

            gpioSetMode(allgpios[i], PI_INPUT);
            gpioSetPullUpDown(allgpios[i], PI_PUD_UP);

            gpioSetAlertFunc(allgpios[i], gpio_generic_callback);
        }
    }
}

void gpio_in_unload()
{
    printf("[*] gpio_in_unload..\n");
    gpioTerminate();
}
