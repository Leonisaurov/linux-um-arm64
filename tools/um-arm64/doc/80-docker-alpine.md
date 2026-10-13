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
directorio donde viven las piezas. Hace tres cosas:

1. **elige el kernel** con `config/docker.config` (busca `linux-um-docker` y
   después el glibc `linux`),
2. **elige la imagen** con Docker (`alpine.ext4` / `alpine-docker.ext4`), antes
   de la Alpine pelada, y
3. **apunta el kernel a la glibc de Termux** con `grun --configure` *solo si el
   kernel es glibc y el intérprete no existe*. En un kernel bionic estático
   `patchelf --print-interpreter` no imprime nada y el paso es un no-op.

Lo que **no** hace más es arrancar `dockerd`: eso pasó a `/umarm-init`
(`harness/guest/umarm-init-alpine`), que es el camino que también usa la app.
Antes el launcher inyectaba un `umalpine-docker.sh` por hostfs, y con un init
que también arranca el daemon los dos se pisaban (`rm -rf /run/docker` sobre un
daemon vivo). El init monta cgroup2, bootea openrc, arranca el servicio y
después corre el comando de `-c` o da la shell; el launcher solo escribe
`umalpine-hostname` y, si está, `umalpine-net.sh` en el share.

Igual que `umalpine.sh`, acepta `-c 'CMD'` para un comando y sin `-c` deja una
shell; `UMALPINE_MEM`, `UMALPINE_KERNEL`, `UMALPINE_IMAGE`, `UMALPINE_SHARE` y
`UMALPINE_DOCKER=1` funcionan igual. `UMALPINE_HOSTNAME` (default `umalpine`)
es el nombre del guest: sin él el prompt sale `(none):~#`, porque el hostname del
kernel es `CONFIG_DEFAULT_HOSTNAME` -- el default del árbol es el literal
`(none)` (`init/Kconfig`) -- hasta que alguien llama `sethostname(2)`, y esta
minirootfs no tiene init que lo haga. En Termux no hay `/bin/bash`, así que se
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
    echo 4 > /proc/sys/kernel/printk    # el KERN_INFO del bridge/veth, fuera
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
6. **La consola se come la salida de `docker run`.** El driver bridge y veth
   loguean cada cambio de estado de puerto en `KERN_INFO` ("docker0: port
   1(veth...) entered blocking state"), y la consola del guest imprime todo lo
   que esté ≥ `console_loglevel` (7 por defecto). Un `docker run alpine echo
   hello` queda enterrado en una docena de líneas del kernel. El bring-up
   escribe `echo 4 > /proc/sys/kernel/printk`: sube el umbral a `KERN_WARNING`,
   así que warnings, errores y BUGs siguen saliendo -- que es lo que escanean
   los gates -- y el INFO se calla.
7. **El shebang es `#!/bin/bash`.** Termux no tiene `/bin/bash` ni
   `/usr/bin/env`; se invoca con `bash alpine-um`. Es la misma convención que
   el resto del harness.
8. **El kernel glibc necesita `grun --configure`.** Sin eso, Termux no tiene
   `/lib/ld-linux-aarch64.so.1` y el kernel no arranca. El lanzador lo detecta
   con `patchelf --print-interpreter` y lo hace solo; con el bionic no pasa
   nada.

## Revisión de la lista de no verificados (2026-10-12)

Revisado en el teléfono con el kernel bionic, sobre la misma imagen. Dos de los
primeros intentos dieron "fallas" que eran del fixture y no de UM: el busybox
que trae la imagen `alpine` **no tiene el applet `httpd`** (`applet not found`),
así que el contenedor moría y `-p` respondía "connection refused". Con un
servidor que existe (`nc`) el resultado cambia. Todo lo de abajo se probó con
`nc` o con `nginx:alpine`, no con un fixture que no arranca.

| lo que estaba sin verificar | resultado |
| --- | --- |
| `nft` como binario | ✅ `nftables v1.1.1`, tablas `ip nat/filter` y `ip6 nat/filter` |
| `-p` / publicación de puertos | ✅ `0.0.0.0:8080->80/tcp`, `wget 127.0.0.1:8080` → `PORT_OK`, y la regla `DNAT` visible en `ip nat DOCKER` |
| red custom + contenedor↔contenedor | ✅ `by_ip=NET_OK` y `by_name=NET_OK`: el DNS embebido (127.0.0.11) resuelve el nombre |
| internet del contenedor | ✅ NAT `docker0` → `vec0` → passt |
| `--network host` | ✅ comparte el netns del guest y llega a `example.com` |
| `docker compose` | ✅ v2.31.0: bajó `nginx:alpine`, publicó `8081→80`, sirvió el HTML y `down` limpió red y contenedor |
| kernel de 4 KB bajo el lanzador | ✅ `getconf PAGESIZE=4096`, boot y red |
| `openrc`/`rc-service docker` | ✅ `rc-status` reporta `softlevel=boot` y `rc-service docker start/stop/restart` arrancan y frenan el daemon (`RCDOCKER ok server=27.3.1`); el detalle está abajo |
| host de 16 KB | ⚪ no testeable acá: el teléfono tiene páginas de 4 KB. Lo que sí corre es el guest de 16 KB sobre un host de 4 KB |

No hay kernel de 4 KB **con** `docker.config`: se construye sólo el de 16 KB
porque un guest de 16 KB bootea en hosts de 4 y de 16 KB, y una segunda copia
sólo agrega bytes al artifact. El de 4 KB que se probó es el `linux-um` de
default, es decir el camino sin Docker.

## User namespaces: no era el kernel, era la imagen

`docker.config` enciende `CONFIG_USER_NS=y`. En la imagen Alpine el
`unshare(CLONE_NEWUSER)` daba 0 y el `execve` siguiente fallaba `EACCES` sobre
un archivo `root:root 0755`, con o sin mapeo (`-U`, `-Ur`, `--map-root-user`), y
solo con `-U`: `unshare -m/-p/-n` seguidos de exec andaban. Eso se registró como
bug abierto de `arch/um`. **No lo es.**

La causa es la imagen. El minirootfs Alpine se había extraído como usuario sin
privilegios, así que `/bin`, `/lib`, `/usr`, `/etc` quedaron **del uid del que
extrajo y en modo 0700**, no `root:root 0755`. En el guest, root los atraviesa
gracias a `CAP_DAC_OVERRIDE`, y por eso todo funcionaba —menos dentro de un user
namespace—. Ahí no hay mapeo para ese uid del disco,
`capable_wrt_inode_uidgid()` falla, `generic_permission()` devuelve `EACCES`
sobre el directorio, y el `execve` siguiente muere con ese mismo `EACCES`. El
`execve` funciona sin el `unshare` porque fuera del namespace el root del guest
sí tiene el override. El archivo que se intentaba ejecutar (`/bin/busybox`) era
irrelevante: fallaba la travesía de `/bin`.

La prueba es de una línea, hecha en el teléfono. Antes:

    # ls -ld /bin
    drwx------ 2 10379 10379 /bin
    # unshare -Ur /bin/busybox echo hi
    unshare: can't execute '/bin/busybox': Permission denied

Después de `chown -R 0:0 /bin /lib /usr /etc` y `chmod 0755` en los directorios:

    # ls -ld /bin
    drwxr-xr-x 2 root root /bin
    # unshare -Ur /bin/busybox echo hi
    hi

Lo que lo hacía confuso es que la imagen que usa el gate `docker-prereqs` es la
Debian, construida con `debootstrap` como root, así que `unshare -U true` ahí
siempre anduvo: el control que debía aparecer estaba verde, y solo la Alpine
reproducía el fallo.

El arreglo, entonces, no toca `arch/um`:

* `harness/mkrootfs.sh` y `harness/mkdockerimage.sh` hacen `chown -R 0:0` del
  árbol y `chmod 0755` de los directorios antes de `mke2fs -d`. `mkinitramfs.sh`
  no lo necesita: su escritor newc pone uid/gid 0 por construcción.
* `harness/guest/userns-init` es el gate. Primero imprime la propiedad de la que
  depende el mecanismo, para que una regresión se nombre sola en vez de
  aparecer como `EACCES`; después hace `unshare -Ur`, ejecuta, chequea el uid
  adentro y repite con `-U`. En el kernel `default` (sin `CONFIG_USER_NS`) el
  veredicto es un skip con razón, no un pass.

Con la imagen corregida, rootless Docker y `--userns-remap` dejan de estar
bloqueados por esto; los contenedores comunes, que nunca lo necesitaron, siguen
andando igual.

## `rc-service docker`: openrc tiene que bootear el sistema

El síntoma era `rc-service docker start` → `docker is already starting` y un
`rc-service docker status` que decía que el sistema "no fue booteado por
openrc". La causa no era `supervise-daemon` ni el pidfile: la imagen traía
`/etc/runlevels/*` **vacíos** y no tenía `/etc/network/interfaces`.

El servicio declara `depend() { need sysfs cgroups net }`, y `net` lo provee
`networking`, que a su vez necesita `localmount` → `root`/`fsck`. Con los
runlevels vacíos nada de esa cadena estaba en un runlevel, así que `openrc
boot` no arrancaba nada y `rc-service docker start` no podía satisfacer `need
net` — de ahí el mensaje, que no nombra ni la cadena ni el archivo que faltaba.

`/umarm-init` (el de la imagen Alpine, `harness/guest/umarm-init-alpine`) ahora:

* monta `/run` como tmpfs (el minirootfs lo tiene como directorio real, y por
  eso los pidfiles sobrevivían al poweroff),
* monta cgroup v2,
* baja `printk` a 4 para callar el `KERN_INFO` de bridge/veth,
* crea `/etc/network/interfaces` con `auto lo` si no existe,
* hace `rc-update add` de `fsck root sysfs cgroups` en `sysinit`,
  `hostname localmount networking` en `boot` y `docker` en `default`,
* corre `openrc sysinit` y `openrc boot`,
* arranca docker por `rc-service docker start` (con `dockerd` directo como
  fallback si no hay openrc), y
* recién entonces da la shell o corre el comando de `-c`.

`harness/guest/rc-docker-init` es el gate: bootea los runlevels, para y arranca
el servicio, espera el socket, `docker info`, chequea `status: started`, para el
servicio y chequea `status: stopped`. Corre sobre `alpine-docker.ext4`, la
imagen que ahora construye `harness/mkdockerimage.sh` y que también es la que
empaqueta la app.

## Lo que sigue sin probar

* Un host de 16 KB (no hay uno a mano; el guest de 16 KB sobre 4 KB sí se probó).
* Más de una CPU: UML es uniprocesador, no hay `cpuset` que probar.
