# Docker dentro de un guest Alpine

Verificado el 2026-10-11 en Termux/Android aarch64 (host `pagesize 4096`,
uid 2000) con el kernel `7.2.0-rc4-gac9d4a6a6ed5` del artifact
`um-arm64-boot-docker-prereqs` (run `38183050490`) y Alpine 3.21.4.

## Resumen

Docker 27.3.1 corre en el guest y `docker run --rm hello-world` imprime
`Hello from Docker!`. El kernel de docker que publica CI **no trae red**
(`CONFIG_UML_NET_VECTOR is not set`), así que `docker pull` no puede bajar la
imagen: se carga con `docker load` desde el host. Todo lo demás del pipeline
(dockerd, containerd, runc, overlay2, cgroup v2, seccomp, namespaces, veth,
bridge) es real y corre dentro del guest.

## 0. El wrapper

`tools/um-arm64/harness/umalpine.sh` tiene shebang `#!/bin/bash`, que en Termux
no existe: ejecutarlo directo da `bad interpreter: No such file or directory`.
Hay que llamarlo con `bash tools/um-arm64/harness/umalpine.sh ...`. Acepta
`UMALPINE_KERNEL`, `UMALPINE_IMAGE`, `UMALPINE_INIT`, `UMALPINE_MEM` (default
`512M`) y `UMALPINE_SHARE` (default `$TMPDIR/umalpine-share`), el directorio que
el guest ve como `/host`.

## 1. La imagen

`~/Develop/um-rss/16k/alpine.ext4` **no está limpia**: su `/etc/apk/world` ya
trae `docker e2fsprogs`, hay 30 MiB usados y `docker-cli` quedó a medio instalar
de un intento anterior (`apk` fallaba con `No space left on device`). Para
verificar la receta desde cero usé la de 4k, que sí está prístina (7.9 MiB
usados):

    cp ~/Develop/um-rss/4k/alpine.ext4 "$TMPDIR/alpine-docker.ext4"
    truncate -s 1G "$TMPDIR/alpine-docker.ext4"

En el host **no** hacen falta `e2fsck` ni `resize2fs`: Termux no los tiene. El
fs se agranda en línea dentro del guest. (`mke2fs.android` y `e2fsdroid` sí
existen, pero no se usaron.)

## 2. Instalar Docker (con cualquier kernel que tenga red)

Con el kernel bionic normal (`~/Develop/um-rss/16k/linux-um`), que es el que
trae `vec0`:

    apk update
    apk add e2fsprogs-extra     # resize2fs está en -extra, NO en e2fsprogs
    resize2fs /dev/ubda         # en línea, con el fs montado en /
    apk add docker

`resize2fs` sobre ext4 montado funciona:

    resize2fs 1.47.1 (20-May-2024)
    Filesystem at /dev/ubda is mounted on /; on-line resizing required
    old_desc_blocks = 1, new_desc_blocks = 1
    EXT4-fs (ubda): resizing filesystem from 16384 to 262144 blocks
    EXT4-fs (ubda): resized filesystem to 262144
    The filesystem on /dev/ubda is now 262144 (4k) blocks long.

y `df` pasa de 56.0M a `987.8M` (13.0M usados justo después del resize).

Nombres de paquetes: `docker` es el metapaquete y arrastra `docker-engine`,
`docker-cli`, `docker-cli-buildx`, `containerd`, `runc` e `iptables`
(`apk add docker` = **242 MiB en 35 paquetes**). Listar `docker-cli`,
`containerd` u `openrc` aparte es redundante. `openrc` no se usó y en la imagen
no existe `/etc/init.d/`: dockerd se arranca a mano.

Persistencia verificada: reboot y

    Docker version 27.3.1, build ce1223035ac3ab8922717092e63a184cf67b493d

(el `apk add` quedó escrito en la imagen).

## 3. El kernel de docker (glibc)

    gh run download 38183050490 -n um-arm64-boot-docker-prereqs -D art
    cp art/*/linux kernel-docker && chmod +x kernel-docker
    grun --configure ./kernel-docker

`grun --configure` (patchelf) deja:

    interpreter /data/data/com.termux/files/usr/glibc/lib/ld-linux-aarch64.so.1
    rpath       /data/data/com.termux/files/usr/glibc/lib

El ejecutable se llama `linux` (122.761.720 B); el artifact comprimido pesa
61.231.668 B.

## 4. dockerd + hello-world

Boot con `UMALPINE_KERNEL=$PWD/kernel-docker`,
`UMALPINE_IMAGE=$PWD/alpine-docker.ext4`, `UMALPINE_MEM=1024M` y
`UMALPINE_SHARE=$PWD/share` (con `hello-world.tar` dentro). Dentro del guest:

    rm -f /var/run/docker.pid /var/run/docker.sock   # trampa: /var/run no es tmpfs
    mkdir -p /sys/fs/cgroup
    mount -t cgroup2 none /sys/fs/cgroup
    dockerd > /var/log/dockerd.log 2>&1 &

### `docker info`

    Client:
     Version:    27.3.1
     Context:    default
     Debug Mode: false
     Plugins:
      buildx: Docker Buildx (Docker Inc.)
        Version:  v0.19.1
        Path:     /usr/libexec/docker/cli-plugins/docker-buildx

    Server:
     Containers: 0
      Running: 0
      Paused: 0
      Stopped: 0
     Images: 1
     Server Version: 27.3.1
     Storage Driver: overlay2
      Backing Filesystem: extfs
      Supports d_type: true
      Using metacopy: false
      Native Overlay Diff: true
      userxattr: false
     Logging Driver: json-file
     Cgroup Driver: cgroupfs
     Cgroup Version: 2
     Plugins:
      Volume: local
      Network: bridge host ipvlan macvlan null overlay
      Log: awslogs fluentd gcplogs gelf journald json-file local splunk syslog
     Swarm: inactive
     Runtimes: io.containerd.runc.v2 runc
     Default Runtime: runc
     Init Binary: docker-init
     containerd version: 207ad711eabd375a01713109a8a197d197ff6542
     runc version: 7cb363254b69e10320360b63fb73e0ffb5da7bf2
     init version:
     Security Options:
      seccomp
       Profile: builtin
      cgroupns
     Kernel Version: 7.2.0-rc4-gac9d4a6a6ed5
     Operating System: Alpine Linux v3.21
     OSType: linux
     Architecture: aarch64
     CPUs: 1
     Total Memory: 1010MiB
     Name: (none)
     ID: 50c6f6dc-80b5-47b4-b833-b14349b444d7
     Docker Root Dir: /var/lib/docker
     Debug Mode: false
     Experimental: false
     Insecure Registries:
      127.0.0.0/8
     Live Restore Enabled: false

    WARNING: No swap limit support
    WARNING: No cpuset support

### La imagen llega por `docker load`, no por `docker pull`

Los bytes son una descarga real de Docker Hub, pero hecha en el host (API de
registry: config 592 B + layer 3149 B, empaquetados en un `docker save` de
20.480 B) porque el guest no tiene red:

    # docker load < /host/hello-world.tar
    f8975ecc6f0e: Loading layer  7.168kB/7.168kB
    Loaded image: hello-world:latest

    # docker images
    REPOSITORY    TAG       IMAGE ID       CREATED        SIZE
    hello-world   latest    eb84fdc6f2a3   6 months ago   5.2kB

    # docker run --rm hello-world

    Hello from Docker!
    This message shows that your installation appears to be working correctly.

    To generate this message, Docker took the following steps:
     1. The Docker client contacted the Docker daemon.
     2. The Docker daemon pulled the "hello-world" image from the Docker Hub.
        (arm64v8)
     3. The Docker daemon created a new container from that image which runs the
        executable that produces the output you are currently reading.
     4. The Docker daemon streamed that output to the Docker client, which sent it
        to your terminal.

    To try something more ambitious, you can run an Ubuntu container with:
     $ docker run -it ubuntu bash

    Share images, automate workflows, and more with a free Docker ID:
     https://hub.docker.com/

    For more examples and ideas, visit:
     https://docs.docker.com/get-started/

### Por qué no hay `docker pull`

El kernel de docker del artifact se construye con `ci-build.sh` a partir de
`arch/um/configs/arm64_defconfig` + `config/docker.config`, y ese defconfig no
activa el driver vectorial. Solo `build-bionic.sh` hace `-e UML_NET_VECTOR`
(para el kernel de Android). Consecuencias medidas:

* boot log: `Unknown kernel command line parameters
  "vec0:transport=fd,fd=3,mac=02:00:00:00:00:01", will be passed to user space.`
* `zcat /proc/config.gz | grep UML_NET_VECTOR` → `# CONFIG_UML_NET_VECTOR is not set`
* `/proc/net/dev` solo tiene `lo`, `dummy0`, `sit0`
* `docker pull hello-world` →

      Using default tag: latest
      Error response from daemon: Get "https://registry-1.docker.io/v2/": dial tcp: lookup registry-1.docker.io on 1.1.1.1:53: dial udp 1.1.1.1:53: connect: network is unreachable

Para un `docker pull` real hace falta un kernel con `config/docker.config` **y**
`CONFIG_UML_NET_VECTOR=y` (p. ej. agregar el símbolo a `docker.config`, o
construir el kernel bionic con `EXTRA_CONFIG=config/docker.config`). No se
compiló ninguno; en Termux no se compilan kernels.

## Tamaños reales

| pieza | tamaño |
| --- | --- |
| artifact `um-arm64-boot-docker-prereqs` | 61.231.668 B (~58 MiB) comprimido |
| kernel `linux` (y copia parcheada) | 122.761.720 B (~117 MiB) |
| `alpine.ext4` original | 67.108.864 B (64 MiB) |
| `alpine-docker.ext4` tras `truncate` | 1.073.741.824 B (1 GiB); 285 MiB en disco (`du`) |
| guest, después de todo | `987.8M` total, **247.2M usados**, 703.5M libres |
| `apk add docker` | 242 MiB en 35 paquetes |
| imagen `hello-world` | 5.2 kB (`docker images`); tar `docker save` 20.480 B |

## Trampas

1. **La imagen de 16k ya estaba sucia.** World con `docker` y `e2fsprogs`,
   30 MiB usados, `docker-cli` a medias. Usar una limpia o hacer `apk fix` antes.
2. **`resize2fs` no está en `e2fsprogs`.** En Alpine vive en
   `e2fsprogs-extra`. Sin él, `apk add docker` muere con
   `No space left on device`.
3. **Hay que resize antes de instalar docker.** El fs de 64 MiB tiene ~43 MiB
   libres; docker necesita 242 MiB. `resize2fs /dev/ubda` funciona en línea, no
   hace falta desmontar ni tocar el host.
4. **`openrc` es innecesario.** No hay `/etc/init.d/`; `dockerd` a mano alcanza.
   El paquete `docker` ya arrastra `containerd`, `runc` e `iptables`
   (`iptables v1.8.11 (nf_tables)`); el binario `nft` no está instalado y no
   hizo falta.
5. **El kernel de docker no tiene NIC** (ver arriba). Un `docker pull` en el
   guest es imposible con este artifact.
6. **`/var/run` persiste en la imagen.** Después de un poweroff, el próximo
   `dockerd` falla con `failed to start daemon, ensure docker is not running or
   delete /var/run/docker.pid: process with PID 87 is still running`. Hay que
   borrar `/var/run/docker.pid` y `/var/run/docker.sock` antes de arrancar.
7. **El shebang del wrapper** (`#!/bin/bash`) no existe en Termux; invocarlo con
   `bash`.

## Lo que NO probé

* `docker pull` real desde el guest (bloqueado por el kernel, ver arriba).
* Compilar un kernel `docker.config` + `UML_NET_VECTOR` (no se compilan kernels
  acá).
* `openrc`/`rc-service docker` y si existe un `docker-openrc`.
* `docker compose`, rootless, más de una CPU, `--network host`/puertos,
  contenedores que hablen a la red o entre sí más allá de `hello-world`.
* Reiniciar `dockerd` sin limpiar `docker.pid` (sí es la trampa 6, pero no busqué
  si `dockerd` tiene una opción para evitarlo).
* El kernel de 4 KB bajo el wrapper.
* La imagen de 16k sucia de punta a punta (solo se inspeccionó).
* `nft` como binario (no instalado).
