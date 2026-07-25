# Makefile for hello-sdk — deliberately BORING, that's the lesson.
#
# Notice what is NOT here: no compiler path, no --sysroot, no -march,
# no mention of ARM at all. We only use variables ($(CC), $(CFLAGS),
# $(LDFLAGS)) and pkg-config — and the SDK's environment-setup script
# fills all of them in:
#   CC       -> aarch64-poky-linux-gcc -mcpu=cortex-a76 --sysroot=...
#   PKG_CONFIG_* -> resolve .pc files inside the TARGET sysroot, so
#                   `pkg-config libsystemd` finds OUR image's libsystemd.
#
# The exact same Makefile builds a native x86 binary in a plain shell
# (against your Ubuntu's libsystemd). That's the portability contract
# that lets an app developer ignore Yocto entirely.

hello-sdk: hello-sdk.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $< $(shell pkg-config --cflags --libs libsystemd)

clean:
	rm -f hello-sdk

.PHONY: clean
