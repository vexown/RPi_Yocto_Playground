/*
 * hello.c — the first program we ship in our own Yocto recipe.
 *
 * Deliberately tiny, but it proves the whole chain: cross-compiled on the
 * x86 PC by the Yocto toolchain, packaged as an .rpm, installed into the
 * image, executed on the Pi's ARM cortex-a76.
 */
#include <stdio.h>
#include <sys/utsname.h>

int main(void)
{
    struct utsname u;

    printf("Hello from meta-playground!\n");

    /* uname(2) — same data the `uname -a` command shows. Printing the
     * machine field makes the cross-compilation visible: this will say
     * aarch64 even though we built it on an x86_64 PC. */
    if (uname(&u) == 0)
        printf("Running on: %s %s (%s)\n", u.sysname, u.release, u.machine);

    return 0;
}
