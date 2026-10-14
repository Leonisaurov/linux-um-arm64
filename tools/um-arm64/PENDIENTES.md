# Pendientes

Lo que quedó abierto al 2026-10-13 en `linux-um-arm64`, después de dejar
`alpine-um` andando (Alpine + Docker + red en el teléfono). Los dos bugs que
esta lista tenía como abiertos están cerrados; abajo está el estado y lo que
realmente sigue sin probar. El detalle largo vive en `doc/80-docker-alpine.md`
(la guía de Docker) y `doc/60-continuation.md` (las notas del port).

- Repo: `/data/data/com.termux/files/home/Develop/Clones/linux-um-arm64`
  (rama `main`).
- La app Android (`dist/umapp`) es ahora una terminal real (el emulador de
  Termux, vendorizado) y lleva la imagen Alpine+Docker+openrc adentro; ver
  `dist/umapp/VENDORED-TERMUX.md` y `doc/70-android.md`.

## Cerrado: user namespaces

Durante un tiempo esto se registró como bug de `arch/um`: en la imagen Alpine
`unshare(CLONE_NEWUSER)` daba 0 y el `execve` siguiente fallaba `EACCES` sobre un
archivo `root:root 0755`, con `-U`, `-Ur` y `--map-root-user`. **No era el
kernel.**

La causa era la imagen. El minirootfs Alpine se había extraído como usuario sin
privilegios, así que `/bin`, `/lib`, `/usr` y `/etc` quedaron **del uid del que
extrajo y en modo 0700**. Root en el guest los atraviesa con
`CAP_DAC_OVERRIDE`, y por eso todo funcionaba salvo dentro de un user namespace:
ahí no hay mapeo para ese uid del disco, `capable_wrt_inode_uidgid()` falla y
`generic_permission()` devuelve `EACCES` sobre el directorio, que es el `EACCES`
del `execve`. El archivo ejecutado era lo de menos; fallaba la travesía de
`/bin`.

El control que confundía: el gate `docker-prereqs` corre sobre la imagen
**Debian**, construida con `debootstrap` como root, así que su `unshare -U true`
siempre anduvo. Solo la Alpine reproducía el fallo.

Arreglo y prueba:

- `harness/mkrootfs.sh` y `harness/mkdockerimage.sh` hacen `chown -R 0:0` del
  árbol y `chmod 0755` de los directorios antes de `mke2fs -d`.
- `harness/guest/userns-init` es el gate: imprime la propiedad de la que depende
  el mecanismo y después corre `unshare -Ur /bin/busybox ...` y `unshare -U`.
  En el kernel `default` (sin `CONFIG_USER_NS`) da un skip con razón.
- `alpine-um -c 'unshare -Ur /bin/busybox echo hi'` imprime `hi`. Verificado en
  el teléfono, y el gate verificado como `init=/userns-init`.

## Cerrado: `rc-service docker` no arrancaba el daemon

El síntoma (`docker is already starting`, "el sistema no fue booteado por
openrc") no era `supervise-daemon`: la imagen traía `/etc/runlevels/*` **vacíos**
y no tenía `/etc/network/interfaces`. El servicio declara
`need sysfs cgroups net`, y `net` sale de `networking` → `localmount` →
`root`/`fsck`; con los runlevels vacíos nada de esa cadena estaba en un runlevel.

`/umarm-init` (`harness/guest/umarm-init-alpine`) ahora monta `/run` como tmpfs y
cgroup v2, crea `/etc/network/interfaces`, llena los runlevels, corre
`openrc sysinit`, `openrc boot`, arranca docker por `rc-service docker start` (o
`dockerd` directo como fallback) y recién ahí da la shell o corre el comando.
`harness/guest/rc-docker-init` es el gate: `rc-service docker status/start/stop`
y `docker info`, con el daemon real. Verificado en el teléfono como
`init=/rc-docker-init` (`RCDOCKER ok server=27.3.1`).

## Cerrado: la consola no tenía tty, y no había usuario

La app daba shell en el guest, pero `sh` decía `can't access tty; job control
turned off` y `bash`, `cannot set terminal process group (-1): Not a tty`. No era
el pty de la app: `con0=fd:0,fd:1` deja `/dev/console` como fd 0, así que
`[ -t 0 ]` da verdadero, pero nada lo había hecho *terminal controladora* — PID 1
arranca en una sesión sin ninguna, y `open("/dev/tty")` falla. El init hacía
`setsid -w -c /bin/sh -l`, y el `setsid` de busybox de esta Alpine **no tiene
`-w`**: fallaba al instante, corría el `else` y la shell quedaba sin tty. Tampoco
hay `cttyhack`. Ahora el init abre una sesión nueva cuyo líder abre la tty de la
consola (`setsid` + `open("/dev/tty0")`): la primera tty que abre un líder de
sesión pasa a ser la controladora. Verificado en el teléfono: `tty` y
`readlink /proc/self/fd/0` dan `/dev/tty0`, y `sleep 30 & jobs` lista el trabajo.
`harness/guest/console-init` es el gate.

El mismo trabajo destapó un segundo problema de permisos: como el minirootfs se
extrae sin privilegios, `tar` aplica el umask del build (`--no-same-permissions`
es su default para no-root) y `/etc/passwd` y `/etc/group` quedan **0600**. Root
los lee por `CAP_DAC_OVERRIDE` y no se nota; un usuario no-root no, así que `id`
imprime `unknown ID 1000` y `login` se porta raro. `mkrootfs.sh` y
`mkdockerimage.sh` ahora extraen con `-p` y después hacen `chmod -R a+rX` (que
agrega lectura y ejecución sin borrar setuid ni el sticky de `/tmp`), y devuelven
`/etc/shadow` a 0640 y `/root` a 0700. La imagen además instala `doas` con
`permit nopass :wheel`, porque el minirootfs no trae busybox setuid y el usuario
no-root no tendría otra forma de llegar a root.

Y en el primer arranque de la app el guest ofrece crear ese usuario: la app
escribe `first-run` en su directorio de datos al descomprimir la imagen,
`umarm-init` lo convierte en un asistente (usuario, contraseña, contraseña de
root opcional), lo agrega a `wheel` y `docker`, lo recuerda en
`/var/lib/umarm/user` y de ahí en más entra como él. El marcador lo escribe la app
y lo borra el guest: el harness y los gates arrancan la imagen sin tocarla y como
root.

## Sin probar (resultados nulos, con razón)

- **Un host de 16 KB**: no hay uno a mano en Termux; la Raspberry Pi 5
  `magicjr` del port sirve para eso (ver `doc/60-continuation.md` §2b). Lo que sí
  se probó es un guest de 16 KB sobre host de 4 KB (lo normal acá) y un guest de
  4 KB.
- **Más de una CPU**: UML es uniprocesador (`CONFIG_SMP` off), así que no hay
  `cpuset` que probar; `docker info` avisa `No cpuset support`. No es algo
  pendiente de arreglar, es una propiedad de UML.

## CI

`.github/workflows/ci.yml` corre la matriz completa y **sólo se dispara con
cambios de código**: `push` y `pull_request` tienen `paths-ignore` para `*.md`,
`**/*.md`, `Documentation/**`, `LICENSES/**`, `COPYING`, `CREDITS`, `MAINTAINERS`
y `.mailmap`. `schedule` y `workflow_dispatch` no llevan filtro. Para forzar los
gates en un commit de docs, `workflow_dispatch`.

Dos filas nuevas en la matriz: `userns`/`userns-skip` (kernel `docker` y
`default`, imagen `alpine.ext4`) y `rc-docker` (kernel `docker`, imagen
`alpine-docker.ext4`, la que construye `mkdockerimage.sh` y que la app
empaqueta). Y `console` (kernel `docker`, imagen `alpine-docker.ext4`,
`init=/console-init`) chequea lo que rompió la consola: modos de `/etc/passwd`,
`doas` setuid, que un usuario nuevo se resuelva a sí mismo y que la tty de
consola se pueda tomar como controladora. El job `build` construye esa imagen y
la sube con el resto.

Detalle que costó tiempo: `harness/umalpine.sh` en modo one-shot **bufferiza**
toda la salida del guest y la imprime recién cuando el kernel sale. Si el guest
se cuelga, no ves nada (ni el boot). Los scripts de revisión escriben a
`/host/diagN.out` por eso; para depurar dentro del guest, hacé lo mismo.

## Entorno, para no rearmarlo

- Launcher: `~/.local/bin/alpine-um` (wrapper con shebang de Termux) →
  `~/Develop/um-rss/alpine-um/alpine-um` (copia de `harness/umalpine.sh`). Uso:
  `alpine-um`, `alpine-um -c 'CMD'`, `UMALPINE_HOSTNAME=... alpine-um`.
- Piezas en `~/Develop/um-rss/alpine-um/`:
  - `alpine.ext4` — 1 GiB, Alpine 3.21.8, Docker 27.3.1, openrc, con la imagen
    ya corregida (root-owned, `/umarm-init` Alpine, `rc-service docker` andando).
  - `linux-um-docker` — bionic, commit `375bc6f87`, md5
    `7a7184064c0e9c808f8443f4f0de4561`; `linux-um-docker.build.txt` al lado.
  - `umnet`, `passt`, `stub_exe`.
- **Si se pierde el kernel**: se baja del artifact `um-arm64-android` de un run
  verde (`16k/linux-um-docker`), o se reconstruye con `workflow_dispatch`.
- **Si se pierde o ensucia la imagen**: se rehace con `doc/80-docker-alpine.md`
  §1, o con `harness/mkdockerimage.sh` en un host aarch64 sin Android (el `apk`
  de Alpine muere con SIGSYS bajo el seccomp de Android).
- Para la app: se construye con `dist/umapp/build-apk.sh` y el `BT`/`ANDROID_JAR`
  de Termux (`$PREFIX/bin`, `$PREFIX/opt/android-sdk/platforms/android-*/android.jar`).
  Ojo con `pkill -f 'linux-um'`: el patrón matchea la propia línea de comando;
  usar `ps -eo pid,comm` o el truco del bracket.
