// SPDX-License-Identifier: GPL-2.0
/*
 * Make personality(ADDR_NO_RANDOMIZE) fail, to simulate a host that forbids it.
 *
 * arch/um/os-Linux/main.c asks for ADDR_NO_RANDOMIZE and re-execs itself if the
 * request took effect. The goal states that personality() may be blocked on
 * Android, and the address-space layout that now works must not depend on it --
 * so this shim reproduces that host, locally, today, rather than discovering it
 * on a phone after the layout is settled.
 *
 * Build:
 *   clang --target=aarch64-linux-gnu -shared -fPIC -o noaslr_preload.so \
 *         noaslr_preload.c
 * Use:
 *   LD_PRELOAD=./noaslr_preload.so ./linux ...
 */
#define _GNU_SOURCE
#include <errno.h>
#include <unistd.h>

int personality(unsigned long persona);

int personality(unsigned long persona)
{
	(void)persona;
	errno = EPERM;
	return -1;
}

/*
 * Announce that the shim is actually loaded.
 *
 * Without this, a gate configured with LD_PRELOAD passes while testing an
 * ordinary host: a wrong path, a wrong ABI or a library the host refuses to load
 * all fail silently, and the run looks successful. native.sh requires this
 * string when PRELOAD_MARKER is set and refuses to pass without it, so a noaslr
 * gate that did not actually disable ASLR cannot be mistaken for one that did.
 */
__attribute__((constructor))
static void noaslr_preload_announce(void)
{
	static const char msg[] = "noaslr_preload_active\n";
	ssize_t n = write(2, msg, sizeof(msg) - 1);

	(void)n;
}
