OBJS=batt_mon_tester.o \
  batt_mon.o

BIN=batt_mon

CFLAGS+=-Wall -g -O3
LDFLAGS+=-lm -ldl -ffast-math -lwiringPi $(shell libpng-config --ldflags)
INCLUDES+=-Ianalog_read/ -Idisplay/ -Idisplay/common/ -Igpio/ -Igpio_in/ -Ikeyboard/ -Ishift_in/ -Iserialport/ -Ibatt_mon/ -Icommon

all: $(BIN)

%.o: %.c
	@rm -f $@
	$(CC) $(CFLAGS) $(INCLUDES) -g -c $< -o $@ -Wno-deprecated-declarations

$(BIN): $(OBJS)
	$(CC) -o $@ -Wl,--whole-archive $(OBJS) $(LDFLAGS) -pthread -Wl,--no-whole-archive -rdynamic

clean:
	@rm -f $(OBJS)
	@rm -f $(BIN)
