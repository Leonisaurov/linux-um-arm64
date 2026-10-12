# Docker dentro de un guest Alpine

Verificado el 2026-10-12 en Termux/Android aarch64 (host `pagesize 4096`,
uid 2000), Alpine 3.21.8, Docker 27.3.1, con el kernel bionic `linux-um-docker`
del artifact `um-arm64-android` (run del commit `375bc6f87`, md5
`7a7184064c0e9c808f8443f4f0de4561`) y la imagen `alpine.ext4` de
`~/Develop/um-rss/alpine-um/`.

## Resumen

Docker 27.3.1 corre en el guest y **`docker run --rm hello-world` hace el pull
desde Docker Hub** antes de correr. Eso último es nuevo: el kernel de docker de
CI no traía red (`CONFIG_UML_NET_VECTOR is not set`), así que `docker pull` no
podía bajar nada y el único camino era `docker load` desde el host.
`CONFIG_UML_NET_VECTOR` vive ahora en `config/docker.config` (commit
`73f191a5a`), y con eso el guest ve `vec0`, hace DHCP por umnet/passt y baja
imágenes de verdad. Todo lo demás del pipeline (dockerd, containerd, runc,
overlay2, cgroup v2, seccomp, namespaces, veth, bridge, nftables) ya era real.

El lanzador es `tools/um-arm64/alpine-um`, que es `harness/umalpine.sh` bajo ese
nombre: el nombre es el que activa el modo `--docker`. Ver §0.

## 0. El lanzador

    bash tools/um-arm64/harness/umalpine.sh --docker   # explícito
    bash alpine-um                                     # el nombre implica --docker

`alpine-um` es el mismo archivo que `umalpine.sh`, copiado con ese nombre en el
directorio donde viven las piezas. Hace las cuatro cosas que antes se hacían a
mano:

1. **elige el kernel** con `config/docker.config` (busca `linux-um-docker` y
   después el glibc `linux`),
2. **elige la imagen** con Docker (`alpine.ext4` / `alpine-docker.ext4`), antes
   de la Alpine pelada,
3. **monta cgroup2 y arranca `dockerd`** dentro del guest, borrando antes el
   estado de `/run/docker` y `/run/containerd` que deja un daemon matado
   (trampa 4), y
4. **apunta el kernel a la glibc de Termux** con `grun --configure` *solo si el
   kernel es glibc y el intérprete no existe*. En un kernel bionic estático
   `patchelf --print-interpreter` no imprime nada y el paso es un no-op.

Igual que `umalpine.sh`, acepta `-c 'CMD'` para un comando y sin `-c` deja una
shell; `UMALPINE_MEM`, `UMALPINE_KERNEL`, `UMALPINE_IMAGE`, `UMALPINE_SHARE` y
`UMALPINE_DOCKER=1` funcionan igual. En Termux no hay `/bin/bash`, así que se
invoca con `bash alpine-um`.

## 1. La imagen (el ext)

El minirootfs Alpine son 64 MB con ~7.9 MiB usados: no entra `apk add docker`.
La imagen quedó terminada así, sobre la de 16k que ya tenía `docker` en
`/etc/apk/world` de un intento anterior:

    cp ~/Develop/um-rss/16k/alpine.ext4 ~/Develop/um-rss/alpine-um/alpine.ext4
    truncate -s 1G ~/Develop/um-rss/alpine-um/alpine.ext4
    $PREFIX/glibc/bin/e2fsck -f -y ~/Develop/um-rss/alpine-um/alpine.ext4
    $PREFIX/glibc/bin/resize2fs ~/Develop/um-rss/alpine-um/alpine.ext4

`e2fsprogs-glibc` **sí** está en Termux, así que el resize se hace en el host,
sin montar ni bootear (la nota vieja de este archivo decía que no estaban;
`resize2fs` sigue sin estar en Alpine fuera de `e2fsprogs-extra`). Después, con
cualquier kernel que tenga red, se completa la instalación:

    apk update
    apk add docker

`docker` es el metapaquete y arrastra `docker-engine`, `docker-cli`,
`docker-cli-buildx`, `containerd`, `runc` e `iptables`. Desde un minirootfs
limpio son **242 MiB en 35 paquetes**; acá ya estaban los que un intento
anterior dejó, así que bajó 4 (`containerd`, `docker-engine`, `docker-cli`,
`docker-cli-buildx`, 239 MiB en 28 paquetes en total). Persiste en la imagen:
reboot y `docker --version` sigue contestando `27.3.1`.

`openrc` no hace falta y no hay `/etc/init.d/`: `dockerd` se arranca a mano (lo
hace el script inyectado, §3).

## 2. El kernel

Docker son features del kernel (namespaces, cgroup v2, overlayfs, veth, bridge,
nftables), no de la libc, así que el kernel tiene que venir de un build con
`tools/um-arm64/config/docker.config`. Hay dos publicados por CI, y la
diferencia es la libc **del proceso kernel**, no la del guest (el guest es musl
en los dos casos):

| artifact | archivo | libc | en Termux |
| --- | --- | --- | --- |
| `um-arm64-android` | `16k/linux-um-docker` | bionic, estático | corre directo, es lo que usa `alpine-um` |
| `um-arm64-boot-docker-prereqs` | `linux` | glibc, dinámico | necesita `grun --configure` (lo hace el lanzador) |

El job `android` construye el bionic con el mismo `EXTRA_CONFIG=config/docker.config`
que el gate `docker-prereqs` del job `build`; la única diferencia es el NDK. Por
eso el teléfono ya no depende de `glibc-runner` para correr contenedores. El
bionic se construye solo a 16 KB: una página de guest de 16 KB bootea en hosts
de 4 KB y de 16 KB (una página de guest es un `mmap()` del host, y un guest más
chico que el host cuelga), así que una segunda copia solo agregaría bytes al
artifact.

## 3. Levantar dockerd

Con las piezas en un directorio:

    mkdir -p ~/um/alpine-um && cd ~/um/alpine-um
    cp tools/um-arm64/harness/umalpine.sh alpine-um        # el nombre hace el modo
    cp .../um-arm64-android/16k/{linux-um-docker,stub_exe,umnet,passt} .
    cp ~/Develop/um-rss/alpine-um/alpine.ext4 .
    bash alpine-um -c 'docker run --rm hello-world'

Lo que el modo inyecta por hostfs (y que se puede leer en
`$UMALPINE_SHARE/umalpine-docker.sh`) es lo mismo que antes se tipeaba a mano:

    rm -rf /var/run/docker /var/run/containerd
    rm -f /var/run/docker.pid /var/run/docker.sock
    mkdir -p /sys/fs/cgroup
    mount -t cgroup2 none /sys/fs/cgroup
    dockerd > /var/log/dockerd.log 2>&1 &

El transcript del arranque, con el kernel bionic:

    umalpine: dockerd up (27.3.1)

    # docker info
    Server:
     Containers: 0
      Running: 0
      Paused: 0
      Stopped: 0
     Images: 0
     Server Version: 27.3.1
     Storage Driver: overlay2
      Backing Filesystem: extfs
      Supports d_type: true
      Native Overlay Diff: true
     Logging Driver: json-file
     Cgroup Driver: cgroupfs
     Cgroup Version: 2
     Security Options:
      seccomp
       Profile: builtin
      cgroupns
     Operating System: Alpine Linux v3.21
     Architecture: aarch64
     CPUs: 1
     Total Memory: 1010MiB
    WARNING: No swap limit support
    WARNING: No cpuset support

    # docker run --rm hello-world
    Unable to find image 'hello-world:latest' locally
    latest: Pulling from library/hello-world
    58dee6a49ef1: Pulling fs layer
    58dee6a49ef1: Verifying Checksum
    58dee6a49ef1: Download complete
    58dee6a49ef1: Pull complete

Ese `Pulling from library/hello-world` es la red del guest haciendo su trabajo:
el kernel tiene `vec0`, `udhcpc` pide el lease, y `dockerd` sale por el
`passt` del host como cualquier otro proceso del guest.

## Trampas

1. **El kernel de docker tiene que ser uno con `docker.config`.** El defconfig
   no trae cgroup v2, ni veth/bridge, ni nftables; `dockerd` muere en el setup
   de red o los containers no arrancan. Los nombres `linux-um-docker` (bionic)
   o `linux` del artifact de docker (glibc) son la señal.
2. **`resize2fs` no está en `e2fsprogs` en Alpine**, está en
   `e2fsprogs-extra`. En Termux sí está en `e2fsprogs-glibc` y se puede hacer
   en el host, sin bootear.
3. **La imagen de 64 MB no alcanza.** Docker son ~240 MB; sin resize,
   `apk add docker` muere con `No space left on device` y deja `docker` escrito
   en `/etc/apk/world` pero sin instalar.
4. **`/run` persiste en la imagen** (`/var/run` es un symlink a `/run`, y no es
   tmpfs). Después de un poweroff, el próximo `dockerd` falla con `failed to
   start daemon, ensure docker is not running or delete /var/run/docker.pid:
   process with PID N is still running`. Borrar sólo `docker.pid` y
   `docker.sock` **no alcanza**: el `containerd` gestionado guarda
   `/run/docker/containerd/containerd.pid` y falla antes, con `libcontainerd:
   failed to save daemon pid to disk: process with PID N is still running`,
   porque el PID del archivo viejo fue reusado por otro proceso. Hay que borrar
   los árboles `/run/docker` y `/run/containerd` enteros; son estado de runtime
   que `dockerd` recrea. Esto se descubrió en el segundo boot, no en el primero.
5. **Sin `mount -t cgroup2` no hay controllers.** El minirootfs no tiene init
   que lo monte; `docker info` sale con `Cgroup Version: 2` pero sin `cpu io
   memory pids` y los containers fallan al crear.
6. **El shebang es `#!/bin/bash`.** Termux no tiene `/bin/bash` ni
   `/usr/bin/env`; se invoca con `bash alpine-um`. Es la misma convención que
   el resto del harness.
7. **El kernel glibc necesita `grun --configure`.** Sin eso, Termux no tiene
   `/lib/ld-linux-aarch64.so.1` y el kernel no arranca. El lanzador lo detecta
   con `patchelf --print-interpreter` y lo hace solo; con el bionic no pasa
   nada.

## Lo que NO probé

* `docker compose`, rootless, más de una CPU, `--network host`/puertos,
  contenedores que hablen a la red o entre sí más allá de `hello-world`.
* `openrc`/`rc-service docker` y si existe un `docker-openrc`.
* El kernel de 4 KB bajo el lanzador (la imagen es la misma; lo que cambia es
  la página del guest) y un host de 16 KB.
* `nft` como binario (no instalado; `iptables v1.8.11 (nf_tables)` sí está).
