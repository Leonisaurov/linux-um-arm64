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
| `build` | `ubuntu-24.04-arm` | `ci-build.sh` builds `ARCH=um SUBARCH=arm64 LLVM=1` five times -- `arm64_defconfig`; the same tree with `config/docker.config` merged; the same tree at `PAGE_SIZE=4k`; the same tree with `config/modules.config` merged (plus `make modules`, whose `.ko` the module gates load through hostfs); and the same tree with `config/control-ptrs-per-pte.patch` applied, which is the negative control for the rss gate -- and emits each kernel, the freestanding `stub_exe`, the exact `.config`s, the Alpine root filesystem, and the gate-2 fixture |
| `net-helpers` | `ubuntu-24.04-arm` | builds `umnet` and gates it with `ci-umnet.sh`: no kernel, no passt and no root needed |
| `android` | `ubuntu-24.04-arm` | builds the kernel against the **Android NDK** for bionic, at 16 KB and 4 KB, and publishes `um-arm64-android` -- the artifact to download and run on a phone |
| `boot` (matrix) | `ubuntu-24.04-arm` | downloads the artifact and runs `native.sh` for each gate, booting whichever kernel that gate names |
| `flake` | `ubuntu-24.04-arm` | the flake loop, on a schedule and on demand: `harness/ci-flake.sh` runs the matrix N times against the **modules** kernel and tallies it. Not a gate -- it is a campaign, and 200 iterations is twenty minutes |
| `umapp` | `ubuntu-24.04` | builds `dist/umapp` into an APK with `aapt2`/`javac`/`d8`/`apksigner` and verifies it with `ci-umapp.sh`. On an x86_64 runner for the same reason as `android`: the arm64 runner images install no Android SDK at all, and the command-line tools package is an x86_64 build. Nothing is downloaded -- the x86_64 image ships build-tools and platforms under `$ANDROID_HOME` |
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
| `mod-64m` | Alpine ext4 on `ubd0` | `rw`, `hostfs=<dir>`, `mem=64M` | gate 10: a real `.ko` through hostfs, loaded with `insmod`, at the memory size where no PLT is needed |
| `mod-512m` | Alpine ext4 on `ubd0` | `rw`, `hostfs=<dir>`, `mem=512M` | the same module where the module region is far enough from the kernel text that `CALL26` cannot reach and PLTs are mandatory |
| `mod-3g` | Alpine ext4 on `ubd0` | `rw`, `hostfs=<dir>`, `mem=3G` | the same module where `ADRP` is near its limit and the veneer path runs |
| `rss-16k` | Debian ext4 on `ubd0` | `rw` | the rss counters at 16 KB pages: large folios on ext4, faulted in through a file mapping, one mm freed per child |
| `rss-4k` | Debian ext4 on `ubd0` | `rw` (kernel built at `PAGE_SIZE=4k`) | the same workload at 4 KB pages, which the port's own notes leave untested. Skipped with a reason on a host whose pages are larger, because a 4 KB guest cannot boot there |
| `rss-control` | Debian ext4 on `ubd0` | `rw` (kernel built with the literal `PTRS_PER_PTE`) | the negative control: it must *reproduce* `Bad rss-counter`, and a control that does not is reported as a failure of the control |

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

The `mod-*` fixtures are `harness/guest/module-init`, and gate 10 turned out to
be a config change rather than a port: the loader is already wired for this
subarch -- `arch/arm64/um/Makefile` builds the parent architecture's `module.c`,
`module-plts.c` and `insn.c`, and `arch/arm64/um/asm/{module.h,module.lds.h}`
supply the `struct mod_arch_specific` and the `.plt`/`.init.plt` sections those
need under `ARCH=um` -- and `arm64_defconfig` simply says
`# CONFIG_MODULES is not set`. What was missing was not code but an answer, which
is what these three gates produce: nothing had ever loaded a module in this port.

The module is not a hand-written fixture. It comes through hostfs from
`make modules` on the same tree that built the kernel, so it is a real `.ko` with
real relocations against real kernel symbols. `binfmt_misc` is the one chosen
because its job is visible from userspace: it registers a filesystem, so it
appears in `/proc/filesystems`, and that only happens if its init function ran
and its calls into the kernel landed at valid addresses. `/proc/modules` alone
would not say so -- a module can be listed there with its relocations applied to
the wrong addresses.

The three entries differ only in `mem=`, and that is the test rather than a
detail: the module region's placement decides which relocation paths are taken.
At 64M no PLT is needed; at 512M the module is far enough from the kernel text
that a direct `CALL26` cannot reach and PLTs are mandatory; at 3G `ADRP` is near
its limit and the veneer path runs. A single run at the default would skip the
entire PLT path while looking green.

The `rss-*` fixtures are `harness/guest/rss-init`, and the reason there are three
of them is the whole point of the exercise. `check_mm()` runs unconditionally
from `__mmdrop()`, so an mm freed with file-backed pages still accounted to it
prints `BUG: Bad rss-counter state ... type:MM_FILEPAGES val:N` -- and nothing
fails when it does. The counters are simply wrong, and they are the counters the
OOM killer and `/proc/*/status` read, which is why this needed a gate rather
than a reader.

The defect is one line: `PTRS_PER_PTE` was the literal `512`, which at 16 KB
pages is four times the 128 entries a PMD owns. The only bound `finish_fault()`
puts on mapping a large folio in a single `set_ptes()` is
`pte_off + (nr_pages - idx) > PTRS_PER_PTE`, so with the literal a 128-page folio
is accepted at any `pte_off` and the run reaches past index 127 -- which the
page-table walk masks away with `(PTRS_PER_PTE - 1)`, so no lookup consults
those entries and no zap frees them, while the rmap and the rss counters have
already counted them.

So the workload is shaped around that mechanism, not around "run a shell":
large folios (a multi-MB file read sequentially on **ext4** -- small files never
get them and tmpfs is a different path), faulted in through a **file mapping**
(which is what makes them `MM_FILEPAGES` and what routes through
`finish_fault()`), with one mm freed per child. A workload missing any of the
three would pass on a broken kernel just as happily as on a fixed one.

Which is exactly why `rss-control` exists. It is the same kernel built with
`config/control-ptrs-per-pte.patch` applied -- the literal back, and the
`static_assert` that guards the invariant removed with it, since a control that
cannot build is not a control -- and it **must** reproduce the BUG. `native.sh`
grew an `EXPECT_BUG` for it: the diagnostic appearing is the expected result
there, so it does not make the verdict `BUG`, and `expect_bug_hits=N` goes into
`result.txt` as the evidence that it fired. A control that does *not* reproduce
fails as `CONTROL_FAIL`, loudly, because that is the one outcome that says the
other two runs prove nothing.

`rss-4k` is the half the port's own notes leave as untested (`doc/60-
continuation.md`, item 0a: "whether the 4 KB build is also clean is untested").
It needs a 4 KB host -- a guest page is a host `mmap()`, and a 4 KB guest on a
larger host hangs rather than failing -- so the step measures the runner's page
size and skips with `verdict=SKIP` and the reason when it cannot run. That is a
statement about the host and nothing about the kernel, and it is reported as one
rather than passed silently.

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
rss-16k      GATERSS ok RSS_PARENT pages=2048 RSS_TOUCHED pages=2048 children=8 rounds=4
rss-4k       GATERSS ok RSS_PARENT pages=2048 RSS_TOUCHED pages=2048 children=8 rounds=4
rss-control  GATERSS ok ... + BUG: Bad rss-counter state ... type:MM_FILEPAGES val:1  (expected)
```

#### The APK

`umapp` builds the app the same way its `build-apk.sh` documents -- `aapt2`,
`javac`, `d8`, `apksigner`, no Gradle -- and then checks it with
`harness/ci-umapp.sh`, because there is no device on a runner to install it on.

What that verifier can check is everything that otherwise only fails on a phone:
that the signature verifies (Android refuses to install an unsigned APK, and that
refusal happens after the download), that the native binaries are inside
`lib/arm64-v8a/` and are aarch64 static ELFs (the app cannot exec from its data
directory, which is why the kernel is shipped as `libuml.so`; a dynamic ELF or one
for the host would extract fine and then fail to exec), that the assets the app
reads at startup are present, and that the manifest claims what it must --
`org.umarm.debian`, `minSdkVersion 26`, `arm64-v8a`, INTERNET, and the USB device
filter that makes the attach prompt appear.

Two differences from what the author shipped, both worth naming rather than
hiding. `sockprobe_bionic` is absent: the script has a scratch slot for it, and
the staging loop warns rather than failing, but there is no source for it in the
tree. And the initramfs is the gate-2 fixture rather than the Alpine one the app
was shipped with -- the tree has no producer for an Alpine initramfs, so the APK
this job builds boots the fixture. An APK that boots something is a better
artifact than one that boots nothing, but it is not the app the author released.

## The Android artifact

This is the one job that runs on an x86_64 runner (`ubuntu-24.04`), and the
reason is worth recording because everything else here is on `ubuntu-24.04-arm`:
**Google publishes the NDK for x86_64 hosts only.** There is no
`android-ndk-rXX-linux.zip` that an aarch64 machine can execute, which is why an
arm runner fails with `cannot execute binary file: Exec format error` on the
compiler it just unpacked -- and why an aarch64 host that wants to build this
locally needs a repacked NDK (`build-bionic.sh` looks for
`toolchains/llvm/prebuilt/linux-aarch64` and refuses a stock one there rather than
failing later). Cross-compiling is not a compromise for this job: the target is
aarch64-android either way, and the port's own bionic binaries were built this
way.

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

**The artifact is verified on the device, not just built.** CI has no phone, so
it records what it built and leaves the last step to `harness/verify-artifact.sh`,
which walks the whole chain: the kernel's md5 against `build.txt`, a boot for
each page size that can run on the host, the guest reporting that page size, a
`uname` containing the commit `build.txt` recorded, gcc inside the guest building
the libm+pthreads program and it computing correctly, and -- given the helpers --
the guest reaching the network. A page size below the host's is skipped with a
reason rather than failed, because a guest page is a host `mmap()`.

Run on a MEGA 3 (Android 15, 4 KB host pages) against the artifact from commit
`05da2d23c`: **10/10, both page sizes**, with `uname -r` reporting
`7.2.0-rc4-g05da2d23ca3d` -- the binary naming the commit it came from, which is
the chain that makes a downloaded kernel checkable rather than trusted.

**The networking helpers are built here too**, which is what makes the artifact
self-contained. `passt` is pinned by *commit*
(`defc25b9444c508d21badb6bc9a0b835ddd01126`) rather than by tag or by "latest",
because `dist/passt-bionic.patch` is a diff against exactly that tree; the pin is
also the short hash the working binary reports as its version
(`passt defc25b-bionic`). The patch is 20 hunks in 10 files, in two groups.

**Five runtime hunks**, which are why passt can run at all on Android:

* `/proc/self/uid_map` missing means there is exactly one user namespace, so
  `ns_is_init()` returns true instead of dying;
* `unshare(CLONE_NEWUSER)` returning `EINVAL` means the kernel has no user
  namespaces: warn and continue as the unprivileged uid it already is;
* `unshare(CLONE_NEWIPC|NEWNS|NEWUTS)` returning `EPERM` means no
  `CAP_SYS_ADMIN`, and everything after it in `isolate_prefork()` -- remounting
  `/`, a private tmpfs, `pivot_root` -- needs the same privilege, so the whole
  prefork isolation is skipped rather than failing one step at a time;
* a netlink route socket cannot be **bound** by an untrusted app (SELinux allows
  the shell uid and denies apps), and an unbound one cannot send either, so
  `nl_sock_init()` warns instead of dying and the three discovery entry points
  return "not found" -- which is correct, because umnet passes the entire
  configuration on the command line;
* `setgroups()`, `setgid()` and `setuid()` are **killed** by Android's app
  seccomp policy with `SIGSYS`: not an error return, a death with no message and
  no errno, which is why it took a probe to find. They are skipped, and there is
  nothing to drop -- passt is already the unprivileged uid it was given. Asking
  first does not work here, which is worth recording: the call that would tell
  you the syscall is unavailable is the call that kills the process, and an app
  really does have supplementary groups, so a `getgroups()`-based guard calls
  `setgroups()` anyway.

**Five bionic header hunks**: AOSP's uapi is neither glibc's nor musl's.
`<resolv.h>` exists without `MAXNS`/`MAXDNSRCH`; `struct ipv6hdr` and
`struct ipv6_opt_hdr` are already defined; `struct udphdr` was renamed to
`__kernel_udphdr`, so `<linux/udp.h>` stops supplying it; there is no
`<paths.h>`, so `_PATH_LOG` is defined in `log.c`; `<linux/virtio_ring.h>`
carries the structures and none of the helpers, so `vring_need_event()` is copied
from the kernel's own uapi; and `<inttypes.h>` is not pulled in transitively the
way glibc and musl do it, so `PRIu16` needs an explicit include.

It was verified the way this project verifies things: the patch applied to a
**pristine checkout of the pin**, built for bionic, and the result booted a guest
on a MEGA 3 that took a DHCP lease, reached `1.1.1.1:80` over TCP and resolved
`example.com` -- identical to the prebuilt `passt` upstream ships in its release.
The method that found the `SIGSYS` is worth keeping too: a probe that forks one
syscall per child and reports which child is killed, because a seccomp death
leaves nothing behind to read.

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

6. **`[ "" -gt 4096 ]` under `set -e`, in the 4 KB gate's host-page check.**
   The check asks `getconf PAGESIZE` and compares. Termux has no `getconf`, so
   the answer is the empty string, `[` prints `integer expected` and returns
   non-zero, and `set -e` turns that into a failed step. The gate would have
   failed for a reason with nothing to do with the kernel, on the one host class
   the harness is most used on. It now falls back to `python3 -c
   'os.sysconf("SC_PAGE_SIZE")'` -- the same way `verify-artifact.sh` already
   did it -- and treats an undeterminable page size as an error with a message
   rather than as a guess.

7. **The step summary read a path `native.sh` never writes.** It looked for
   `$RUNNER_TEMP/run/<gate>/result.txt`, and `native.sh` writes
   `<gate>/<stamp>/result.txt` plus a `<gate>-latest` symlink next to it. So
   every gate's summary said `no result.txt` -- the one place a human looks,
   empty, on every run. Both the `result.txt` and the `kernel-bugs.txt` half had
   it. Worth recording because it survived several green runs: a summary that
   says "no result.txt" looks like a run with nothing to report.

8. **`EXPECT_BUG: unbound variable`, which turned all fifteen boot gates red at
   once.** `native.sh` runs under `set -u`, and the new `EXPECT_BUG` had no
   default, so `[ -n "$EXPECT_BUG" ]` was itself an unbound-variable error on
   every gate that is not a control. The local test passed because it always
   *set* the variable, including as the empty string -- and under `set -u`
   defined-but-empty is not the same thing as unset. One line
   (`EXPECT_BUG=${EXPECT_BUG:-}`), and the lesson is about the test: a harness
   that supplies every input cannot catch a missing default.

9. **The Debian image was root-owned, and UML silently made the root read-only.**
   `mkrootfs.sh` runs `sudo mke2fs` for the Debian tree -- debootstrap leaves
   root-owned files and device nodes that have to survive into the image -- and
   that also means the image *file* comes out root-owned. The boot job runs as
   `runner`, so `open_ubd_file()` could not open the backing file for writing,
   and it falls back to read-only on EACCES without a word:

   ```c
   if (!openflags->w || ((fd != -EROFS) && (fd != EACCES)))
           return fd;
   openflags->w = 0;
   ```

   So `rw` on the kernel command line was quietly ignored and the guest got a
   read-only root. It went unnoticed because no gate had ever written to that
   image -- g7 compiles in a tmpfs and the docker gate writes to tmpfs too -- so
   the first gate that tried (the rss one) is the one that found it. Fixed by
   chowning the image to the invoking user after mke2fs, and the rss fixture now
   checks that /var/tmp is writable so that the next occurrence names itself
   instead of failing with an empty message.

10. **`make modules` succeeded and produced nothing.** The modules config named
   `CONFIG_MODULES=y` and nothing else, on the reasoning that
   `arm64_defconfig` already says `CONFIG_BINFMT_MISC=m`. But the first
   `make defconfig` runs olddefconfig while MODULES is still off, and Kconfig
   resolves a tristate whose dependency is `n` to `y` -- so by the time the
   fragment merged `CONFIG_MODULES=y`, the `m` was gone and olddefconfig does not
   bring it back. The build was green, the artifact held an empty directory, and
   the gate said `no .ko in the host share`. The fragment now names the modules it
   wants, which is the only way for them to survive the order the build runs in.

11. **`ls` plus `pipefail` plus `2>/dev/null` is a silent exit.** The APK job
   failed with `Process completed with exit code 2` and *no output at all*.
   `build-apk.sh` runs under `set -euo pipefail`, and the line that picks the
   newest build-tools was

       BT=${BT:-$(ls -d "$SDK"/build-tools/* /tmp/bt*/android-* 2>/dev/null | ...)}

   On the runner `/tmp/bt*/android-*` matches nothing, `ls` exits 2 for that, the
   pipeline's status under `pipefail` becomes 2, the assignment inherits it, and
   `set -e` ends the script -- with the reason discarded by `2>/dev/null`. The
   fix is a picker that always succeeds, which leaves the script's own checks to
   report a missing toolchain in words. Reproduced locally before fixing, under
   `set -euo pipefail` rather than in an interactive shell: the first version of
   the local test had not set `pipefail` and therefore passed.

### The flake loop

`flake` is the item the port's own notes rank first among the open ones, and the
only one they say explicitly does not carry over: *"the 550/550 flake result does
not carry over. It has to be re-run after modules land, against a kernel that has
actually loaded one."* Loading a module changes vmalloc usage and the guest's
address-space layout, which is exactly where the stub pages live.

Two things make this the loop that answers that rather than a loop that looks like
it does.

**The perturbation is inside a boot.** A module loaded in one UML process is gone
when that process exits, so a matrix that merely sits next to a module gate tests
two unrelated things and would report green either way.
`harness/guest/flake-init` loads the module first and then does the fork/exec at
volume, the FP torture, the multi-MB file mapping and the hostfs write *in the
same address space*, and unloads it after everything has run. It is in the matrix
every iteration; a sampled perturbation is not a perturbation. The loop also
refuses to run at all if it finds no `.ko`, because an empty set would be a green
loop that tested nothing.

**The criterion is the verdict, not the marker.** `loop.sh`'s criterion is the
marker string, and the marker is exactly the criterion that missed the rss leak --
a run that printed its marker was never scanned. `native.sh` scans for kernel
diagnostics independently and reports `verdict=BUG`, so a run with a defect in its
log cannot pass here even with its marker present. That difference is tested: a
kernel printing both its marker and a BUG line fails the loop.

The expensive rows are sampled, as in `loop.sh`: g4 spawns 2000 processes and fp
runs ~8500 verify iterations, and running both every pass would put the loop past
a day, which means it would not be run at all.

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
