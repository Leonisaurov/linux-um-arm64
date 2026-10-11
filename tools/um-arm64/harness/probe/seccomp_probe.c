// SPDX-License-Identifier: GPL-2.0
/*
 * Which syscalls does this process's seccomp filter kill?
 *
 * Written because a seccomp death leaves nothing behind to read: passt exited
 * with signal 31 (SIGSYS) between two lines of its own output, and there is no
 * errno, no message and no strace on an Android untrusted_app to ask. The answer
 * turned out to be setgroups(), setgid() and setuid(), which Android's app
 * policy kills rather than failing -- but finding that by reading passt's source
 * was not working, because the call that would tell you the syscall is
 * unavailable is the call that kills the process.
 *
 * So: one syscall per *forked child*, so a death does not end the enumeration,
 * and the parent reports which child died of what. Build it for bionic and run
 * it on the device:
 *
 *   $NDK/toolchains/llvm/prebuilt/linux-aarch64/bin/clang \
 *       --target=aarch64-linux-android30 -O1 -static \
 *       -Wl,-z,max-page-size=16384 -o seccomp_probe probe/seccomp_probe.c
 *   ./seccomp_probe
 *
 * The list below is the set of uid/gid/namespace/capability syscalls a program
 * that drops privileges makes at start-up, which is where this class of failure
 * lands. Add to it as needed; the shape is the point, not the list.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <errno.h>
#include <string.h>
#include <unistd.h>
#include <grp.h>
#include <sched.h>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <sys/syscall.h>
#include <linux/capability.h>

#define SIGSYS_NR 31

static void try(const char *name, long (*fn)(void))
{
	pid_t p = fork();
	int st;

	if (p == 0) {
		long r = fn();

		/* errno is only meaningful when the call failed, and the caller
		 * prints it either way -- r == 0 is the interesting case.
		 */
		printf("      -> %s (errno=%d)\n", r ? "errno" : "ok", errno);
		fflush(stdout);
		_exit(0);
	}

	waitpid(p, &st, 0);
	if (WIFSIGNALED(st))
		printf("%-30s killed by signal %d%s\n", name, WTERMSIG(st),
		       WTERMSIG(st) == SIGSYS_NR ?
		       "  <= SIGSYS, the seccomp filter killed it" : "");
	else
		printf("%-30s exited %d\n", name, WEXITSTATUS(st));
	fflush(stdout);
}

static long f_getgroups(void) { return getgroups(0, NULL); }
static long f_setgroups(void) { return setgroups(0, NULL); }
static long f_setgid(void)    { return setgid(getgid()); }
static long f_setuid(void)    { return setuid(getuid()); }
static long f_setresgid(void) { return setresgid(getgid(), getgid(), getgid()); }
static long f_setresuid(void) { return setresuid(getuid(), getuid(), getuid()); }
static long f_unshare_u(void) { return unshare(CLONE_NEWUSER); }
static long f_unshare_ns(void) { return unshare(CLONE_NEWIPC | CLONE_NEWNS | CLONE_NEWUTS); }
static long f_capbset(void)   { return prctl(PR_CAPBSET_DROP, CAP_NET_BIND_SERVICE, 0, 0, 0); }

static long f_capget(void)
{
	struct __user_cap_header_struct h = { .version = 0x20080522, .pid = 0 };
	struct __user_cap_data_struct d[2];

	return syscall(__NR_capget, &h, d);
}

static long f_capset(void) { return syscall(__NR_capset, NULL, NULL); }

int main(void)
{
	printf("uid=%d gid=%d\n", getuid(), getgid());

	try("getgroups(0, NULL)", f_getgroups);
	try("setgroups(0, NULL)", f_setgroups);
	try("setgid(getgid())", f_setgid);
	try("setuid(getuid())", f_setuid);
	try("setresgid(...)", f_setresgid);
	try("setresuid(...)", f_setresuid);
	try("unshare(CLONE_NEWUSER)", f_unshare_u);
	try("unshare(NEWIPC|NS|UTS)", f_unshare_ns);
	try("prctl(PR_CAPBSET_DROP)", f_capbset);
	try("capget(...)", f_capget);
	try("capset(NULL, NULL)", f_capset);

	printf("done\n");
	return 0;
}
