# El disco de datos del guest

La imagen del guest se reemplaza entera cuando hay un arreglo del rootfs. Hasta
este cambio eso arrastraba `/home` y las imágenes de docker: el diálogo de
actualización de la app lo decía con todas las letras. Ahora el guest tiene
**dos discos**, la base reemplazable y los datos que no se tocan.

## El contrato

| | |
| --- | --- |
| `ubd0` → `/dev/ubda` | la imagen base (`rootfs.ext4`), la que cambia una actualización |
| `ubd1` → `/dev/ubdb` | el disco de datos (`data.ext4`), el mismo archivo siempre |

El guest monta `/dev/ubdb` en `/data` y bind-montea:

| directorio | por qué |
| --- | --- |
| `/home` | los archivos del usuario |
| `/var/lib/docker` | imágenes, contenedores, volúmenes, containerd |
| `/var/lib/umarm` | el registro `/var/lib/umarm/user` de que el asistente ya corrió |
| `/root` | los archivos de la cuenta root |

Nada más. `/etc`, `/usr` y `/lib` son de la base y se reemplazan con ella, que es
el punto: un arreglo del sistema llega con la imagen nueva mientras estos cuatro
directorios quedan. **El precio**: un `apk add` deja el paquete en la base, así
que los paquetes instalados a mano *no* sobreviven a una actualización de imagen.
Tampoco `/etc` (un `daemon.json`, por ejemplo). Lo que el usuario hizo — sus
archivos y sus contenedores — sí.

## El lado del guest: `umarm-data.sh`

`harness/guest/umarm-data.sh`, llamado por `umarm-init-alpine` ni bien monta
`/dev`, antes de la red, de openrc, de dockerd y del asistente. Sin `ubd1` en la
línea de comandos —el harness sin `UMALPINE_DATA`, y todos los gates que no piden
disco de datos— es un no-op, así que llamarlo siempre no cambia nada.

1. **Formatea** el disco la primera vez. No usa `dumpe2fs` para decidir si ya hay
   filesystem: en Alpine `mkfs.ext4` está en `e2fsprogs` pero `dumpe2fs` en
   `e2fsprogs-extra`, y con `dumpe2fs` ausente el test diría siempre "no hay
   filesystem", cada arranque parecería el primero y `mkfs` correría **encima de
   un disco bueno**. La decisión es la magia del superblock ext (dos bytes en el
   offset `0x438`, `0xEF53` little-endian), que no necesita más que `dd` y `od`.
   El único disco que llega a `mkfs` es uno sin superblock.
2. **Siembra** el disco nuevo una sola vez, copiando lo que la base ya tenía en
   esos cuatro lugares. Es la transición desde el esquema de un solo disco: no se
   pierde nada. Después nunca más.
3. **Bind-montea** los cuatro directorios y arregla el modo de `/var/lib/docker`
   (`0710 root:docker`, que es lo que `checkpath -o root:docker` de openrc
   espera).

El gate es `harness/guest/data-init`, en la matriz de CI como `data`: formatea un
disco nuevo, verifica que los cuatro caminos estén sobre `ubdb`, comprueba que la
siembra sobrevivió al bind, escribe en los directorios del usuario, desmonta y
vuelve a montar —que es el próximo arranque— y lee lo que escribió.

## El lado de la app

- **Creación**: `ensureGuestData()` crea `data.ext4` como archivo *sparse* de
  2 GiB en `getFilesDir()`. Nada lo formatea de este lado (no puede: no hay
  `mkfs` en la app); lo formatea el guest en el primer arranque.
- **Boot**: `boot()` agrega `ubd1=<data.ext4>` a la línea de comandos del kernel.
  Si el archivo no se puede crear, el guest arranca igual y sus datos quedan en
  la base, como antes.
- **Actualización**: `installImage()` sólo reemplaza `rootfs.ext4`. `data.ext4`
  es otro archivo y la actualización no lo toca.
- **Copia de seguridad**: el drawer tiene una sección **Data** con
  `Back up guest data`, `Restore guest data`, `Export a backup…` e
  `Import a backup…`. Un backup es un gzip del disco de datos (un ext4 casi vacío
  comprime en unos pocos MB) en
  `getExternalFilesDir(null)/backups/`, que se puede sacar del teléfono por USB;
  `Export`/`Import` usan el selector de documentos, así que una copia puede vivir
  fuera de la app y sobrevivir a desinstalarla. Se guardan los 3 últimos.
- **Antes de actualizar**: el botón `Reinstall` del diálogo de imagen escribe un
  backup automático (`data-before-<versión>.ext4.gz`) *antes* de instalar; el
  diálogo tiene además un botón `Back up first` para hacerlo a mano antes de
  decidir. El backup es una segunda línea de defensa: el disco de datos ya
  sobrevive por ser otro archivo.

Los backups exigen el guest apagado, igual que la instalación de imagen: el
archivo estaría cambiando debajo.

## La transición desde el esquema de un solo disco

Una instalación vieja tiene todo adentro de `rootfs.ext4`. La primera
actualización que trae este cambio reemplaza esa base **antes** de que exista un
disco de datos, así que en ese único salto todavía se pierde `/home` y el
asistente vuelve a correr una vez: cuando el guest formatea el disco nuevo, ya no
queda nada viejo que sembrar. De ahí en adelante la base se reemplaza sin tocar
nada. No hay migración automática de la instalación vieja porque el disco de
datos *es* la migración; hacer que además rescue el rootfs anterior exigiría
adjuntarlo como un tercer disco y copiarlo, y el caso es uno solo por
dispositivo.

## Verificado

En Termux, con el kernel biónico de docker y una copia de la imagen, dos
arranques reales de la misma corrida:

    arranque A (ubd0=scratch.ext4, disco de datos NUEVO)
      umarm-data: formatting /dev/ubdb as ext4
      /home/keep.txt        = hello-from-boot-A
      /var/lib/docker/keep  = pulled-image
      /var/lib/umarm/user   = alice
      /etc/base-rev         = base-A          (base)

    se reemplaza la imagen base por scratchB.ext4

    arranque B (ubd0=scratchB.ext4, MISMO disco de datos)
      umarm-data: /dev/ubdb already carries a filesystem; keeping it
      home=hello-from-boot-A docker=pulled-image wizard=alice base-rev=gone
      WIZARD_WOULD_SKIP

Es decir: `/home`, `/var/lib/docker` y el registro del asistente sobrevivieron al
reemplazo de la base; lo que estaba sólo en la base (`/etc/base-rev`) se fue con
ella; y el asistente no vuelve a correr. El disco quedó comprobado además con
`debugfs` desde el host. El gate `data` de CI pasa en la misma corrida
(`UMARM_VERDICT=PASS`).

Lo que **no** está verificado en un dispositivo: la UI del APK (Back up, Restore,
Export, Import) y un arranque real de la app con el disco de datos. El APK
compila, `harness/ci-umapp.sh` comprueba que las cadenas estén en el dex y que
la firma y el manifiesto sigan bien, y el camino del guest es el mismo que sí se
verificó acá -- pero la primera corrida en el teléfono queda pendiente, anotada
en `PENDIENTES.md`, «Sin probar».
