#include "gpio.h"

//-----------------------------------------------------------------------------
// PRIVATE VARIABLES

static int pin_power = 24;

//-----------------------------------------------------------------------------
// METHODS

// Perform a read of power switch pin
bool gpio_read_power_pin()
{
    if (pin_power < 0) return false;
    return gpioRead(pin_power) ? true : false;
}

//-----------------------------------------------------------------------------

// Init all GPIOs configured
void gpio_init()
{
    // Initialize pigpio library
    if (gpioInitialise() < 0) {
        fprintf(stderr, "pigpio initialization failed\n");
    }

    // Set power pin as input
    if (pin_power >= 0) {
        gpioSetMode(pin_power, PI_INPUT);
    }
}

//-----------------------------------------------------------------------------

// Set the power switch pin to read
void gpio_set_power_pin(int pin)
{
    pin_power = pin;
    if (pin_power >= 0) {
        gpioSetMode(pin_power, PI_INPUT);
    }
}

//-----------------------------------------------------------------------------
