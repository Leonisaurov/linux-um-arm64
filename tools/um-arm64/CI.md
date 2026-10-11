# CI, and running the gates on your own machine

The pipeline lives in `.github/workflows/ci.yml` and its two helpers,
`harness/ci-build.sh` and `harness/native.sh`, plus the gate fixture built by
`harness/mkinitramfs.sh`.

## Why there is no qemu here

The port's documents (`doc/00-environment-and-deviations.md`,
`harness/boot.sh`, `harness/vm.sh`) assume an **x86_64 build domain** driving a
`qemu-system-aarch64` VM as the run domain, because when they were written no
arm64 hardware was available. That was recorded as a deviation from the goal,
not as a design choice.

GitHub's `ubuntu-24.04-arm` hosted runner is a real arm64 machine running a real
arm64 kernel (`Linux 6.17.0-1022-azure aarch64` in the run this document was
written from). So:

* no cross-compilation -- `clang`'s default target already is the target;
* no TCG emulation -- the guest's user code runs on the real CPU;
* build and run share one machine, which is exactly what the port set out to
  show.

`boot.sh` and `vm.sh` are untouched and still work for the x86_64+qemu setup.
`native.sh` is the same verdict logic with the VM, the ssh staging and the 9p
share removed.

## The jobs

| job | runner | what it does |
| --- | --- | --- |
| `build` | `ubuntu-24.04-arm` | `ci-build.sh` builds `ARCH=um SUBARCH=arm64 LLVM=1` twice -- `arm64_defconfig`, and the same tree with `config/docker.config` merged -- and emits both kernels, the freestanding `stub_exe`, the exact `.config`s, the Alpine root filesystem, and the gate-2 fixture |
| `net-helpers` | `ubuntu-24.04-arm` | builds `umnet` and gates it with `ci-umnet.sh`: no kernel, no passt and no root needed |
| `android` | `ubuntu-24.04-arm` | builds the kernel against the **Android NDK** for bionic, at 16 KB and 4 KB, and publishes `um-arm64-android` -- the artifact to download and run on a phone |
| `boot` (matrix) | `ubuntu-24.04-arm` | downloads the artifact and runs `native.sh` for each gate, booting whichever kernel that gate names |
| `umdebian` | `ubuntu-24.04-arm` | builds a Debian root filesystem, assembles `dist/umdebian`, and drives the shipped launcher through its documented contract with `ci-umdebian.sh` |

The three jobs are independent after `build`, so a red `umdebian` does not hide
which gate failed, and the two Debian-rootfs users each build their own image
because the guest writes to it.

The fixture is `harness/probe/guestinit.c` as `/init`: a freestanding aarch64
binary with its own `_start`, raw `svc #0` calls, one guest capability per line.
It prints `UMARM_GUEST_OK` and powers the machine off. No busybox, no libc, no
root filesystem, so there is nothing for the gate to fail on except the kernel.
The newc archive is written by an inline Python writer -- `cpio` is not
installed on Termux and is an avoidable moving part.

### The gate matrix

| gate | fixture | `EXTRA_ARGS` | path exercised |
| --- | --- | --- | --- |
| `g2-default` | initramfs | *(none)* | the built-in default: ptrace userspace with `PTRACE_SYSEMU` |
| `g2-seccomp` | initramfs | `seccomp=on` | the seccomp fast path; `on` makes a non-functional seccomp a fatal error rather than a silent fallback |
| `g2-nosysemu` | initramfs | `nosysemu` | `PTRACE_SYSCALL` plus a `NT_ARM_SYSTEM_CALL` cancellation, i.e. what a pre-5.3 arm64 host (a 4.19 Android kernel) does |
| `g3-alpine` | Alpine ext4 on `ubd0` | `rw` | guest VFS, block device, `fork`/`exec`, process teardown |
| `fp-ptrace` | Alpine ext4 on `ubd0` | `rw` | FP/SIMD state: all 32 V registers plus FPCR/FPSR, bit-exact |
| `fp-seccomp` | Alpine ext4 on `ubd0` | `rw seccomp=on` | the same torture on the seccomp path, where the port's fixed FP bug lived |
| `g4-alpine` | Alpine ext4 on `ubd0` | `rw` | 2000 sequential `fork`/`exec` and 64 children alive at once |
| `g3-noaslr` | Alpine ext4 on `ubd0` | `rw` + host `LD_PRELOAD` | gate 3 with `personality()` failing, i.e. an Android host |
| `fp-noaslr` | Alpine ext4 on `ubd0` | `rw` + host `LD_PRELOAD` | the FP torture under the same simulated host |
| `g5-hostfs` | Alpine ext4 on `ubd0` | `rw` + `hostfs=<dir>` | the host filesystem bridge, verified from the host side |
| `g7-debian` | Debian ext4 on `ubd0` | `rw` | a real gcc and glibc in the guest, with the program's output checked |
| `docker-prereqs` | Debian ext4 on `ubd0` | `rw` (kernel built with `docker.config`) | cgroup v2, overlayfs, namespaces, veth/bridge, nftables |

The `g2` fixture is `harness/probe/guestinit.c` as `/init`: a freestanding
aarch64 binary with its own `_start`, raw `svc #0` calls, one guest capability
per line. It prints `UMARM_GUEST_OK` and powers the machine off. No busybox, no
libc, no root filesystem, so there is nothing for the gate to fail on except the
kernel. The newc archive is written by an inline Python writer -- `cpio` is not
installed on Termux and is an avoidable moving part.

The `g3` fixture is a real ext4 image (`mkrootfs.sh`) built from Alpine's
pinned minirootfs with `harness/guest/gate3-init` as `/init`. Building it needs
no root: `mke2fs -d <dir>` populates a filesystem with libext2fs and never
mounts anything, and the Alpine tarball contains no device nodes, which is the
only thing that would have needed privilege. `gate3-init` prints its marker only
after every check has passed -- `uname -m`, a pipeline with a checkable result,
reads and writes through the VFS, the root device really being `/dev/ubda`,
200 sequential `fork`/`exec`, and 16 concurrent children.

The `fp` fixture is `probe/fptorture.c`, compiled into the same image by
`mkrootfs.sh` and run by `harness/guest/fp-init`. It is freestanding, so it needs
no guest libc and no dynamic loader. It exists because gates 1-5 barely touch
floating point: busybox computes almost nothing, so a bug in the FP save/restore
path survives all of them and only surfaces under `dpkg` and a compiler, where
NEON is used continuously -- as "apt occasionally fails with a strange error".
It covers the three paths that are not the GPR set: the syscall round-trip, the
task switch, and signal delivery through `mcontext.__reserved[]` in the
hand-written `arch/arm64/um/signal.c`. The two rows in the matrix above are not
redundant: the bug the port fixed here was specific to seccomp mode, where the
guest's FP/SIMD state was never saved or restored across a signal because the
guard compared `host_fp_size` against `sizeof(struct user_fpsimd_state)` (528)
rather than the 520 bytes actually copied.

The `g4` fixture is `harness/guest/gate4-init`, the same image again. Gates 2
and 3 start a handful of processes; this one starts thousands, sequentially and
concurrently, and checks results rather than exit status -- a pipeline sum, a
multi-stage pipeline whose output is compared against an independent
computation, and a child's non-zero exit status surviving into the parent. One
stub per guest mm means 64 concurrent children are 64 stub processes, which is
the case the sequential loop cannot reach and where the port's reaper and
stub-lifetime bugs lived.

The two `noaslr` gates run the *same* init without changing anything inside the
guest: `PRELOAD` puts `noaslr_preload.so` in the UML process's `LD_PRELOAD`, and
that shim makes `personality(ADDR_NO_RANDOMIZE)` return `EPERM`. That is what an
Android host does. The port asks for `ADDR_NO_RANDOMIZE` and re-execs itself if
the request takes effect, and the goal is explicit that the address-space layout
must not depend on it getting its way -- so this reproduces that host locally,
today, rather than discovering it on a phone after the layout is settled.

A preload that did not load would leave the gate testing an ordinary host and
still passing, so the shim is self-proving: it has a constructor that writes
`noaslr_preload_active` to stderr, the gates declare it as `PRELOAD_MARKER`, and
`native.sh` refuses to pass a run (`verdict=PRELOAD_FAIL`) when the string is
absent. That check runs **before** the marker check on purpose: a gate that did
not test what it claims must not be able to pass at all.

The effect is also visible in the kernel's own first line, which is worth
knowing because it is the difference the port had to survive:

```
ordinary host:  Address space: host top 0x1000000000000, stub at 0xffffffff4000
noaslr host:    Address space: host top 0xfffff4128000, stub at 0xfffff411c000
```

With `personality()` succeeding the port re-execs itself with ASLR off and the
layout is deterministic; with the shim it stays randomised, and `TASK_SIZE` is
unchanged in both (`0xff8000000000`).

`native.sh` records the shim and its marker in `result.txt` as `preload=`,
`preload_marker=` and `preload_missing=`, and copies the library into the run
directory, so a run says which host it simulated.

The `g5` fixture is `harness/guest/gate5-init`, on the Alpine image again, with
`hostfs=<dir>` on the kernel command line -- which both sets the default root and
*confines* every hostfs mount to that tree. hostfs is not a block device: every
guest `open`, read, write and rename becomes a host syscall against a real path.
The gate reads a file `native.sh` seeded, writes 256 KiB, reads it back, and
renames it -- because `doc/30-syscall-budget.md` singles out `renameat2()`, and a
sandbox that omits it breaks `mv` months later. The half that carries the risk is
verified **on the host**: `native.sh` removes the output before the run and
requires it to exist afterwards as `HOSTFS_CHECK`, so the guest's own word is not
the evidence.

The `g7` fixture is `harness/guest/gate7-init`, on a Debian image built by
`mkrootfs.sh DISTRO=debian` with `debootstrap` (which needs root, and only to
`chown` and make device nodes inside a tree it never mounts). The port's original
gate 7 ran `apt install build-essential` *inside* the guest, which needs guest
networking that CI cannot provide; build-essential is baked into the image
instead, and the gate keeps the part that carries the risk. The guest's own gcc
compiles a program that uses **libm and pthreads** and checks itself: the
`sqrt` identity, the same sum computed through `sqrt` and `pow` compared against
each other, and four threads over a shared counter. That is the shape of the bug
the port fixed -- FP state corrupted across a task switch or a signal shows up as
two computations disagreeing, not as a crash.

The `docker-prereqs` fixture is `harness/guest/docker-init` on that same Debian
image, with a kernel built from `config/docker.config`. **It is not `dockerd`**:
containerd, runc and an image do not fit in CI, and neither does pulling one. It
checks the prerequisites that file exists for, read from the *running* kernel
through `/proc/config.gz` rather than trusted from the build host, plus cgroup v2
mounting, overlayfs mounting and writing through to `upperdir`, `unshare` of
every namespace, a veth pair into a bridge, and an nftables `nat` table. The
precedent is in that config's own comments: a variant once dropped `CGROUP_BPF`
and recorded that "docker starts and runs". Docker started, containers did not,
because runc calls `bpf_prog_query(BPF_CGROUP_DEVICE)` on every create. This gate
would have caught that without running dockerd.

The boot log names the mode, so the gate is checkable rather than assumed
(`arch/um/os-Linux/start_up.c`):

```
g2-default   Userspace mode: ptrace      + Checking syscall emulation for ptrace...OK
g2-seccomp   Userspace mode: SECCOMP
g2-nosysemu  Userspace mode: ptrace      + Checking syscall emulation...skipped (nosysemu)
g3-alpine    GATE3 ok root=/dev/root arch=aarch64 sum=5050 procs=200+16
g4-alpine    GATE4 ok sequential=2000 concurrent=64 sum=500500 pipeline=89440
fp-ptrace    FPTORTURE_OK
fp-seccomp   Userspace mode: SECCOMP + FPTORTURE_OK
g3-noaslr    noaslr_preload_active + GATE3 ok ...
fp-noaslr    noaslr_preload_active + FPTORTURE_OK
g5-hostfs    GATE5 ok host_read='hello-from-host' blocks=256
g7-debian    GATE7 ok gcc=12 GATE7_C_OK threads=4 counter=40000
docker-prereqs  GATEDOCKER ok symbols=... controllers=...
```

### The Android artifact

Everything else here builds the **glibc** variant: that is the run domain, and it
is what the gates boot. It is also not what runs on a phone. An app process is
started by zygote with a seccomp filter already installed, and glibc's startup
issues `rseq(2)` and `set_robust_list(2)`, which that filter kills -- a glibc
binary dies before `main()` having printed nothing at all. bionic is the libc the
filter was written for, so `android` builds the same kernel against the NDK:

* **The NDK is pinned twice**: by version and by the sha1 Google publishes for the
  zip (`27.2.12479018`, `090e8083a715fdb1a3e402d0763c388abb03fb4e`). The *zip* is
  cached rather than the unpacked tree -- 663 MB instead of several GB -- and the
  sha1 is verified on every use, so a cache entry is never trusted further than
  the download it came from. Keyed by version *and* digest, so it cannot go
  stale.
* **Both page sizes**, in separate directories. 16 KB is the shipped default and
  the only setting that runs on any host, because a guest page is a host `mmap()`
  and a 4 KB guest cannot boot on a 16 KB one; 4 KB is what most phones are today
  and what the port's gate history was collected on. `build-bionic.sh` asserts the
  symbol took effect after `olddefconfig`, because `scripts/config -e` on a name
  that does not exist warns and carries on, and the failure would then be a kernel
  that boots everywhere except the host it was built for.
* **`stub_exe` ships with it**, because an Android domain refuses `execveat()` on
  a memfd; without it the kernel exits having printed nothing.
* **What is missing is `passt`.** `harness/build-net-bionic.sh` builds the two
  networking helpers, but it applies `dist/passt-bionic.patch`, which is not in
  this tree: passt is a glibc/musl program and needs porting to bionic. An
  existing `passt`/`umnet` pair works with any kernel -- they meet the kernel at a
  socketpair, not at a build -- or the guest runs with no network.

`harness/build-bionic.sh` also gained the two things that make it runnable off an
x86_64 runner: it picks the NDK prebuilt for *this* host (`linux-aarch64` on an
arm64 machine, and it refuses a stock x86_64-only NDK there rather than failing
later as "cannot execute binary file"), and it finds the host compiler before the
Android `--target` shim joins `PATH` -- otherwise `command -v clang` resolves to
that shim and every host tool gets built for Android.

### The shipped artifact

The `umdebian` job runs `harness/ci-umdebian.sh`, which gates the *product*
rather than the kernel: `dist/umdebian` plus the launcher. Everything it checks
is shell between a user and a booted kernel, which is exactly the layer that
breaks silently and that no boot gate can see.

A command goes in and only its output comes out -- `echo hello` produces the
single line `hello`, not one line plus a boot log. Its exit status propagates
(`exit 42` is 42, `false` is 1), so the launcher composes with a shell like any
other command; `-v` still streams the boot log and still propagates the status,
which it used to get wrong by returning 0 unconditionally. The share directory
works in both directions, and the guest side is checked **on the host**: a guest
saying it wrote a file is not evidence, the file existing in `share/` is. A
command containing quotes and `\n` survives, because it travels through the share
and not the kernel command line, which cannot carry either.

The last check is the one worth naming. UML takes an `fcntl(F_SETLK)` write lock
on the backing file, and the second instance gets `Failed to lock '<file>'`
followed by a root-mount panic with a stack trace -- which reads like a corrupt
filesystem and is not. The launcher turns that into one sentence, and the check
holds the lock with `fcntl.lockf` for the same reason: `flock(2)` does not
conflict with `fcntl` locks, so holding it with `flock(1)` would pass against a
guest that booted perfectly.

(`root=/dev/root` and not `/dev/ubda`: that is what the guest's own
`/proc/mounts` reports for the device it was given, which is why `gate3-init`
accepts both.)

Note that the **built-in default is ptrace**, not seccomp:
`seccomp_config` is a zero-initialised `__initdata`, so only `seccomp=on` or
`seccomp=auto` enable the fast path. The matrix therefore covers the fast path
in the `seccomp` column rather than in `default`.

## The verdict

Unchanged from `boot.sh`, because that logic is the part that cost incidents to
get right:

* success is the **marker string** in the boot log, never the exit status;
* an **independent** scan for `BUG:`/`WARNING:`/`Oops`/`INFO: rcu`/`INFO: task
  ... blocked`/`Unable to handle kernel`/`kernel BUG at` runs regardless of the
  marker -- a run that reaches its marker while the kernel reports a defect is
  `verdict=BUG`, not `PASS`;
* on a fatal signal, a gdb backtrace instead of "it does not boot".

`native.sh` prints `UMARM_VERDICT=<verdict>` and archives `result.txt`,
`boot.log`, `kernel-bugs.txt` and (on a signal) `backtrace.txt` under `$ART`.
The boot is bounded by `timeout --signal=KILL` with `panic=-1`, so a hang ends
the run instead of parking a dead prompt until the job timeout.

## Cache design

Only the **compiler cache** is cached, never build outputs: `ccache`, keyed
`ccache-um-arm64-<sha>` with a stable `ccache-um-arm64-` restore prefix.
Restore and save are separate (`actions/cache/restore` + `actions/cache/save`
with `if: always()`), so a build that fails late still leaves its cache behind
and the next attempt is incremental -- the first green build after the ccache
was warm took about 20 seconds.

Because only ccache is restored, a stale cache cannot splice an old object into
a new binary: ccache hashes its inputs and never trusts mtimes, so the
restored-objects-are-newer trap that affects build-tree caches does not apply.
Restored caches are still only a shortcut -- `build.txt` records the sha256 of
both outputs, and the gate's `result.txt` records the `bin_md5` that was
actually booted.

## Bugs this pipeline found

Each of these was invisible to the port's original machine and immediate here:

1. **`arch/um/kernel/skas/Makefile` linked the stub with the host's default
   linker.** The rule drives the link with `$(CC)` to pass `--target=`, which
   also means clang picks its default linker, and `-Wl,--no-rosegment` is an
   lld-only option. kbuild adds `-fuse-ld=lld` only to `KBUILD_HOSTLDFLAGS`,
   which that rule does not use. On a host whose default `ld` is GNU bfd:

   ```
   aarch64-linux-gnu-ld: unrecognized option '--no-rosegment'
   ```

   Fixed by selecting lld in the rule, guarded on clang being the driver.

2. **Artifacts lose the executable bit.** `actions/upload-artifact` /
   `download-artifact` round-trip a zip and do not restore file modes, so
   `linux-um-arm64` arrives 0644. `native.sh` now fixes that itself.

3. **`upload-artifact` roots an artifact at the least common ancestor of its
   paths.** Listing files under `$RUNNER_TEMP/artifacts/*` alongside
   `$RUNNER_TEMP/initramfs.cpiogz` roots it at `$RUNNER_TEMP`, and the boot job
   downloads `artifacts/artifacts/...`. The build job now stages everything into
   `$ART` and uploads that one directory.

4. **`runner.temp` is not available in the job-level `env:` context.** A
   workflow using it there does not fail with a syntax error -- it fails in 0s
   with "This run likely failed because of a workflow file issue", and it fails
   with **zero jobs**, not one. That is worth being precise about: CI cannot
   report on the workflow CI could not read, so the only place this is catchable
   is before the push, which is why `harness/check-workflow.sh` exists. It checks
   that and one more thing that has bitten this file -- a job without
   `timeout-minutes`, which turns a hang into a six-hour run.

   This was got wrong twice: once originally, and once again while adding the
   `android` job. Both times the symptom was the same empty run.

5. **`umnet` could not tell that the kernel had exited.** The UML side of its
   pump is an `AF_UNIX SOCK_DGRAM` socketpair, and closing the peer of a datagram
   socketpair produces no `POLLHUP` and no `EOF`; `poll()` on it blocks forever.
   So when the guest halted, UML exited, and `umnet` stayed in `poll()` with the
   kernel as an unreaped zombie. The kernel was fine and the port was fine --
   what was broken was the ability of anything *waiting* on the launcher to
   find out that the run had finished. On a phone the shipped `./deb` printed
   the command's answer and then never returned: a run that had completed,
   looking exactly like one that had hung.

   Found by running the artifact rather than the kernel, which is why
   `net-helpers` (needs no kernel, no passt, no root) and the `umdebian` job
   exist. The fix is a `SIGCHLD` self-pipe in the pump's `poll()` set; the gate
   asserts the elapsed time, and the old binary hangs against it in 15s.

   The same file's exit-status half had already been fixed for the opposite
   reason -- it used `WNOHANG` with a discarded status and an unconditional
   `return 0`, so a kernel killed by a signal, a panic, and a kernel that never
   started all reached the caller as "exited, status 0". Inside an Android app,
   where a sandbox can kill the process outright and there is no shell to ask,
   that is the difference between a diagnosis and a guess. The gate covers that
   too: `kernel-status` requires status 7 to arrive as 7.

## Running the same gates locally

### On any arm64 Linux

```sh
O=$PWD/../out ART=$PWD/../artifacts bash tools/um-arm64/harness/ci-build.sh
bash tools/um-arm64/harness/mkinitramfs.sh "$PWD/../artifacts/initramfs.cpiogz"
BIN=$PWD/../artifacts/linux-um-arm64 \
INITRD=$PWD/../artifacts/initramfs.cpiogz \
ART=$PWD/../artifacts GATE=g2 MARKER=UMARM_GUEST_OK INIT=/init \
  bash tools/um-arm64/harness/native.sh
```

### On Termux (Android, unprivileged)

Termux is already the run domain. The build, however, must be the **bionic**
one, because an app process is started by zygote with a seccomp filter already
installed and glibc's startup issues calls that filter kills (`rseq`,
`set_robust_list`), so a glibc binary dies before `main()` with no output. Use
`harness/build-bionic.sh` with the Android NDK; on an arm64 device that means an
NDK with a `toolchains/llvm/prebuilt/linux-aarch64` directory (the stock NDK
ships `linux-x86_64` only and will not run under Termux).

**`stub_exe=` is required on Termux.** Measured on a MEGA 3, Android 15,
kernel 5.10.226, Termux as `untrusted_app_27`:

```
execveat(memfd flags=0):   Permission denied
execveat(memfd MFD_EXEC):  Permission denied
exec  from $TMPDIR:        OK
```

UML otherwise writes the stub to a memfd and `execveat`s it, and this SELinux
domain refuses that -- exactly the failure described in
`doc/70-android.md` and in the `um: say why the stub could not be exec'd`
commit. Executing a file in the app's data directory *is* permitted, so point
the kernel at the `stub_exe` the build produced:

```sh
stub_exe=$PREFIX/lib/stub_exe
```

which `native.sh` forwards through `STUB_EXE=<path>`.

Two more Termux notes:

* `$TMPDIR` is under `/data`, i.e. flash, and UML prefers `TMPDIR` over `/tmp`
  for guest RAM. `mem=256M` and an eye on free space are worth more than they
  are on a desktop.
* The `HOST_*` console descriptors are registered with epoll and `epoll_ctl` on
  a regular file fails with `EPERM`. `native.sh` uses `con0=null,fd:1` for that
  reason; only change it if stdout is a terminal.

## Extending the matrix

`harness/loop.sh` lists the full gate matrix the port used
(`g2mini g2alpine g3 g5 g3noaslr g4 fp fpnoaslr`). Everything in it is covered
above except two variations, and three gates below go past it (`g7`, `docker`,
and the second userspace mode for `fp`):

* **`g2alpine`** -- the same initramfs gate with an Alpine-based initramfs
  instead of the freestanding probe. Cheap to add; `mkinitramfs.sh` would need a
  second mode that packs a directory instead of a single binary.
* **`g4`/`fp` on a 16 KB guest** -- `doc/40-page-size.md` describes a whole
  matrix over guest page size. CI runs 16 KB (the default) on a 4 KB host;
  a 4 KB guest is a different build and cannot boot on a 16 KB host at all.
* **`dockerd` itself**, for the reason given above.

The original `init` scripts and rootfs images for those gates lived in the
repository's sibling directories, outside the kernel tree, and are not part of
this snapshot. `guestinit`, `gate3-init`, `gate4-init`, `gate5-init`,
`gate7-init` and `docker-init` replace them; `mkrootfs.sh` is the tool for the
ones that need a root filesystem.

The original `init` scripts and rootfs images for those gates lived in the
repository's sibling directories, outside the kernel tree, and are not part of
this snapshot. `guestinit` and `gate3-init` replace `g2mini` and `g3`; the rest
have to be recreated, and `mkrootfs.sh` is the tool for the ones that need a
root filesystem.
