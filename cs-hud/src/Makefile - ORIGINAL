#---------------------------------------------------------------------------#
# Object files
#---------------------------------------------------------------------------#
OBJS = main.o \
       config.o \
       manager.o \
       display_manager.o \
       analog_read/analog_read.o \
       gpio/gpio.o \
       gpio_in/gpio_in.o \
       keyboard/keyboard.o \
       shift_in/shift_in.o \
       serialport/serialport.o \
       state.o \
       batt_mon/batt_mon.o \
       display/icon.o \
       display/display.o \
       display/display_tools.o \
       display/common/backgroundLayer.o \
       display/common/font.o \
       display/common/key.o \
       display/common/imageGraphics.o \
       display/common/imageKey.o \
       display/common/imageLayer.o \
       display/common/image.o \
       display/common/loadpng.o

#---------------------------------------------------------------------------#
# Binary
#---------------------------------------------------------------------------#
BIN = cs-hud

#---------------------------------------------------------------------------#
# Compiler flags
#---------------------------------------------------------------------------#
CFLAGS += -Wall -g -O3 -Icommon $(shell libpng-config --cflags)
INCLUDES += -I/opt/vc/include/ \
            -I/opt/vc/include/interface/vcos/pthreads \
            -I/opt/vc/include/interface/vmcs_host/linux \
            -I/usr/include/libdrm \
            -Ianalog_read/ -Idisplay/ -Idisplay/common/ \
            -Igpio/ -Igpio_in/ -Ikeyboard/ -Ishift_in/ -Iserialport/ -Ibatt_mon/

#---------------------------------------------------------------------------#
# Linker flags
#---------------------------------------------------------------------------#
LDFLAGS += -L/opt/vc/lib/ -lbcm_host -lm -ldl -ldrm -ffast-math -lpigpio -lrt -lpthread $(shell libpng-config --ldflags)

#---------------------------------------------------------------------------#
# Build rules
#---------------------------------------------------------------------------#
all: $(BIN)

# Compile object files
%.o: %.c
	@rm -f $@
	$(CC) $(CFLAGS) $(INCLUDES) -g -c $< -o $@ -Wno-deprecated-declarations

# Link binary
$(BIN): $(OBJS)
	$(CC) -o $@ $(OBJS) $(LDFLAGS) -pthread -rdynamic

# Clean
clean:
	@rm -f $(OBJS)
	@rm -f $(BIN)
