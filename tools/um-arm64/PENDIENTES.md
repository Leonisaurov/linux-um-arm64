# Pendientes

Lo que quedó abierto al 2026-10-13 en `linux-um-arm64`, después de dejar
`alpine-um` andando (Alpine + Docker + red en el teléfono). El detalle largo
está en `doc/80-docker-alpine.md` (la guía de Docker) y `doc/60-continuation.md`
(las notas de continuación del port); acá está lo accionable para una sesión
limpia.

- Repo: `/data/data/com.termux/files/home/Develop/Clones/linux-um-arm64`
  (rama `main`, al escribir esto en `0f2c023ab`, todo pusheado y CI verde).
- Para retomar: *"seguí con los pendientes de tools/um-arm64/PENDIENTES.md"*.

## 1. User namespaces rotos — bug abierto, es el importante

`CONFIG_USER_NS=y` está en `config/docker.config` (para rootless Docker y
`--userns-remap`), pero **no funciona**. Lo que lo hace un bug y no una
limitación conocida es que nada lo dice: el símbolo está, `unshare` da 0, y el
paso siguiente falla con un error que no nombra ni el kernel ni el userns.

**Reproducir desde el teléfono** (una línea, un boot):

    alpine-um -c 'unshare -U /bin/busybox true; echo rc=$?'

y con el rastro que lo aísla (el `strace` ya está instalado en la imagen actual,
ver "Entorno"):

    alpine-um -c 'strace -f -e trace=unshare,execve unshare -U /bin/busybox true'

**Evidencia**, dentro del guest:

    unshare: can't execute '/bin/busybox': Permission denied
    unshare(CLONE_NEWUSER)                                 = 0
    execve("/bin/busybox", ["/bin/busybox", "true"], ...)  = -1 EACCES (Permission denied)

- El binario es `root:root 0755`, el mismo `execve` funciona **sin** el
  `unshare`, y un path inexistente da `ENOENT`: se alcanza el exec y el `EACCES`
  lo da el kernel, no los bits de permiso.
- Falla igual con `-U`, `-Ur` y `--map-root-user`.
- Consecuencia: rootless Docker y `--userns-remap` no son usables. Los
  contenedores comunes (namespaces de red/PID/mount, sin userns) sí andan, que
  es todo lo que el launcher y el gate `docker-prereqs` necesitan.

**Dónde mirar:** `arch/um` **no** menciona userns en ningún lado, así que el
defecto es genérico. Un exec de un mm nuevo pasa por `init_new_context()` →
`start_userspace()` (`arch/um/kernel/skas/mmu.c`,
`arch/um/os-Linux/skas/process.c`), que arranca el stub con un `execve` del
*host*. Sospecha a confirmar: ese camino (el stub/exec del host, o el `bprm` con
`current_user_ns() != &init_user_ns`) devuelve `EACCES`. No es un permiso de
archivo.

**Plan de ataque** (en este orden):

1. **Escribir el gate que lo reproduce**, porque hoy no hay ninguno: un
   `harness/guest/userns-init` que haga `unshare -U`, ejecute algo y solo
   imprima su marcador si el exec vuelve a funcionar, más una fila en la matriz
   de `.github/workflows/ci.yml` (kernel `docker`). Hoy ese gate debe **fallar**;
   cuando el fix entre, debe pasar. Es la misma disciplina que el resto de los
   gates: sin un control que falle, un fix no prueba nada.
2. **Aislar el loader.** Compilar en el host un binario **estático**
   (`clang --target=aarch64-linux-gnu -static ...`) y pasarlo por el share;
   `unshare -U /host/static` dentro del guest. Si también falla, no es el
   `/lib/ld-musl-aarch64.so.1` de busybox, es el `execve` en sí.
3. **Control x86_64.** El port mantiene un control x86 UML para cambios
   genéricos de `arch/um/`. Construirlo y repetir: si x86 también falla, es un
   defecto de UML y no del subarch arm64, y el fix va en `arch/um/` o en el
   camino de stub compartido.
4. **Instrumentar, no teorizar.** `printk` en el camino de `execve`
   (`fs/exec.c`/`bprm_execve`) y en `init_new_context()`/`start_userspace()`
   para ver si el `EACCES` lo devuelve el guest antes de tocar el stub o si es
   el exec del host el que lo devuelve. El port ya se comió días por teorizar:
   primero el fallo exacto, después el fix.

**Criterio de terminado:** `alpine-um -c 'unshare -Ur /bin/busybox echo hi'`
imprime `hi`, y el gate del punto 1 pasa en los dos kernels (docker y default,
que no trae `USER_NS` — ahí el gate debe dar un skip con razón, no un pass).

## 2. `rc-service docker` no arranca el daemon

- `/etc/init.d/docker` existe, pero `rc-service docker start` dice
  `docker is already starting` y `rc-service docker status` queda en `stopped`;
  openrc avisa que el sistema "no fue booteado por openrc".
- `touch /run/openrc/softlevel`, limpiar `/run/openrc` y arrancar desde cero
  **no** alcanzan. `dockerd` a mano (lo que hace `alpine-um --docker`) sí
  funciona, así que no es bloqueante: el launcher no usa openrc.
- No se investigó la causa. El servicio usa `supervisor=supervise-daemon`; un
  primer sospechoso es que `supervise-daemon` necesite un sistema booteado por
  openrc, y que no haya forma de saltearlo sin `openrc` completo.

## Sin probar

- Un **host de 16 KB**: el teléfono tiene páginas de 4 KB. Lo que sí se probó es
  un guest de 16 KB sobre host de 4 KB (lo normal acá) y un guest de 4 KB. Para
  el host de 16 KB está la **Raspberry Pi 5 `magicjr`** que el port ya usa
  (ssh, 16 KB nativos, passwordless sudo, trabajo en `~/umarm`): ver
  `doc/60-continuation.md` §2b. No hay uno a mano en Termux.
- **Más de una CPU**: UML es uniprocesador (`CONFIG_SMP` off), así que no hay
  `cpuset` que probar; `docker info` avisa `No cpuset support`.
- La **causa raíz** del `EACCES` de userns (punto 1).

## CI

`.github/workflows/ci.yml` corre la matriz completa (~7-9 min) y **sólo se
dispara con cambios de código**: `push` y `pull_request` tienen `paths-ignore`
para `*.md`, `**/*.md`, `Documentation/**`, `LICENSES/**`, `COPYING`,
`CREDITS`, `MAINTAINERS` y `.mailmap`. Un commit que sólo toca esos archivos no
inicia ningún run (GitHub saltea sólo si *todos* los archivos cambiados están en
la lista). `schedule` y `workflow_dispatch` no llevan filtro y siempre corren,
así que el flake semanal queda igual. Si querés forzar los gates para un commit
de docs, ya no alcanza con pushear: usá `workflow_dispatch`.

Detalle que costó tiempo: `harness/umalpine.sh` en modo one-shot **bufferiza**
toda la salida del guest y la imprime recién cuando el kernel sale. Si el guest
se cuelga, no ves nada (ni el boot). Los scripts de la revisión escriben a
`/host/diagN.out` por eso; para depurar dentro del guest, hacé lo mismo.

## Entorno, para no rearmarlo

- Launcher: `~/.local/bin/alpine-um` (wrapper con shebang de Termux que ejecuta
  la copia del runtime por ruta absoluta) →
  `~/Develop/um-rss/alpine-um/alpine-um` (copia de `harness/umalpine.sh`).
  Uso: `alpine-um`, `alpine-um -c 'CMD'`, `UMALPINE_HOSTNAME=... alpine-um`.
- Piezas en `~/Develop/um-rss/alpine-um/`:
  - `alpine.ext4` — 1 GiB, Alpine 3.21.8, Docker 27.3.1, más lo que dejaron las
    pruebas de la revisión: paquetes `nftables`, `docker-cli-compose`, `openrc`,
    `strace`, e imágenes `hello-world`, `alpine`, `nginx:alpine`.
  - `linux-um-docker` — bionic, commit `375bc6f87`, md5
    `7a7184064c0e9c808f8443f4f0de4561`; `linux-um-docker.build.txt` al lado tiene
    el detalle. Más `umnet`, `passt`, `stub_exe`.
- **Si se pierde el kernel**: se baja del artifact `um-arm64-android` de un run
  verde (`16k/linux-um-docker`), o se reconstruye con `workflow_dispatch`
  (job `android`, `EXTRA_CONFIG=tools/um-arm64/config/docker.config`). Los
  kernels se construyen **sólo en CI**; no se compilan en el teléfono.
- **Si se pierde o ensucia la imagen**: se rehace con `doc/80-docker-alpine.md`
  §1 (crecer el ext y `apk add docker`), no hace falta CI.
- Scripts de la revisión: `~/Develop/um-rss/alpine-um/share/{tests,diag,diag2..diag7}.sh`,
  cada uno escribe a `/host/diagN.out`. Se corren con

      UMALPINE_SHARE=~/Develop/um-rss/alpine-um/share \
        ~/Develop/um-rss/alpine-um/alpine-um -c '. /host/diag7.sh'

  y después se lee el `.out` en el host (sobrevive si el guest cuelga). Ojo con
  `pkill -f 'linux-um'`: el patrón matchea la propia línea de comando; usar
  `ps -eo pid,comm` o el truco del bracket.
