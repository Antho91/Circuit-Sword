# Out-of-tree wrapper Makefile for RTL8723BS staging tree driver.
# Used by DKMS when rebuilding after a kernel update.
#
# The staging tree Makefile uses obj-$(CONFIG_RTL8723BS) so we must
# pass CONFIG_RTL8723BS=m explicitly when building out-of-tree.

KSRC ?= /lib/modules/$(shell uname -r)/build

all:
	$(MAKE) -C $(KSRC) M=$(shell pwd) CONFIG_RTL8723BS=m modules

clean:
	$(MAKE) -C $(KSRC) M=$(shell pwd) CONFIG_RTL8723BS=m clean
