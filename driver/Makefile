# SPDX-License-Identifier: GPL-2.0
#
# Renesas RA9530 wireless power transmitter / stylus charger
#
# Out-of-tree (the usual case while developing):
#     make                       # uses /lib/modules/$(uname -r)/build
#     make KDIR=/path/to/linux   # or an already built kernel tree
#     sudo insmod ra9530-charger.ko
#
# In-tree: copy these files into drivers/power/supply/ and add
#     obj-$(CONFIG_RA9530_CHARGER) += ra9530-charger.o
# to drivers/power/supply/Makefile together with the Kconfig entry.

ifdef CONFIG_RA9530_CHARGER
obj-$(CONFIG_RA9530_CHARGER) += ra9530-charger.o
else
obj-m += ra9530-charger.o
endif
