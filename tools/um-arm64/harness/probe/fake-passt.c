// SPDX-License-Identifier: GPL-2.0
/*
 * A stand-in for passt, so that umnet can be tested without building passt.
 *
 * umnet execs its passt with a fixed argument list (-f -F <fd> -t none, plus the
 * whole network configuration) and then pumps frames between it and UML's vector
 * `fd` transport. The bug this exists to catch is not in the frames: umnet could
 * not notice the *kernel* exiting, because the UML end of its socketpair is
 * SOCK_DGRAM and closing the peer of a datagram socketpair produces no POLLHUP
 * and no EOF. The pump then sat in poll() forever with the kernel unreaped as a
 * zombie, and everything waiting on umnet waited with it.
 *
 * Reproducing that needs a "passt" that starts, accepts that argument list and
 * then stays alive doing nothing at all. Anything that speaks the protocol would
 * exercise a different exit path, and anything that rejects the arguments would
 * exit before the interesting state is reached. Hence: accept, sleep, die on
 * SIGTERM like anything else.
 */
#include <unistd.h>

int main(void)
{
	for (;;)
		sleep(3600);

	return 0;
}
