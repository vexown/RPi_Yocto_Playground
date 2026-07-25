/*
 * hello-sdk.c — compiled OUTSIDE Yocto, using the playground SDK.
 *
 * The point of this file is the twist: it links against libsystemd —
 * a real library from OUR image. A generic cross-compiler from apt
 * (gcc-aarch64-linux-gnu) couldn't do this honestly: it has Ubuntu's
 * headers/libs, not playground 0.1's. The SDK's target sysroot has the
 * exact ones, because it was generated FROM playground-image.
 *
 * Build: source the SDK environment script, then `make` (see Makefile).
 * No bitbake anywhere near this — that's the demonstration.
 */

#include <stdio.h>
#include <systemd/sd-daemon.h>	/* from the SDK's target sysroot */

int main(void)
{
	printf("Hello from the playground SDK — built with no bitbake in sight.\n");

	/* sd_booted(): "is this system running systemd as PID 1?"
	 * (It just checks whether /run/systemd/system/ exists — but the
	 * point is the SYMBOL comes from libsystemd.so at link time.) */
	if (sd_booted() > 0)
		printf("...and libsystemd confirms: PID 1 is systemd. (session 7 says hi)\n");
	else
		printf("...and libsystemd says: not booted with systemd?!\n");

	return 0;
}
