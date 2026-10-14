# Pendientes

Lo que quedó abierto al 2026-10-13 en `linux-um-arm64`, después de dejar
`alpine-um` andando (Alpine + Docker + red en el teléfono). Los dos bugs que
esta lista tenía como abiertos están cerrados; abajo está el estado y lo que
realmente sigue sin probar. El detalle largo vive en `doc/80-docker-alpine.md`
(la guía de Docker) y `doc/60-continuation.md` (las notas del port).

- Repo: `/data/data/com.termux/files/home/Develop/Clones/linux-um-arm64`
  (rama `main`).
- La app Android (`dist/umapp`) es ahora una terminal real (el emulador de
  Termux, vendorizado). La imagen Alpine+Docker+openrc ya **no** va adentro: es
  un release de GitHub que la app busca y baja sola. Ver
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

## Cerrado: la imagen era un asset del APK

La imagen iba gzippeada adentro del APK (144 MB), y eso hacía 289 MB cada build
de la app y convertía al APK en la unidad de versionado de algo que no es suyo:
un arreglo de la imagen sólo llegaba al teléfono con una actualización de la app.
Ahora la imagen es un asset de un release de GitHub. Cuando cambia, el job
`publish` (sólo en `push` a `main`) crea un release
`rootfs-<fecha>-<run>-<attempt>` con `rootfs.ext4.gz` y `rootfs.json`, y no
publica nada si la receta del guest es la que ya está. La versión sale de la
receta y no de los bytes a propósito: el ext4 no es reproducible (`mke2fs` escribe
un UUID al azar, `install` estampa la hora), así que un md5 cambiaría en cada
corrida y le preguntaría a cada app instalada en cada push a `main`.

El *body* del release es el manifiesto
(`{"version":…,"md5":…,"size":…,"recipe":…}`), así que una sola consulta a la
API de releases le dice a la app cuál es la última imagen y con qué hash tiene
que coincidir. En cada arranque la app consulta,
compara el tag con el que guardó en `rootfs.version` y ofrece bajar sólo si
difieren. "Keep" recuerda esa versión, así que la pregunta se hace una vez por
imagen, y en Settings hay una entrada que vuelve a preguntar a propósito. La
descarga va al cache y a los files de la app: archivo temporal, chequeo de md5,
gunzip a `rootfs.ext4.new` y rename sobre `rootfs.ext4`, para que la imagen que
el guest está booteando nunca quede a medio escribir. Imagen nueva es instalación
nueva, así que se escribe el mismo marcador `first-run` y corre el asistente. Un
build puede seguir metiendo una imagen con `ROOTFS_GZ` para correr sin red, y
`ci-umapp.sh` acepta las dos formas.

Aparte de la imagen, el kernel. El APK quedaba en 153 MB porque `libuml.so` era
el kernel biónico **sin strip**, y 131 de sus 143 MB son
`.debug_info`/`.debug_loc`/`.debug_line` que ningún teléfono lee. El job `android`
les corre `llvm-strip --strip-debug` y `build-apk.sh` strippea la copia staged:
143 MB → 12 MB y el APK → **27 MB**. Verificado en el teléfono: el kernel
strippado (md5 `4e275e73…`) arranca el guest y pasa el gate `console` con
`kernel_bugs=0`, y es byte por byte el `libuml.so` que quedó en el APK.

El kernel no puede venir de un release como la imagen. El dominio `untrusted_app`
niega `execute` sobre los archivos de datos de la app — la misma regla W^X que
obliga a que `stub_exe` salga de `nativeLibraryDir` en vez de un memfd —, así que
un kernel bajado a `files/` se podría descargar y verificar y el exec fallaría
igual. Además el APK llevaba el kernel **equivocado**: `16k/linux-um` (el de
`arm64_defconfig`) en vez de `16k/linux-um-docker`, que es el que necesita
dockerd; el job `umapp` ahora instala el docker y compara el md5 de `libuml.so`
con el que construyó el job `android`.

## Cerrado: la app se actualiza sola, y la UI es un drawer

Faltaba lo simétrico a la imagen: que la app detecte que hay una versión nueva de
sí misma y la ofrezca. El job `publish-apk` sube el APK firmado a un release
`umarm-<receta>`, y la app lo consulta al arrancar, lo baja, verifica el md5 y se
lo pasa al instalador. La **receta** es lo que reemplaza al version code:
`build-apk.sh` hashea todo lo que entra en el APK (manifiesto, recursos,
fuentes, el jni, el initramfs y el md5 de cada binario, kernel incluido), y sus
doce dígitos hexadecimales van al manifiesto como `org.umarm.recipe` y a
`build/recipe`. El tag del release es esa receta, así que una corrida que no
cambió nada encuentra el tag y no publica, y una que cambió algo publica una vez;
nadie tiene que acordarse de subir un número.

Eso sólo funciona porque el build es reproducible donde importa, y dos cosas no
lo eran. Las dos salieron de construir el mismo commit dos veces y comparar, y de
comparar dos commits con el código del kernel idéntico:

- `mkinitramfs.sh` escribía `int(time.time())` en cada cabecera del cpio, así que
  el archivo cambiaba en cada corrida. El `gzip -9n` del final ya estaba por esa
  misma razón; el escritor de cpio era la mitad que faltaba. El mtime es constante
  ahora, y dos builds separados por segundos dan el mismo hash.
- `CONFIG_LOCALVERSION_AUTO`, que `init/Kconfig` trae en `y`, agrega el
  `git describe` del HEAD del repo vía `scripts/setlocalversion`. Este repositorio
  *es* el kernel, así que cada commit —incluso uno que no toca nada que el build
  lea— daba bytes distintos: el mismo código en dos commits dio `4f665eba…` y
  `66dddf9f…`. `build-bionic.sh` apaga el símbolo y fija un sufijo, así que los
  bytes del kernel que se envía siguen al código del kernel. Los glibc conservan
  el sufijo automático: no se envía ninguno, y saber qué commit corrió un gate
  vale tenerlo en su log.

`KBUILD_BUILD_TIMESTAMP` ya estaba fijo en el epoch con user y host fijos, así que
el tiempo del build nunca fue el problema: lo eran la identidad del repositorio y
la del archivo. Con los dos arreglados, un commit que sólo toca `ci.yml` reproduce
la misma receta y el mismo md5 de kernel, y el job de publicación encuentra el tag
que ya hizo.

Y algo que la comprobación de actualizaciones no puede tomar de la API: el orden
de sus releases. La documentación dice que `GET /releases` viene ordenado por
`created_at` descendente; lo que devolvió fue `umarm-ea5ba1424a6d` (13:50) y
`umarm-a83c8b925c82` (13:29) *arriba* de `umarm-7c974e3214bc` (14:07), que es
orden por nombre de tag. Tomar el primero le habría ofrecido a la app instalada un
*downgrade*, y se lo habría seguido ofreciendo. `fetchLatestRelease()` toma el
`published_at` máximo comparando los timestamps ISO como texto.

Instalar es la mitad incómoda: hace falta declarar `REQUEST_INSTALL_PACKAGES` y
que el usuario lo permita (el switch por app de Android 8, al que la app manda al
usuario en vez de fallar en silencio), y el APK tiene que llegar al instalador
como `content://` porque desde Android 7 un `file://` del storage privado tira
`FileUriExposedException`. `FileProvider` vive en androidx.core, que acá no está,
así que `ApkProvider` es esa parte escrita a mano: un nombre en el cache, sólo
lectura, no exportado, con el permiso de URI otorgado por intent.

La UI, además: se fueron la barra de botones de arriba y la tira de teclas de
abajo, y quedó un handle en una esquina con un drawer (imagen, app, teclas,
fuente, Settings). Las teclas no se perdieron: un `CTRL` latcheado sigue
valiendo para el próximo carácter del teclado blando.

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
descarga). Y `console` (kernel `docker`, imagen `alpine-docker.ext4`,
`init=/console-init`) chequea lo que rompió la consola: modos de `/etc/passwd`,
`doas` setuid, que un usuario nuevo se resuelva a sí mismo y que la tty de
consola se pueda tomar como controladora. El job `build` construye esa imagen y
la sube con el resto, y el job `publish` la publica como release (con el
`paths-ignore` de siempre, un commit de docs no republica nada).

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
