# umdebian — Debian on an Android phone, no root

A Debian bookworm userspace running on a Linux 7.2 kernel, on a phone, as an
ordinary unprivileged process. Not a container and not a VM: the kernel is
`ARCH=um SUBARCH=arm64` — User Mode Linux built for aarch64 — so it is a single
statically linked executable that runs under whatever uid you already have.

Nothing is installed on Android. No root, no `/dev/kvm`, no kernel modules, no
new mounts, no `CLONE_NEWUSER`. Deleting the directory removes it completely.

## Install

    ./install.sh

Pushes three files to `/data/local/tmp/umdebian`: the kernel, the Debian image
(~1.4 GB on disk, gzipped in transit), and the launcher -- plus `stub_exe` when
you have one next to the kernel, which on a phone you do need (see the notes).
Then it runs one command on the device and checks the answer, because three
successful `adb push`es are not evidence that anything boots.

    KERNEL=./linux-um-16k ./install.sh                # which kernel to ship
    NO_COMPRESS=1 ./install.sh                        # push the image raw
    ADB="adb -s 1A2B3C" DEST=/sdcard/umdebian ./install.sh

The guest page size comes from the kernel's file name (`-4k` / `-16k`, how the
builds are published) or from `GUEST_PAGESIZE`. It is not guessed, because the
failure mode is a hang rather than an error, and `install.sh` refuses to install
a guest page size below the device's host page size. Get the `-16k` build unless
you know the device is 4 KiB: it runs on both.

## Use

    adb shell
    cd /data/local/tmp/umdebian

    ./deb                    # interactive Debian shell
    ./deb uname -a           # run one command and print its output
    ./deb apt list --installed
    ./deb -v uname -a        # same, but show the kernel boot log too

Interactive mode needs a terminal, so run `adb shell` first and then `./deb`.
`adb shell ./deb` with no terminal will tell you so rather than appearing to
hang — UML takes its console from stdin, and a stdin that cannot be polled
leaves you with a booted guest whose output goes nowhere.

Files you put in `share/` appear inside the guest as `/host`, and it is
writable both ways.

## What works

An ordinary Debian userspace: `bash`, `dpkg`, `apt` (offline operations),
`perl`, the usual coreutils, and **gcc 12.2** — which compiles and runs
programs inside the guest:

    $ ./deb "gcc -O2 -o /tmp/hello /host/hello.c && /tmp/hello"
    compiled by gcc inside the guest, running on Linux aarch64
    6 * 7 = 42

209 packages installed, roughly 680 MB free in the image for more. `uname -m`
says `aarch64`. Exit status propagates, so `./deb false` returns 1 and the
launcher composes with the Android shell like any other command.

`python3` is **not** in this image — it is a base system plus a toolchain, not a
full desktop install. There is no network, so it cannot be apt-installed here
either; add it to the image before packaging if you want it.

There is **no network** and **no systemd**. PID 1 is `/umarm-init`, a small
shell script (`tools/um-arm64/harness/guest/umarm-init`, installed into the image
by `mkrootfs.sh`): it mounts `/proc`, `/sys`, `/dev`, `/dev/pts` and a tmpfs on
`/tmp`, mounts the share from the `umarm.share=` kernel argument with hostfs, and
then either runs the launcher's command or gives a login shell. Shutdown goes
through `/umarm-poweroff` rather than `poweroff -f`, because this image has no
init system at all and that binary may simply not be present -- and PID 1 exiting
is not a shutdown: under `panic=-1` the kernel hangs instead, which the launcher
cannot tell from a guest still working.

`/umarm-init` traps the signals busybox sends an init (`reboot` sends SIGTERM,
`poweroff` SIGUSR2, `halt` SIGUSR1 -- it only signals PID 1 unless passed `-f`)
and runs `/umarm-poweroff` or its sibling `/umarm-reboot`, so a `reboot` typed in
the guest does something instead of killing PID 1 and wedging the boot. A UML
reboot is a re-exec of the kernel binary, so that guest comes back from scratch.

## Notes

* Guest RAM defaults to 1 GB; override with `UMDEB_MEM=2048M ./deb`.
* Guest memory is backed by a file in `/tmp` when that is a writable tmpfs,
  which keeps it out of flash. The launcher falls back to its own directory.
* The kernel here is built for **4 KiB** pages. A guest page is a host `mmap`,
  so it cannot be smaller than the host's page size; on a 16 KiB-page device
  (some Android 15+ hardware) use the 16 KiB build instead. `install.sh` checks
  and refuses rather than leaving you with a hang.
* Exiting the shell powers the kernel down and returns you to Android.
* **`stub_exe`.** UML normally writes its stub into a memfd and `execveat()`s it,
  and an Android shell or app domain refuses that: the kernel then exits having
  printed nothing at all, which reads like a broken kernel and is not. Executing
  a *file* in your own data directory is allowed, so when a `stub_exe` sits next
  to the kernel the launcher passes it automatically and `install.sh` pushes it.
* Guest networking is on by default and is two extra processes: `umnet`
  reframes between UML's vector transport and `passt`, a userspace TCP/IP stack.
  Neither needs root, a tap device or a user namespace. Set `UMDEB_NET=0` to run
  without either, which also makes the launcher's return a little earlier.

## Why this works at all on an old phone

The host kernel here is 4.19. Two things had to be fixed for that, both of them
general rather than Android-specific: `PTRACE_SYSEMU` does not exist on arm64
before 5.3, so the kernel builds the same behaviour out of `PTRACE_SYSCALL` plus
a syscall cancellation; and the guest's address-space limit computed to zero on
a host with a 39-bit virtual address space, which is what most 4 KiB-page arm64
kernels ship. See `doc/70-android.md`.
