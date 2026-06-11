# Out-of-tree build for the cs_battery virtual battery module.
# Used by DKMS (rebuilds on kernel updates) and for on-device testing:
#   make            # build against the running kernel
#   sudo insmod cs_battery.ko
KSRC ?= /lib/modules/$(shell uname -r)/build

obj-m := cs_battery.o

all:
	$(MAKE) -C $(KSRC) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KSRC) M=$(CURDIR) clean
