/*
 * stubfork -- fork+reap volume, from a binary rather than from a shell.
 *
 * The fault-injection gate needs a guest that *survives* a fork failing with
 * ENOMEM: that failure is the injection, and what happens afterwards is the
 * point. A shell cannot do it. busybox ash aborts when its own fork fails --
 * "fork: Out of memory" and then exit -- and `cmd || :` does not help, because
 * the shell dies inside itself rather than reporting a non-zero status. The
 * first version of stubfail-init was a shell loop and both the gate and its
 * control died the same way, which is to say the gate tested nothing.
 *
 * So the volume comes from here: a loop that forks, reaps, and counts the
 * failures instead of dying on them. Reaping matters as much as forking --
 * mm_sigchld_irq() is what walks mm_list, and walking a list that holds a freed
 * mm is the bug being reproduced.
 *
 * Freestanding, like every other probe that goes in through compile_probe:
 * clone(SIGCHLD, 0) is a new mm, which is a start_userspace() call, and
 * wait4() is the reap. No libc, no argv (a freestanding _start cannot read it
 * reliably -- the prologue has already moved sp).
 */

#define SYS_write	64
#define SYS_exit	93
#define SYS_clone	220
#define SYS_wait4	260

#define SIGCHLD		17
#define ITERS		2000

static long sys5(long n, long a, long b, long c, long d, long e)
{
	register long x8 asm("x8") = n;
	register long x0 asm("x0") = a;
	register long x1 asm("x1") = b;
	register long x2 asm("x2") = c;
	register long x3 asm("x3") = d;
	register long x4 asm("x4") = e;

	asm volatile("svc #0" : "+r"(x0)
		     : "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x8)
		     : "memory", "cc");
	return x0;
}

static void puts_len(const char *s, long n)
{
	register long x8 asm("x8") = SYS_write;
	register long x0 asm("x0") = 1;
	register long x1 asm("x1") = (long)s;
	register long x2 asm("x2") = n;

	asm volatile("svc #0" : "+r"(x0) : "r"(x1), "r"(x2), "r"(x8)
		     : "memory", "cc");
}

static void putstr(const char *s)
{
	long n = 0;

	while (s[n])
		n++;
	puts_len(s, n);
}

static void putnum(long v)
{
	char buf[24];
	int i = 0;

	if (v == 0) {
		puts_len("0", 1);
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
	long i, pid, fails = 0;
	int st;

	for (i = 0; i < ITERS; i++) {
		pid = sys5(SYS_clone, SIGCHLD, 0, 0, 0, 0);
		if (pid == 0)
			sys5(SYS_exit, 0, 0, 0, 0, 0);	/* child */
		if (pid < 0) {
			/* The injection, and normal: keep going. */
			fails++;
			continue;
		}
		sys5(SYS_wait4, pid, (long)&st, 0, 0, 0);
	}

	putstr("STUBFORK done iters=");
	putnum(ITERS);
	putstr(" fails=");
	putnum(fails);
	putstr("\n");
	sys5(SYS_exit, 0, 0, 0, 0, 0);
	for (;;)
		;
}
