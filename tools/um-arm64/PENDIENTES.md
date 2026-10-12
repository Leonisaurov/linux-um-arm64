# Pendientes

Lo que quedó abierto al 2026-10-12, después de dejar `alpine-um` andando (Alpine
+ Docker + red en el teléfono). El detalle largo está en
`doc/80-docker-alpine.md` y `doc/60-continuation.md`; acá está lo accionable.

Para retomar: *"seguí con los pendientes de tools/um-arm64/PENDIENTES.md"*.

## No funciona / hallazgos

### 1. User namespaces rotos — bug abierto, es el importante

- `CONFIG_USER_NS=y` está en `config/docker.config` (para rootless Docker y
  `--userns-remap`), pero **no funciona**.
- Reproducción, dentro del guest de `alpine-um`:

      # unshare -U /bin/busybox true
      unshare: can't execute '/bin/busybox': Permission denied

- `strace` lo aísla:

      unshare(CLONE_NEWUSER)                                 = 0
      execve("/bin/busybox", ["/bin/busybox", "true"], ...)  = -1 EACCES (Permission denied)

- El binario es `root:root 0755`, el mismo `execve` funciona **sin** el
  `unshare`, y un path inexistente da `ENOENT`: se alcanza el exec y el `EACCES`
  lo da el kernel, no los bits de permiso. Falla igual con `-U`, `-Ur` y
  `--map-root-user`.
- Consecuencia: rootless Docker y `--userns-remap` no son usables. Los
  contenedores comunes (namespaces de red/PID/mount, sin userns) sí andan.
- Por dónde empezar: `arch/um` **no** menciona userns en ningún lado, así que es
  genérico. Un exec de mm nuevo pasa por `init_new_context()` →
  `start_userspace()` (`arch/um/kernel/skas/mmu.c`,
  `arch/um/os-Linux/skas/process.c`), que arranca el stub con un `execve` del
  *host*. Sospecha: ese camino (stub/exec del host, o `bprm` bajo un userns no
  inicial) devuelve `EACCES`. No es un permiso de archivo ni el fixture.

### 2. `rc-service docker` no arranca el daemon

- `/etc/init.d/docker` existe, pero `rc-service docker start` dice
  `docker is already starting` y `rc-service docker status` queda en `stopped`;
  openrc avisa que el sistema "no fue booteado por openrc".
- `touch /run/openrc/softlevel` y limpiar `/run/openrc` **no** alcanzan.
- `dockerd` a mano (lo que hace `alpine-um --docker`) sí funciona, así que no es
  bloqueante. No se investigó la causa.

## Sin probar

- Un **host de 16 KB**: el teléfono tiene páginas de 4 KB. Lo que sí se probó es
  un guest de 16 KB sobre host de 4 KB, y un guest de 4 KB.
- **Más de una CPU**: UML es uniprocesador; no hay `cpuset` que probar.
- La **causa raíz** del `EACCES` de userns (punto 1).

## Entorno, para no rearmarlo

- Launcher: `~/.local/bin/alpine-um` (wrapper con shebang de Termux) →
  `~/Develop/um-rss/alpine-um/alpine-um` (copia de `harness/umalpine.sh`).
- Piezas en `~/Develop/um-rss/alpine-um/`:
  - `alpine.ext4` (1 GiB, Alpine 3.21.8 con Docker 27.3.1 y las imágenes de las
    pruebas: `hello-world`, `alpine`, `nginx:alpine`).
  - `linux-um-docker` (bionic, commit `375bc6f87`, md5
    `7a7184064c0e9c808f8443f4f0de4561`), `umnet`, `passt`, `stub_exe`.
- Scripts de la revisión: `~/Develop/um-rss/alpine-um/share/{tests,diag,diag2..diag7}.sh`,
  se corren con
  `UMALPINE_SHARE=$PWD/share ./alpine-um -c '. /host/diagN.sh'`
  (escriben progreso a `/host/diagN.out` por si el guest cuelga).
- Los kernels se construyen **sólo en CI** (job `android`, salida
  `16k/linux-um-docker`); no se compilan en el teléfono.
