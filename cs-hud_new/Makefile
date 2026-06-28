TARGET  = cs-hud
CC      = gcc
CFLAGS  = -Wall -Wextra -O2 -std=c11 -D_DEFAULT_SOURCE \
          -I/usr/include/libdrm \
          $(shell sdl2-config --cflags)
LDFLAGS = $(shell sdl2-config --libs) \
          -lSDL2_ttf \
          -lpigpio \
          -lpthread \
          -lm

SRCDIR  = src
SRCS    = $(SRCDIR)/main.c \
          $(SRCDIR)/hardware.c \
          $(SRCDIR)/menu.c
OBJS    = $(SRCS:.c=.o)

.PHONY: all clean install uninstall

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

$(SRCDIR)/%.o: $(SRCDIR)/%.c
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -f $(OBJS) $(TARGET)

install: $(TARGET)
	install -m 755 $(TARGET) /usr/local/bin/$(TARGET)
	install -m 644 cs-hud.service /etc/systemd/system/cs-hud.service
	systemctl daemon-reload
	systemctl enable cs-hud.service
	systemctl start  cs-hud.service
	@echo "cs-hud installed and started."

uninstall:
	systemctl stop    cs-hud.service 2>/dev/null || true
	systemctl disable cs-hud.service 2>/dev/null || true
	rm -f /etc/systemd/system/cs-hud.service
	rm -f /usr/local/bin/$(TARGET)
	systemctl daemon-reload
	@echo "cs-hud removed."
