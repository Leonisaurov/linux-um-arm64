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
| `build` | `ubuntu-24.04-arm` | `ci-build.sh` builds `ARCH=um SUBARCH=arm64 LLVM=1` and emits the kernel, the freestanding `stub_exe`, and the exact `.config`; `mkinitramfs.sh` builds the gate-2 fixture |
| `boot` (matrix) | `ubuntu-24.04-arm` | downloads the artifact and runs `native.sh` for each userspace mode |

The fixture is `harness/probe/guestinit.c` as `/init`: a freestanding aarch64
binary with its own `_start`, raw `svc #0` calls, one guest capability per line.
It prints `UMARM_GUEST_OK` and powers the machine off. No busybox, no libc, no
root filesystem, so there is nothing for the gate to fail on except the kernel.
The newc archive is written by an inline Python writer -- `cpio` is not
installed on Termux and is an avoidable moving part.

### The gate matrix

| gate | `EXTRA_ARGS` | path exercised |
| --- | --- | --- |
| `default` | *(none)* | the built-in default: ptrace userspace with `PTRACE_SYSEMU` |
| `seccomp` | `seccomp=on` | the seccomp fast path; `on` makes a non-functional seccomp a fatal error rather than a silent fallback |
| `nosysemu` | `nosysemu` | `PTRACE_SYSCALL` plus a `NT_ARM_SYSTEM_CALL` cancellation, i.e. what a pre-5.3 arm64 host (a 4.19 Android kernel) does |

The boot log names the mode, so the gate is checkable rather than assumed
(`arch/um/os-Linux/start_up.c`):

```
default   Userspace mode: ptrace      + Checking syscall emulation for ptrace...OK
seccomp   Userspace mode: SECCOMP
nosysemu  Userspace mode: ptrace      + Checking syscall emulation...skipped (nosysemu)
```

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
   with "This run likely failed because of a workflow file issue".

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

The next gate worth adding is **gate 3**: a real ext4 root filesystem from
`ubd0`. It needs no root to build -- `mkfs.ext4 -d <dir> image.ext4 <size>`
populates the image from a directory -- so CI can build one from an
`alpine-minirootfs` tarball and boot it with `UBD0=<image> root=/dev/ubda`.
That exercises the guest VFS, `fork`/`exec` and the block device, none of which
the initramfs gate touches.

`harness/loop.sh` lists the full gate matrix the port used
(`g2mini g2alpine g3 g5 g3noaslr g4 fp fpnoaslr`) with the markers and init
scripts each one needs. Those init scripts and the rootfs images lived in the
original repository outside the kernel tree and are not part of this snapshot;
the `guestinit` fixture replaces `g2mini` and is the only one that needs no
rootfs. Everything else has to be recreated as the Alpine image above.
