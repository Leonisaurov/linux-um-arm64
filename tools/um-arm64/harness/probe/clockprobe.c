/*
 * clockprobe -- the guest's clock rate, in the guest, without libc.
 *
 * The harness cannot time the guest from the inside, and the guest cannot reach
 * the host's clock except through the guest kernel -- which is the whole point.
 * So the division of labour is: this busy-spins until *its* CLOCK_MONOTONIC
 * advances N seconds and says how long that was, and native.sh times the run
 * from outside. The two must agree, and a guest clock that runs fast makes the
 * difference negative. See doc/70-vdso.md.
 *
 * Freestanding on purpose. mkrootfs.sh's compile_probe is -nostdlib
 * -ffreestanding, and the probes that go in through it are raw syscalls; the
 * one thing that is not available in that path is a libc. clockcheck.c, which
 * is the same measurement with printf, cannot be built there at all, which is
 * how this file came to exist. Written to fd 1, which under init=/clock-init is
 * the console the boot log is captured from.
 *
 * The seconds are a compile-time constant. They cannot come from argv: a
 * freestanding _start has no arguments, and reading them off the stack fails
 * because the prologue has already moved sp by the time C can look -- tried, and
 * the probe silently used its default while the harness compared the wrong
 * number. compile_probe passes no -D, so CI gets CLOCK_SECS; a local test can
 * build with -DCLOCK_SECS=2.
 */

#ifndef CLOCK_SECS
#define CLOCK_SECS 30
#endif

#define SYS_write		64
#define SYS_clock_gettime	113
#define SYS_exit		93

#define CLOCK_MONOTONIC		1

struct timespec {
	long tv_sec;
	long tv_nsec;
};

static long sys2(long n, long a, long b)
{
	register long x8 asm("x8") = n;
	register long x0 asm("x0") = a;
	register long x1 asm("x1") = b;

	asm volatile("svc #0" : "+r"(x0) : "r"(x1), "r"(x8) : "memory", "cc");
	return x0;
}

static long slen(const char *s)
{
	long n = 0;

	while (s[n])
		n++;
	return n;
}

static void putstr(const char *s);

static void puts_len(const char *s, long n)
{
	register long x8 asm("x8") = SYS_write;
	register long x0 asm("x0") = 1;
	register long x1 asm("x1") = (long)s;
	register long x2 asm("x2") = n;

	asm volatile("svc #0" : "+r"(x0) : "r"(x1), "r"(x2), "r"(x8) : "memory", "cc");
}

static void putstr(const char *s)
{
	puts_len(s, slen(s));
}

/* str + a non-negative long, decimal, no padding. */
static void putnum(long v)
{
	char buf[24];
	int i = 0;

	if (v == 0) {
		putstr("0");
		return;
	}
	while (v > 0 && i < 23) {
		buf[i++] = '0' + (v % 10);
		v /= 10;
	}
	while (i > 0)
		puts_len(&buf[--i], 1);
}

void _start(void)
{
	struct timespec a, b;
	long want = CLOCK_SECS, i;

	putstr("CLOCKCHECK_START secs=");
	putnum(want);
	putstr("\n");

	sys2(SYS_clock_gettime, CLOCK_MONOTONIC, (long)&a);

	i = 0;
	for (;;) {
		sys2(SYS_clock_gettime, CLOCK_MONOTONIC, (long)&b);
		i++;
		if (b.tv_sec - a.tv_sec >= want)
			break;
	}

	putstr("CLOCKCHECK_DONE mono_elapsed=");
	putnum(b.tv_sec - a.tv_sec);
	putstr(".");
	/* milliseconds, three digits, from the nanosecond fields */
	{
		long ns = b.tv_nsec - a.tv_nsec;

		if (ns < 0)
			ns += 1000000000L;
		ns /= 1000000L;
		if (ns < 100)
			putstr("0");
		if (ns < 10)
			putstr("0");
		putnum(ns);
	}
	putstr(" spins=");
	putnum(i);
	putstr("\n");

	sys2(SYS_exit, 0, 0);
	for (;;)
		;
}
