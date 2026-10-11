# Pendiente 4 — el vDSO del guest: plan, y por qué la premisa del README es falsa

Estado: **plan escrito; la Fase 1a (corregir `README.md`) ya está hecha.** El gate
de la Fase 0 (medir la tasa del reloj del guest contra la del host) es lo que
falta. Evidencia: dos recons read-only del árbol y una investigación web; cada
afirmación lleva file:line o URL. La cita de la sección 0 está verificada: cruza
dos líneas en el README, así que un `grep` de una línea no la encuentra.

---

## 0. La premisa, tal como está escrita hoy

`README.md:81-83`:

> Guest vDSO time (`clock_gettime` without a host syscall) is **written but not
> merged**: it does not fit a 4 KB page and needs `GENERIC_VDSO_OVERFLOW_PROTECT`,
> without which guest time wraps after tens of minutes.

Tres afirmaciones. Las tres son verificables, y **las tres son falsas o
irrelevantes** para este árbol. Esto no es una opinión: es lo que sale de mirar.

---

## 1. "Written but not merged" — el código no existe

- `git branch -a` → `main`, `origin/main`, `upstream/um-arm64`. No hay rama, ni
  stash, ni patch con un vDSO de tiempo.
- `grep -rn __vdso_clock_gettime` → aparece en `arch/x86/um/vdso/um_vdso.c` y en
  `arch/arm64/kernel/vdso/` (el arm64 **nativo**). En `arch/arm64/um/` **no
  existe**.
- `arch/arm64/um/vdso/Makefile:6` → `vobjs-y := vdso-note.o sigreturn.o`. Sólo
  sigreturn.
- `arch/arm64/um/vdso/vdso.lds.S:63-67` exporta **únicamente**
  `__kernel_rt_sigreturn`.
- `arch/arm64/um/vdso/vdso.lds.S:5-9` dice, textualmente, que **no** exporta
  funciones de tiempo: *"a vDSO fast path would save nothing"*.

Es el mismo patrón que apareció toda la sesión: **el árbol describe algo que no
contiene** (`passt-bionic.patch`, `umarm-init`, `install.sh`, los `ci-*.sh`,
`device_filter.xml` — y ahora esto). El README no miente sobre el kernel
upstream: miente sobre *este* árbol.

## 2. "Needs `GENERIC_VDSO_OVERFLOW_PROTECT`" — protege algo que UML no puede tener

- Definido en `lib/vdso/Kconfig:15`; **el único selector en todo el árbol es
  `arch/x86/Kconfig:183`**. Ni arm64 nativo ni um lo seleccionan.
- Qué hace (commit `0c68458b0a5878d735572b4f4d91219a1db7c784`, Adrian Hunter,
  2024-03-25, tip/timers-core): *"add multiplication overflow protection to the
  VDSO time getter functions for the price of an extra conditional in the
  hotpath"*. Protege `delta*mult` del **fast path** cuando los timer interrupts
  se detienen. Añade `u64 max_cycles` a `struct vdso_clock`.
- El **fast path** es leer un clocksource desde una data page compartida **sin
  syscall**. En UML eso es imposible por construcción: el único reloj que el
  guest puede leer es el del **host**, y llegar a él cuesta un syscall. Por eso
  `vdso.lds.S:5-9` dice que no ahorraría nada — y por eso **x86 UML no lo
  intenta**: `arch/x86/um/vdso/um_vdso.c:16-54` es un **stub que ejecuta el
  syscall** (*"This vDSO turns all calls into a syscall so that UML can trap
  them"*), sin `vdso_data` ninguno.

  Sin data page no hay `delta*mult`, no hay `max_cycles`, y **no hay nada que
  proteger**. `GENERIC_VDSO_OVERFLOW_PROTECT` no es una dependencia de este
  port: es una dependencia de un diseño que UML no puede usar.

## 3. "Does not fit a 4 KB page" — eso lo decide el port, no el kernel

- El vDSO arm64 **nativo** no tiene límite de una página:
  `arch/arm64/kernel/vdso-wrap.S` alinea con `.balign PAGE_SIZE` y el kernel
  calcula `vdso_pages = (vdso_end - vdso_start) >> PAGE_SHIFT`; el vvar son 4
  páginas aparte (`__VDSO_PAGES`).
- El límite de **una** página es de este port: `arch/arm64/um/vdso/vma.c:38`
  (`BUG_ON(vdso_end - vdso_start > PAGE_SIZE)`) y `vma.c:44` (`task_size -
  PAGE_SIZE`), `vma.c:68`.
- Es una decisión razonable para un vDSO que sólo lleva sigreturn. Deja de serlo
  en cuanto se le quiera meter algo más — pero eso es un `BUG_ON` que se cambia,
  no una restricción del kernel.

## 4. "Guest time wraps after tens of minutes" — el reloj del guest es el del host

Esto es lo que decide el ítem, y es lo que nadie había medido:

- Clocksource del guest: `"timer"`, rating 300 — `arch/um/kernel/time.c:907-913`.
- `timer_read()` = `os_nsecs() / TIMER_MULTIPLIER` (256) —
  `arch/um/kernel/time.c:883-904`, `arch/um/include/linux/time-internal.h:13`.
- `os_nsecs()` = `clock_gettime(CLOCK_MONOTONIC)` **del host** —
  `arch/um/os-Linux/time.c:103-109`.
- Registrado como `clocksource_register_hz(..., 3.90625 MHz)` exacto —
  `arch/um/kernel/time.c:947`.

El guest **no deriva**: su reloj *es* el del host, dividido por 256. Y sin vDSO,
glibc cae al **syscall** (`lib/vdso/gettimeofday.c`:
`clock_mode == VDSO_CLOCKMODE_NONE` → `clock_gettime_fallback()`), que devuelve
ese mismo clocksource. **La ausencia de vDSO no puede causar un reloj malo: sólo
uno más lento.**

El único síntoma medido que hay en el árbol es otro, y ya está explicado ahí
mismo: `doc/80-performance.md:26-44` — una tabla donde el guest sale *más rápido*
que el nativo (`1.270 | 6.012 | 0.838` ns/iter) y el propio doc dice que **eso no
es un resultado** (*"the guest coming out faster than native is not a result"*),
por la frecuencia y el gobernador del teléfono (big.LITTLE 4×A55 1.80 GHz /
3×A77 2.42 / 1×A77 3.19, schedutil — `harness/phonebench.sh:5-13`). Es un
artefacto de medición, no un bug de kernel.

Y la sonda que lo habría zanjado — `harness/probe/clockcheck.c`, que compara la
tasa de `CLOCK_MONOTONIC` del guest contra la del host — **nunca corrió en el
guest**: su única invocación es `harness/faultcmp.sh:53-55`, del lado **nativo**,
y nada parsea su salida (`summarise` sólo lee `us/page`). No hay ningún doc con
su resultado. **Ese es el hueco real de este ítem, no el vDSO.**

---

## 5. El plan, entonces

### Fase 0 — medir (esto es el ítem 4, de verdad)

Cablear `clockcheck` a un **gate de guest**, que es donde nunca corrió:

- `harness/guest/clock-init`: corre `clockcheck` dentro del guest, y el harness
  corre **el mismo binario** fuera, sobre el mismo intervalo de reloj.
- Criterio: `mono_elapsed` del guest vs del host, dentro de una tolerancia
  declarada. El guest mide *su* `CLOCK_MONOTONIC`; el harness mide el del host.
  Si el reloj del guest es el del host — que es lo que dice la sección 4 — esto
  sale igual y **queda probado**, con el número en `result.txt`.
- **Control obligatorio** (la regla de la casa, la que salvó el ítem del rss):
  el mismo gate contra un kernel con el clocksource roto a propósito
  (`tools/um-arm64/config/control-*.patch`, como `control-ptrs-per-pte.patch`)
  tiene que **reproducir** la discrepancia. Un gate que no sabe fallar no prueba
  nada.
- Costo: bajo. Todo lo que hace falta existe; lo que falta es el cableado.

### Fase 1 — decidir el vDSO con la premisa corregida

Con la sección 2 en la mano, un vDSO de tiempo en UML sólo puede ser **stub de
syscall** (diseño x86). Su valor es **completitud de ABI**, no velocidad: hay
software que mira `AT_SYSINFO_EHDR` y los símbolos `__vdso_*`. Opciones, en
orden de lo que yo haría:

- **1a (recomendada primero, y es barata): corregir `README.md:81-83`.** Que diga
  lo que es cierto: el vDSO de este árbol exporta `__kernel_rt_sigreturn` y nada
  más; un vDSO de tiempo con fast path es imposible en UML porque el reloj es el
  del host; el stub de syscall es la única forma y su valor es ABI, no
  rendimiento; y `GENERIC_VDSO_OVERFLOW_PROTECT` no es una dependencia de este
  port. **Un README que describe código inexistente es el bug más barato de
  arreglar y el más caro de dejar.**
- **1b (si se quiere la ABI completa): el stub, ~1 página.** `vdso.S` con el
  syscall (patrón `arch/x86/um/vdso/um_vdso.c:16-54`), exports
  `__vdso_clock_gettime`/`__vdso_gettimeofday`/`__vdso_time` en `vdso.lds.S`, y
  un gate que verifique que el símbolo se resuelve **y que el tiempo sigue
  siendo correcto** (que es lo que la Fase 0 ya mide). Sin data page, sin
  `max_cycles`, sin overflow protect.
- **1c (descartada): data page con fast path.** Necesitaría que el guest lea un
  clocksource sin syscall, y el único reloj disponible es el del host. No hay
  camino: no es que sea difícil, es que el diseño no aplica.

### Fase 2 — dejar el ítem cerrado en la documentación

`doc/60-continuation.md` (la lista rankeada de próximos pasos) y `CI.md` no
mencionan vDSO ni tiempo en absoluto (`grep` verificado). El ítem 4 debería
quedar ahí con su estado real, igual que quedaron el rss y los módulos.

---

## 6. Riesgos y lo que puede salir mal

- **`clockcheck` puede no discriminar**: mide un intervalo de segundos con
  busy-spin, y en un guest UML el jitter del host puede tapar una discrepancia
  chica. Mitigación: intervalo largo (≥ 10 s), tolerancia declarada y no
  "ajustada hasta que pase", y el control de la Fase 0 como árbitro.
- **El síntoma puede ser real y no estar en el clocksource**: si la Fase 0
  muestra una discrepancia que el clocksource no explica, el sospechoso pasa a
  ser el tick (`timer_create(CLOCK_MONOTONIC, SIGEV_THREAD_ID, SIGALRM)` cada
  `NSEC_PER_SEC/HZ` = 10 ms con `CONFIG_HZ` sin definir → 100 —
  `arch/um/kernel/time.c:799,814`, `arch/um/Kconfig:119-121`) o
  `NO_HZ`/`HIGH_RES_TIMERS` (`arm64_defconfig:34-35`). **Eso sería un hallazgo
  mejor que el plan original**, y por eso la Fase 0 va primero.
- **No hay que confundir dos cosas distintas**: el vDSO (un hueco de ABI) y la
  tasa del reloj (que no depende de él). El README las mezcla; el plan no.
- **Costo de CI**: una fila más en `ci-flake.sh` y un gate en la matriz de boot
  — dentro de lo que ya hay. Si se hace 1b, un kernel más en el job `build`
  (5 → 6).

## 7. Resumen en una línea

El pendiente 4 no es "agregar el vDSO": es **medir la tasa del reloj del guest
por primera vez** (nunca se midió), y **corregir un README que describe código
que no existe y una dependencia que UML no puede usar**.
