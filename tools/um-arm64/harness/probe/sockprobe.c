/*
 * sockprobe -- the scratch slot the APK ships as libprobe.so.
 *
 * The app has one place it can exec something from that is not /data/local/tmp:
 * its own nativeLibraryDir, as libprobe.so, in its own uid and its own SELinux
 * domain. /data/local/tmp is shell_data_file and app domains cannot exec it,
 * which is exactly why the slot exists. Whatever is compiled here can be run
 * there with `run-as <pkg> .../libprobe.so`, so this file is a probe of the
 * environment an app process actually has -- which is not the one adb shell
 * has, and not the one this project's other probes assume either.
 *
 * It reports; it only fails on what is required. Two of the answers are known
 * and are printed as facts rather than failures: memfd+execveat is denied under
 * untrusted_app, which is why stub_exe= is mandatory in this port, and the
 * seccomp filter zygote installs is the reason the bionic binaries are built
 * with the NDK instead of glibc. A probe that failed on those would be red on a
 * working device.
 *
 * Not part of a gate: the gates run in a UML guest, and this runs outside one.
 * It is the check for the layer underneath them.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <signal.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static int fails;

static void out(const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
	fflush(stdout);
}

static void bad(const char *fmt, ...)
{
	va_list ap;

	fails++;
	out("SOCKPROBE_BAD ");
	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
	out("\n");
}

/* The whole line, since /proc/self/attr/current ends in a newline of its own. */
static void show_file(const char *path, const char *what)
{
	char buf[256];
	int fd, n;

	fd = open(path, O_RDONLY);
	if (fd < 0) {
		out("%s: unreadable (%s)\n", what, strerror(errno));
		return;
	}
	n = read(fd, buf, sizeof(buf) - 1);
	close(fd);
	if (n < 0) {
		out("%s: unreadable (%s)\n", what, strerror(errno));
		return;
	}
	buf[n] = 0;
	while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == '\r'))
		buf[--n] = 0;
	out("%s: %s\n", what, buf);
}

/* One line out of /proc/self/status, for the fields that answer a question. */
static void show_status(const char *key)
{
	char buf[4096], *p;
	int fd, n;

	fd = open("/proc/self/status", O_RDONLY);
	if (fd < 0)
		return;
	n = read(fd, buf, sizeof(buf) - 1);
	close(fd);
	if (n <= 0)
		return;
	buf[n] = 0;
	p = strstr(buf, key);
	if (!p)
		return;
	for (; *p && *p != '\n'; p++)
		out("%c", *p);
	out("\n");
}

/*
 * execveat(AT_FDCWD, memfd, ...) -- whether a process can exec what it never
 * wrote to disk. This port does not need it (stub_exe= exists for that), but the
 * answer decides whether a launcher can ever drop the stub, so it is reported
 * rather than assumed.
 */
static void probe_memfd_exec(void)
{
	char path[64];
	int fd;

	fd = syscall(SYS_memfd_create, "sockprobe", 0);
	if (fd < 0) {
		out("memfd_create: denied (%s)\n", strerror(errno));
		return;
	}
	snprintf(path, sizeof(path), "/proc/self/fd/%d", fd);
	out("memfd_create: ok, execveat on it: ");
	errno = 0;
	if (syscall(SYS_execveat, fd, "", (char *const[]){ NULL },
		    (char *const[]){ NULL }, AT_EMPTY_PATH) < 0)
		out("denied (%s)\n", strerror(errno));
	else
		out("allowed\n");	/* unreachable: execveat does not return on success */
	close(fd);
}

/*
 * A child, because clone is how UML makes every guest process and the answer
 * can be no for reasons a fork in the same probe would not show. The child
 * exits immediately; the parent only cares whether it was created.
 */
static void probe_clone(void)
{
	int pid, st;

	pid = fork();
	if (pid < 0) {
		bad("fork: denied (%s)", strerror(errno));
		return;
	}
	if (pid == 0)
		_exit(0);
	if (waitpid(pid, &st, 0) != pid) {
		bad("waitpid on a child failed (%s)", strerror(errno));
		return;
	}
	if (!WIFEXITED(st) || WEXITSTATUS(st) != 0) {
		bad("child did not exit cleanly");
		return;
	}
	out("fork+wait: ok\n");
}

int main(void)
{
	void *p;
	long ps;

	setvbuf(stdout, NULL, _IOLBF, 0);

	out("SOCKPROBE_START\n");
	out("uid=%d gid=%d\n", (int)getuid(), (int)getgid());

	show_file("/proc/self/attr/current", "selinux");
	show_status("Seccomp:");
	show_status("NoNewPrivs:");

	/*
	 * The page size is the one answer this port cannot work around: a 16 KB
	 * guest does not boot on a 4 KB host, and the app ships one kernel per
	 * page size because of it.
	 */
	ps = sysconf(_SC_PAGESIZE);
	out("page size: %ld\n", ps);
	if (ps != 4096 && ps != 16384)
		bad("page size %ld is neither 4 KB nor 16 KB", ps);

	/* mmap with the alignment the kernel's own loader needs. */
	p = mmap(NULL, (size_t)ps * 4, PROT_READ | PROT_WRITE,
		 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED)
		bad("anonymous mmap of %ld bytes failed (%s)",
		    (long)ps * 4, strerror(errno));
	else {
		out("anonymous mmap: ok\n");
		munmap(p, (size_t)ps * 4);
	}

	/* Executable memory: the guest's own JITs and the stub both want it. */
	p = mmap(NULL, (size_t)ps, PROT_READ | PROT_WRITE | PROT_EXEC,
		 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED)
		out("PROT_EXEC mmap: denied (%s)\n", strerror(errno));
	else {
		out("PROT_EXEC mmap: ok\n");
		munmap(p, (size_t)ps);
	}

	show_file("/proc/self/exe", "exe");
	probe_memfd_exec();
	probe_clone();

	if (fails)
		out("SOCKPROBE_FAIL fails=%d\n", fails);
	else
		out("SOCKPROBE_OK\n");
	return fails ? 1 : 0;
}
