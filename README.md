# Linux/UML on arm64

`ARCH=um SUBARCH=arm64` — a Linux kernel running as an ordinary aarch64 userspace
process, so that a phone can run a real kernel without root, KVM or a hypervisor.

## What it is for

The useful thing is not that a kernel boots. It is that a **real Linux kernel
runs as an ordinary process on a phone**, which gives an unrooted Android device
things Android otherwise denies it:

* **A real Debian userland.** `dist/umdebian` is a directory you copy to
  `/data/local/tmp`: a kernel, a Debian bookworm image and a launcher.
  `./deb uname -a` runs one command and prints only its output; `./deb` gives a
  shell; files in `share/` are shared both ways. No root, no apk, no mounts, no
  `/dev/kvm`, no user namespace. `rm -rf` removes it completely.
* **A kernel you chose.** Android's kernel is whatever the vendor shipped -- 4.19
  on hardware still being sold. Inside UML the syscall surface, the namespace and
  cgroup behaviour and the page size are the ones in this tree, which is what
  makes it a place to test *kernel-facing* code instead of touring an ABI nobody
  can change.
* **Containers without the privileges a container runtime needs.** The guest
  kernel has real namespaces and cgroup v2, and `dockerd` with overlay2 runs
  inside it on a host that refuses `/dev/kvm`. The prerequisites are what the
  `docker-prereqs` CI gate pins, because that is where a variant of this port
  once claimed "docker starts and runs" while every container create failed.
  `tools/um-arm64/alpine-um` is the launcher for it: an Alpine image with
  Docker installed and the guest network up, where `docker run --rm
  hello-world` pulls the image and runs it; `doc/80-docker-alpine.md` is the
  guide.
* **Kernel work without a device.** The guest is a process on whatever machine
  you already have: `gdb` attaches to it, a boot is a second rather than a
  minute, and the same binary runs on a Pi, a runner, or the phone. That is what
  makes the gate matrix below affordable rather than aspirational.
* **The thin edges of the platform.** `dist/umapp` is an Android app that runs
  the same kernel on a real terminal -- Termux's own terminal emulator, vendored
  (Apache 2.0, `dist/umapp/VENDORED-TERMUX.md`) -- and turns the Alpine + Docker
  + OpenRC image into a shell with `docker` in it, not just a boot log: the
  console has job control, and the first boot asks for the non-root user it will
  log in as (`doas` takes that user to root). The terminal has the screen; what
  the app can do lives in a drawer. The two things that change on their own are
  releases rather than APK contents: the guest image and the app itself are each
  a release asset the app checks for on start, downloads, verifies and installs,
  so an image fix or an app fix is a release and not a rebuild-and-sideload.
  `doc/100-usb.md` hands a real RTL8811AU USB dongle to the guest over
  USB/IP, which is how the port got `wlan0` and a scan on a phone. CI builds the
  APK (`umapp`, on an x86_64 runner because the arm64 runner images install no
  Android SDK) and checks what a device would: the signature, the aarch64 static
  binaries inside `lib/arm64-v8a/`, the terminal classes in `classes.dex`, the
  pty shared object, the assets, the two downloaders, the installer provider,
  and the manifest.

What it is **not**: hardware, a second CPU (the guest is uniprocessor), a 32-bit
compat layer, or an escape from the host. Every guest syscall is a host syscall
and the host still decides whether to allow it -- which is why the port's
interesting bugs are all about the *host* interface, not about the guest.

## Status

Working, and tested rather than asserted:

| | |
|---|---|
| Boot to userspace | Alpine and Debian 12, 4 KB and 16 KB guest pages |
| Syscall interception | `PTRACE_SYSEMU`; syscall **cancellation** where the host has none; syscall **substitution** where a seccomp filter rejects a cancelled call |
| Userspace mode | `SECCOMP` (default fast path) and `ptrace` |
| Loadable modules | `modprobe`/`rmmod`, out-of-tree driver, firmware loading |
| Networking | userspace TCP/IP (passt) over the vector `fd` transport — DHCP, DNS, TCP |
| USB passthrough | a real RTL8811AU dongle from an Android app into the guest over USB/IP, `rtw88_8821au` binds, `wlan0` appears and scans |
| Containers | `dockerd` with overlay2 on cgroup v2; `docker run hello-world` pulls and runs |
| Host libc | glibc and bionic (Android NDK) |

Not working, or not finished:

- **No 32-bit compat.** `CONFIG_COMPAT` is off; the guest runs aarch64 userspace only.
- **`wlan0` association is untested.** The radio comes up, the firmware loads and
  scanning returns real APs with signal levels. Associating needs credentials
  that were not available; nothing beyond scan has been exercised.
- **`BUG: Bad rss-counter state ... type:MM_FILEPAGES val:1`** is fixed, and now
  gated at both page sizes. It printed once per exiting process at 16 KB, where
  `PTRS_PER_PTE` was the literal `512` -- four times the 128 entries a PMD owns --
  so `finish_fault()` accepted a 128-page folio at any `pte_off` and `set_ptes()`
  wrote past the window that PMD owns, into slots no lookup consults and no zap
  frees, while the rmap and the rss counters had already counted them. The
  workload (`harness/guest/rss-init`) is shaped around that mechanism: large
  folios on ext4, faulted in through a file mapping, one mm freed per child. It
  runs at 16 KB and at 4 KB (`rss-16k`, `rss-4k`), and `rss-control` -- the same
  kernel built with the literal back -- is *required* to reproduce the BUG, so a
  clean log cannot be mistaken for a workload that never reached the code.
- **No cpuset controller.** `CONFIG_CPUSETS` depends on `SMP` and UML is
  uniprocessor. `docker info` warns and runs; there is nothing to pin to.
- **No guest vDSO time, and it is not a gap to be filled.** The vDSO this port
  installs exports `__kernel_rt_sigreturn` and nothing else
  (`arch/arm64/um/vdso/vdso.lds.S`), which is load-bearing -- glibc aarch64
  needs it for signal return. A time vDSO is inapplicable rather than missing:
  `clock_gettime` in a UML guest can only be answered by the host's clock, and
  reaching it costs a syscall, so that same file says a fast path "would save
  nothing". x86 UML reached the same conclusion and ships time functions that
  are syscall stubs (`arch/x86/um/vdso/um_vdso.c`).
  `GENERIC_VDSO_OVERFLOW_PROTECT` is not a dependency of this port: it protects
  the `delta * mult` of a fast path reading a clocksource from a shared data
  page, and with no data page there is nothing to protect.
  The guest's clock *is* the host's -- `timer_read()` divides `os_nsecs()`, the
  host's `CLOCK_MONOTONIC` (`arch/um/os-Linux/time.c`), by `TIMER_MULTIPLIER`
  (`arch/um/kernel/time.c`) -- so it cannot drift. What was genuinely untested
  is the *rate*: see `doc/70-vdso.md`.

Three bugs worth naming, all found by running the port on phones rather than by
reading it, and all fixed on this branch:

- **Pointer authentication stayed enabled in the stub.** One stub per guest mm
  means a guest `fork()` starts a new stub, and starting a stub is an
  `execve()`, which on arm64 generates fresh PAC keys. The child returns into a
  stub whose `APIAKey` did not sign the return addresses on its stack, and
  glibc's `_Fork` is `paciasp` / `svc #0` / `autiasp` — so with FEAT_FPAC the
  child dies inside `_Fork` having printed nothing. NOPs on pre-Armv8.3
  hardware, fatal on Armv9. It breaks every container built with branch
  protection, on every fork.
- **Guest FP/SIMD state was never saved or restored across a signal in SECCOMP
  mode**, because the guard compared `host_fp_size` against
  `sizeof(struct user_fpsimd_state)` (528) rather than the payload actually
  copied (520). Go's `SIGURG` preemption then corrupted its own AES-GCM state,
  and every TLS transfer past a few megabytes died with `bad record MAC`.
- **`PTRS_PER_PTE` was a literal 512** where it has to be `PMD_SIZE >>
  PAGE_SHIFT`: right at 4 KB, four times too large at 16 KB, letting generic mm
  write PTEs past the window a PMD owns.

Tested on:

- **Poco F3** (`M2012K11AG`/`alioth`, Snapdragon 870 / SM8250), Android 15, host
  kernel `4.19.246`, 4 KB pages, Armv8.2. That host has no `PTRACE_SYSEMU` —
  arm64 gained it in 5.3 — which is why the cancellation and substitution paths
  exist and are exercised daily rather than theoretically. It also has neither
  pointer authentication nor SVE, so it says nothing about either.
- **Galaxy S26 Ultra** (`SM-S948B`/`m3q`), Android 16, host kernel `6.12.30`,
  4 KB pages, Armv9 with SVE and pointer authentication. The opposite end: a
  current host where `PTRACE_SYSEMU` is present and the CPU implements the
  features the older phone lacks. Two of the three bugs above were invisible on
  the Poco and immediate here — the PAC one is fatal on this CPU and a NOP on
  that one — so the pair is the point rather than either device.
- An **arm64 Debian run domain** for the gates.

Both interception fallbacks can be forced anywhere with `nosysemu` and
`nocancel`, so they are testable without owning a 4.19 phone.

## Base

- Base: **Linux 7.2-rc4** (`origin/next`, the uml tree).
- Branch: **`um-arm64`**, 38 commits on top. There is no other branch; the
  history is linear and each commit is one change.
- Roughly a third of the series is not arm64-specific — x86 and generic `um/`
  fixes found on the way — and those stand on their own.

## Build

Cross-compiling from x86_64 needs nothing but clang: upstream already maps
`SUBARCH=arm64` to `--target=aarch64-linux-gnu` for `ARCH=um`, so the command
line is the same as it would be on an arm64 host.

**glibc** (development, the gates):

```sh
make ARCH=um SUBARCH=arm64 LLVM=1 defconfig
make ARCH=um SUBARCH=arm64 LLVM=1 -j$(nproc)
```

or `harness/build.sh`, which adds ccache and publishes the binary the gates run.

**bionic** (Android NDK, what an app can exec):

```sh
NDK=/path/to/android-ndk-r27c harness/build-bionic.sh
```

The kernel notices bionic by asking the compiler whether `__ANDROID__` is
defined, so the only difference in that script is the target triple. It links
static, because Android has no `/lib/ld-linux-aarch64.so.1` and an app may only
execute from its own native library directory.

Extra config fragments:

```sh
EXTRA_CONFIG="config/usb-wifi.config config/docker.config" harness/build-bionic.sh
```

## Run

One command, one shell:

```sh
./linux mem=512M ubd0=rootfs/alpine.ext4 root=/dev/ubda rw \
        init=/bin/sh con=null con0=fd:0,fd:1
```

`con0=fd:0,fd:1` puts the guest console on this terminal. Use `con0=null,fd:1`
when stdin is not pollable — UML registers console descriptors with epoll, and
`epoll_ctl` on a regular file fails with `EPERM`, after which the console stops
and the boot looks like it died.

Useful options added by this series:

| | |
|---|---|
| `seccomp=on/auto/off` | userspace mode; `on` is roughly 5× faster per syscall |
| `nosysemu` | pretend the host has no `PTRACE_SYSEMU` |
| `nocancel` | pretend the host rejects a cancelled (`-1`) syscall |
| `seccomp_spin=<us>` | stub spin budget before parking; `0` restores always-park |
| `prefault=<bytes>` | anonymous fault-around window; `0` disables |
| `stub_exe=<path>` | exec the stub from a path instead of a memfd |

## Tests

Everything below is reproducible, and the harness is deliberately stricter than
the thing it tests.

A gate is a boot that must print a marker string. **The verdict is the marker,
never the exit status** — `adb shell` returns 0 whatever the remote command did,
and a truncated log is indistinguishable from a kernel that stopped.

```sh
GATE=g3 MARKER=UMARM_BOOT_OK INIT=/gate3-init \
  UBD0=$PWD/rootfs/alpine.ext4 EXTRA_ARGS="rw seccomp=on" harness/boot.sh
```

It prints `verdict=PASS|FAIL|SIGNAL`, the artifact directory, and
`kernel_bugs=N` — an **independent** scan for `BUG:`/`WARNING:` in the boot log,
because an early version had the marker short-circuit the bug check and a real
rss-counter BUG rode along inside a green gate.

The gate matrix, including the expensive ones sampled every N iterations:

```sh
N=20 harness/loop.sh            # g2mini g2alpine g3 g5 g3noaslr g4 fp fpnoaslr
```

On a phone over adb, same interface:

```sh
PUSH=1 BIN=$PWD/artifacts/linux-bionic GATE=g3 INIT=/gate3-init \
  UBD0=alpine.ext4 EXTRA_ARGS="seccomp=on" harness/android.sh
```

Output is captured **on the device** and pulled afterwards, never streamed:
streaming loses the tail, and every gate that "failed" on that phone before this
change was actually passing.

Related probes worth knowing about: `harness/probe/vethprobe.c` creates a veth
pair over rtnetlink, because busybox's `ip` does not know the veth link type and
fails identically whether or not `CONFIG_VETH` is set — useless as a test.

## CI

`.github/workflows/ci.yml` builds and boots the kernel on GitHub's
`ubuntu-24.04-arm` runner. That runner is a real arm64 host, so `./linux` is
built and booted on the same machine and the `qemu-system-aarch64` run domain
the rest of these documents describe is not needed: no cross-compilation, no
TCG, no ssh staging. `harness/native.sh` is `boot.sh`'s verdict logic with the
VM removed.

The gate is the marker string in the boot log plus an independent
`BUG:`/`WARNING:` scan, and several gates add a check on the *host* side of the
boundary they test. The matrix runs twelve gates: an initramfs whose `/init` is a
freestanding probe, in the built-in ptrace default, with `seccomp=on`, and with
the `nosysemu` cancellation fallback that pre-5.3 arm64 kernels take; a real
Alpine ext4 root filesystem from `ubd0` (guest VFS, block device, `fork`/`exec`);
2000 sequential and 64 concurrent `fork`/`exec`; hostfs, verified by the file the
guest wrote being readable on the host; the FP/SIMD torture in both userspace
modes; two of those gates again under an `LD_PRELOAD` shim that makes
`personality()` fail, i.e. an Android host; a Debian image where the guest's own
gcc compiles a libm-and-pthreads program that checks itself; and the docker
prerequisites on a kernel built with `config/docker.config`. A separate job then
verifies the **artifact** rather than the kernel -- `dist/umdebian`'s launcher,
driven through the contract its README documents (a command in, its output out,
its status propagated, the host share both ways, and a sentence instead of a
stack trace when the image is already locked).

One job exists purely for the phone. Everything above builds the **glibc**
variant, because that is the run domain the gates boot -- and it is not what runs
on a device. An Android app process starts with a seccomp filter already
installed, and glibc's startup issues `rseq(2)` and `set_robust_list(2)`, which
that filter kills; the binary dies before `main()` and prints nothing at all. So
the `android` job builds the same kernel against the pinned **Android NDK** for
bionic, at both page sizes, and publishes `um-arm64-android`: kernel, `stub_exe`,
launcher, the two networking helpers (`umnet` and a `passt` built here from a
pinned commit plus `dist/passt-bionic.patch`) and a `RUN.md` with the commands --
ready to copy onto a phone and run, networking included. That is the artifact to
download if what you want is your own UML.

See **[tools/um-arm64/CI.md](tools/um-arm64/CI.md)** for the pipeline, the ccache
contract, the bugs the pipeline found, and how to run the same gates on any arm64
Linux or on Termux (where `stub_exe=` is required, because Android's
`untrusted_app` domain refuses `execveat` on a memfd).

## Benchmarks

Measured on the Poco F3, `adb shell`, guest running `perfbench`. Every column of
a table below is a condition **inside one interleaved run**, so a difference
along a row cannot be thermal drift or governor state. Columns from different
tables are from different runs and must not be compared with each other — that
restriction is the whole point of the harness, not a formality.

Medians of 7 interleaved rounds, µs/op, seccomp mode:

| | native | proot | 128K window | 512K window |
|---|---|---|---|---|
| syscall | 0.079 | 0.166 | 2.049 | **1.999** |
| openat | 2.503 | 28.005 | 4.494 | **4.466** |
| fault | 1.652 | 1.496 | 11.812 | **10.884** |
| forkexec | 3196 | 516 | 1187 | **1177** |

**The `fault` row is not one measurement.** `perfbench` steps by
`sysconf(_SC_PAGESIZE)`, and this guest runs 16K pages against the host's 4K, so
the native figure is per 4K page and the guest's is per 16K page — four times
the memory for one number. Per byte the guest is **1.77×** the host on fresh
anonymous memory, not the ~7× the column implies. The per-page reading of this
row was believed here for a long time and sent a good deal of work chasing an
overhead that was mostly a unit error; `harness/faultbench.c` reports per
megabyte as well as per page so that it cannot happen again.

The two guest columns are the same binary under two command lines, differing
only in the fault-around window: 128K is what the default used to be (8 pages
at 16K), 512K is what it is now (32, the top of the ramp). A separate run,
seccomp only, takes the window apart — again all conditions inside that one run:

| | native | proot | `prefault=0` | 8 pages | 32 pages |
|---|---|---|---|---|---|
| fault | 1.540 | 1.504 | 19.076 | 11.791 | **10.913** |

So having a window at all is worth 1.62×, and widening it from 8 pages to 32
adds a further 8%. `syscall` (2.001 / 1.953 / 2.043) and `forkexec` (1144 / 1152
/ 1144) do not move across those three, which is the check that the change
reaches the fault path and nothing else.

Earlier tables in this file's history carried `before` and `+waiter-bit`
columns, from a run that no longer shares a machine state with anything above.
They are not reproduced here rather than being pasted alongside newer numbers:
the waiter-bit change took `syscall` from 9.841 to 1.995 µs and fault-around
took `fault` from 18.897 to 11.076, both inside their own run.

**Methodology**, because the numbers are worthless without it:

- Pinned to cores 4–5, with a busy loop held on core 6. Those three share one
  cpufreq policy, the governor is `schedutil` and there is no root to pin the
  clock, so without the keeper `perfbench` measures the frequency ramp. That
  alone moved the validator from 0.892 to 1.3 ns/iter.
- Conditions **interleaved**, not run in blocks, so drift hits all of them equally.
- Medians, never means.
- `compute` — pure userspace arithmetic, no kernel entry — is a **validator**.
  If it disagrees across conditions by more than 5%, or jitters more than 8%
  within one, the whole table is thrown away and nothing is printed. Identical
  instruction streams cannot differ; if they do, the machine moved.
- That validator earns its keep. The window sweep above was run twice before it
  produced a table: three kernels × two interception modes is eight conditions,
  long enough for the phone to move under it, and both attempts came back at
  ~27% jitter and printed nothing. Naming only the mode the question needs
  (`MODES=sec`) halved the run and it passed at 1.1%. A table that takes longer
  to collect than the machine stays still is not a more thorough table.
- `native` and `proot` are controls. proot is there because it is the real
  alternative on an unrooted phone, not because bare metal is.

**Caveats:**

- One phone, one SoC. Nothing here says how this behaves elsewhere.
- These are `adb shell` numbers. The same kernel inside the Android app is
  unpinned and unboosted, and measures ~1.9 µs/syscall with `compute` about 18%
  slower — real-world rather than best-case.
- `syscall` is `getppid()`, the cheapest call there is, so it is the purest
  measure of interception overhead and the least like real work. `openat` is
  the row that resembles what programs actually do.
- `compute` is native speed by construction — guest user code runs as real
  instructions on the real CPU. That is the whole point, and it is why a
  compile inside the guest costs roughly what a compile costs.

Reproduce:

```sh
KERNELS="base=... waiter=... fault=..." ROUNDS=7 harness/verifybench.sh
```

It writes `manifest.txt` (git HEAD, md5 and `file(1)` of every binary, device
model, host kernel, page size, every cpufreq policy, battery state),
`results.tsv` (one row per sample), the raw transcript of every measurement, and
`env-before/after.txt`. The table is derived only from the TSV, and the TSV only
from the transcripts, so any of the three can be recomputed from the one below it.

## Upstream

I am not maintaining this and I am not planning to shepherd it through review.
Take whatever is useful — individual patches, the whole series, or just the
harness. It is GPL-2.0 like the rest of the kernel.

The series is `git format-patch`-ready: one change per commit, DCO signed off,
`checkpatch` clean apart from six false positives against idioms that appear
verbatim in mainline (`mb()` with an asm barrier, `ARCH_HAS_SETUP_ADDITIONAL_PAGES`,
`__SYSCALL(nr, sym)`).

If you do pick it up, the parts most likely to be independently useful are the
generic `um/` fixes and the x86 ones, which have nothing to do with arm64.
