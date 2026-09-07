# GPS_INS — firmware ArduPilot para la placa SBY_GPS_INS

Firmware de la placa **SBY GPS G3.1** de SBY Technologies, construido sobre
**ArduPilot Rover**.

Este repositorio **no contiene ArduPilot**. Contiene solo lo que SBY añade —unas
2.100 líneas— y los scripts que descargan ArduPilot, le aplican esos cambios y
compilan. De ahí que ocupe 540 KB en lugar de 2 GB.

---

## Binarios

Cada [release](https://github.com/CarlosEGMWar/GPS_INS/releases) publica los tres
formatos de grabación. Los tres contienen el mismo firmware:

| Fichero | Herramienta |
|---|---|
| `ardurover_with_bl.hex` | ST-LINK / SWD |
| `ardurover_with_bl.bin` | DFU por USB, o cable serie |
| `ardurover.apj` | Mission Planner o `uploader.py`, por USB **o por USART1** |
| `SBY_GPS_INS-vX.Y.Z.zip` | los tres, más `manifest.json` y `COMO_GRABAR.txt` |

Comandos y direcciones: [sección 10](#10-qué-sale-en-dist-y-cómo-se-graba).

---

## 1. Qué es la placa

Controladora GPS/INS: fusiona un receptor GNSS con dos unidades inerciales y emite
una solución de posición y actitud.

| | |
|---|---|
| **Microcontrolador** | STM32F413RHT3 (ARM Cortex-M4, 1,5 MB de flash) |
| **GNSS** | Septentrio mosaic-G5, en NMEA |
| **IMU primaria** | Analog Devices ADIS16467, por SPI |
| **IMU secundaria** | Bosch BMI088, por I2C |
| **No incorpora** | brújula, barómetro ni salidas PWM |

### Qué añade este firmware a ArduPilot

1. **Salida NMEA propietaria** por USART1, con `$GNGGA` y `$PASHR`
   **alimentados por el EKF**, no por el GPS crudo. La posición procede de la
   solución fusionada GNSS+IMU, y el `$PASHR` transporta la actitud y los estados
   del filtro de Kalman. Es la razón de ser del producto.
2. **Comando `$GO_BOOT`**, que conmuta el micro al bootloader de fábrica para
   reprogramarlo por cable serie sin acceder físicamente a la placa.
3. **Soporte del ADIS16467**, que ArduPilot no reconoce.
4. **Correcciones del STM32F413** en USB y DMA, sin las cuales la placa no
   arranca.

> Pinout completo en
> [`docs/GPS_G3_1_Conexiones_GPIO.xlsx`](docs/GPS_G3_1_Conexiones_GPIO.xlsx).
> La configuración que usa el firmware está en
> [`hwdef.dat`](overlay/libraries/AP_HAL_ChibiOS/hwdef/SBY_GPS_INS/hwdef.dat),
> documentada en el [README de la placa](overlay/libraries/AP_HAL_ChibiOS/hwdef/SBY_GPS_INS/README.md).

---

## 2. La idea: overlay + parches

ArduPilot es un proyecto ajeno en evolución constante. Para no quedar anclados a
una versión ni perder los cambios propios, estos se mantienen **por separado** y se
reaplican en cada compilación.

Los cambios son de **dos tipos**, con tratamiento distinto:

```
ARCHIVOS NUEVOS            ->  overlay/   ->  se COPIAN
  no existen en ArduPilot                     no pueden dar conflicto:
                                              nadie mas los toca

ARCHIVOS DE ARDUPILOT      ->  patches/   ->  se APLICAN
  archivos suyos que                          aqui es donde puede haber
  el firmware edita                           conflicto al actualizar
```

**Criterio para ubicar un cambio nuevo:** si el archivo ya existe en ArduPilot, va
como parche; si no existe, va en `overlay/`.

Consecuencia práctica: `$GNGGA`, `$PASHR` y `$GO_BOOT` están contenidos por
completo en el driver propio, luego viven en `overlay/` y **nunca dan conflicto**.
Solo 59 líneas repartidas en 7 parches tocan código de ArduPilot.

---

## 3. Estructura de carpetas

| Carpeta | Contenido | Versionada |
|---|---|---|
| `UPSTREAM` | Versión exacta de ArduPilot sobre la que se construye | Sí |
| `overlay/` | Archivos propios: driver, definición de placa, bootloader | Sí |
| `patches/` | Los 7 parches a ArduPilot, con su documentación | Sí |
| `docs/` | Pinout, especificaciones y guía de Windows. Fuera del build | Sí |
| `scripts/` | Herramientas: preparar, compilar, actualizar, verificar, publicar | Sí |
| `build/ardupilot/` | ArduPilot descargado. **Desechable**, se regenera | No |
| `dist/` | Binarios listos para grabar | No |

Detalle de `overlay/`, donde reside el producto:

```
overlay/
  libraries/AP_NMEA_SBY_INS/                 driver propio
      AP_NMEA_SBY_INS.cpp                       genera $GNGGA y $PASHR, atiende $GO_BOOT
      AP_NMEA_SBY_INS.h
      AP_NMEA_SBY_INS_config.h
      PATCH_NOTES.md                            notas de integracion
  libraries/AP_HAL_ChibiOS/hwdef/SBY_GPS_INS/   definicion de la placa
      hwdef.dat                                 pines, puertos serie, IMUs, LEDs
      hwdef-bl.dat                              idem para el bootloader
      defaults.parm                             parametros de fabrica
      README.md, LEDS.md                        documentacion
  Tools/bootloaders/SBY_GPS_INS_bl.bin        bootloader ya compilado
  Tools/scripts/sby_release.py                empaqueta los 3 formatos de grabacion
```

> **`build/ardupilot/` es desechable por diseño.** Los scripts la resetean y la
> reconstruyen. Los cambios hechos ahí que no se trasladen a `overlay/` o a
> `patches/` se pierden. El estado válido reside siempre en esas dos carpetas.

---

## 4. Requisitos

Requiere **Linux, WSL o macOS**. Los scripts son bash POSIX, sin dependencias
específicas de plataforma.

| Sistema | Estado |
|---|---|
| Linux x86_64 | **Verificado.** Cada push compila desde cero en Ubuntu 24.04 |
| WSL 2 sobre Windows | **Verificado.** Entorno de desarrollo (Ubuntu 22.04) |
| macOS | Sin verificar. El código lo contempla y el toolchain `mac` existe |
| Linux ARM (Raspberry, etc.) | Sin verificar. Ídem con `aarch64-linux` |
| **Windows nativo** (cmd/PowerShell) | **No soportado.** waf requiere POSIX |

Las dos primeras filas no son una estimación: la primera la ejecuta GitHub Actions
en una máquina limpia en cada push, y produce un binario **idéntico byte a byte** al
compilado en la segunda. Las dos marcadas como sin verificar son deducciones: el
código contempla esos casos, pero no se han ejecutado.

> Que Windows nativo no sirva no es una limitación de este proyecto: el instalador
> oficial de ArduPilot para Windows instala Cygwin, que es otra capa POSIX.

### Compilación desde Windows

La vía es **WSL**. El procedimiento completo, desde un Windows sin preparar hasta
obtener `dist/`, está en un documento aparte:

**[Compilar en Windows, desde cero](docs/COMPILAR_EN_WINDOWS.md)**

Incluye el acceso a los binarios desde el Explorador y un método para obtener el
firmware de un cambio sin instalar nada, compilándolo en GitHub.

### Dependencias previas

Solo **`git`**, **`python3`**, **`binutils`** (para `strings`), **`tar`** y
**`bzip2`**, presentes de serie en la mayoría de las distribuciones. El compilador
ARM, ArduPilot y las dependencias de Python los descargan los scripts: ver
[sección 5](#5-instalación).

`preparar.sh` **no invoca `apt` ni `sudo`**: instala con `pip --user` y descomprime
el compilador en `~/opt`. Por eso es independiente de la distribución —Ubuntu,
Fedora, Arch— y no requiere permisos de administrador.

---

## 5. Instalación

Dos comandos. No hay que descargar ArduPilot ni instalar el compilador a mano: los
scripts detectan qué falta y lo resuelven.

```bash
git clone https://github.com/CarlosEGMWar/GPS_INS.git
cd GPS_INS
./scripts/compilar.sh
```

La primera ejecución descarga unos **2,4 GB**. Informa del progreso:

```
== Falta parte del entorno: preparandolo

== Descargando ArduPilot (~880 MB, solo esta vez)
   version: Rover-4.7.1
== Descargando 11 submodulos (~460 MB, ChibiOS es el grueso)
== Instalando dependencias de Python (con pip --user)
== Descargando el compilador ARM (~150 MB, solo esta vez)
   gcc-arm-none-eabi-10-2020-q4-major  para  x86_64-linux
Entorno listo.

== 3. compilando SBY_GPS_INS
...
```

Las ejecuciones siguientes no descargan nada y compilan en ~90 s.

### Entorno y árbol: dos cosas distintas

Conviene separarlas desde el principio, porque los scripts las tratan de forma
independiente:

| | Entorno | Árbol |
|---|---|---|
| Qué es | ArduPilot descargado, submódulos, compilador ARM, dependencias de Python | El contenido concreto de `build/ardupilot/`: overlay copiado, parches aplicados, ediciones locales |
| Dónde vive | `build/ardupilot/`, `~/opt`, `pip --user` | `build/ardupilot/` |
| Se monta | una vez | en cada ciclo |

**Todos los scripts garantizan el entorno.** `compilar.sh`, `actualizar.sh` y
`publicar.sh` llaman a `comprobar_entorno`, que ejecuta `preparar.sh` únicamente si
detecta que falta algo. No hay que prepararlo a mano ni acordarse de hacerlo.

Lo que los diferencia es **el trato al árbol**:

| Script | Entorno | Árbol |
|---|---|---|
| `compilar.sh` | lo garantiza | **lo respeta**: no resetea, no reaplica parches |
| `actualizar.sh` | lo garantiza | **lo resetea**: ArduPilot virgen + overlay + los 7 parches |
| `preparar.sh` | lo monta | no lo toca |

Por eso `preparar.sh` **no es un paso previo obligatorio**. Es el punto de entrada
explícito para descargar los 2,4 GB por adelantado sin compilar todavía:

```bash
./scripts/preparar.sh
```

Es idempotente: puede ejecutarse las veces que haga falta, solo actúa sobre lo que
falte.

### Qué instala y dónde

| Componente | Ubicación | Tamaño |
|---|---|---|
| ArduPilot, en la versión de `UPSTREAM` | `build/ardupilot/` | ~880 MB |
| Submódulos (ChibiOS, mavlink…) | `build/ardupilot/modules/` | ~460 MB |
| `empy`, `pymavlink`, `intelhex`, `future` | `pip --user` | pequeño |
| Compilador ARM | `~/opt/gcc-arm-none-eabi-*/` | ~150 MB |

Nada de esto escribe en directorios del sistema ni requiere `sudo`.

### Uso de un compilador propio

Si el sistema ya provee `arm-none-eabi-gcc`, los scripts lo usan y no descargan
nada. También admite una ruta explícita:

```bash
export ARM_TOOLCHAIN=/ruta/a/gcc-arm-none-eabi/bin
```

Instalación por gestor de paquetes:

```bash
sudo apt install gcc-arm-none-eabi binutils      # Debian / Ubuntu
sudo dnf install arm-none-eabi-gcc-cs binutils   # Fedora
brew install --cask gcc-arm-embedded             # macOS
```

> ArduPilot recomienda la versión **10-2020-q4-major**, que es la que descargan los
> scripts. Versiones muy distintas pueden generar avisos o alterar el tamaño del
> binario.

---

## 6. Los comandos

Cinco. En el día a día se usa uno.

| Comando | Función |
|---|---|
| `compilar.sh` | **uso diario**: compila el estado actual |
| `actualizar.sh` | reconstrucción desde cero y cambio de versión |
| `publicar.sh` | publicar una release |
| `preparar.sh` | montar el entorno (lo invocan los otros) |
| `verificar.sh` | comprobar el binario (lo invocan los otros) |

### `./scripts/compilar.sh` — uso diario

Compila el estado actual y deja los binarios en `dist/`. **No resetea el árbol**, de
modo que respeta el trabajo en curso dentro de `build/ardupilot/`. El entorno sí lo
garantiza, como todos los demás.

El tiempo depende de qué se haya modificado:

| Modificado | Recompila | Tiempo |
|---|---|---|
| Nada | 0 archivos | ~85 s |
| Un `.cpp` | ese archivo | ~90 s |
| `hwdef.dat` o `defaults.parm` | ~1044 archivos | ~10 min |

`hwdef.dat` es costoso porque regenera un cabecero del que depende medio ArduPilot.

Opciones: `--sin-overlay` (no sincronizar `overlay/`, útil al editar esos archivos
directamente en el árbol) y `--sin-dist` (compilar sin empaquetar).

### `./scripts/actualizar.sh` — reconstrucción desde cero

Deja ArduPilot virgen, copia el overlay, aplica los 7 parches en orden, compila y
verifica. Es la vía para obtener un resultado limpio y reproducible.

> **Aviso:** descarta cualquier edición no guardada en `build/ardupilot/`.

### `./scripts/publicar.sh` — publicar una release

Publicar es un acto deliberado y separado de compilar: **nada se publica de forma
automática**, ni al commitear ni al compilar.

```bash
./scripts/publicar.sh --ensayo     # verifica todo sin publicar
./scripts/publicar.sh              # propone la versión siguiente
./scripts/publicar.sh v1.2.0       # publica esa
```

Antes de actuar comprueba: rama `main`, árbol limpio, commit ya presente en GitHub
y etiqueta libre. Después muestra el contenido de la publicación y exige escribir
la versión como confirmación.

**El binario no se construye en local.** El script empuja la etiqueta; a partir de
ahí GitHub Actions compila en una máquina limpia y publica la release, y el script
sigue la ejecución hasta devolver la URL. El motivo es la reproducibilidad: un
binario construido en una máquina de desarrollo arrastra el estado de esa máquina.
Compilando fuera, cualquiera puede reconstruir byte a byte lo publicado.

Requiere un token de GitHub con permiso de escritura, configurado una vez en
`.publicar.env` (incluido en `.gitignore`):

```
token=ghp_...
```

o, para no duplicar el secreto si ya existe en otro archivo:

```
token_en=/ruta/a/ese/archivo.env
```

### `./scripts/preparar.sh` — montar el entorno

Descarga ArduPilot, sus submódulos, las dependencias de Python y el compilador ARM,
**solo lo que falte**. Los demás scripts lo invocan al detectar que algo no está,
por lo que rara vez hace falta llamarlo directamente. Ver
[Entorno y árbol](#entorno-y-árbol-dos-cosas-distintas).

### `./scripts/verificar.sh` — comprobar el binario

Busca las cadenas propias dentro del firmware compilado. Se ejecuta al final de
`compilar.sh` y `actualizar.sh`, y aborta el proceso si falta alguna. Ver
[sección 9](#9-la-comprobación-que-no-hay-que-saltarse).

---

## 7. Actualizar a una versión nueva de ArduPilot

```bash
./scripts/actualizar.sh --buscar          # listar releases disponibles
./scripts/actualizar.sh Rover-4.7.2       # cambiar a esa
```

Descarga esa versión, la deja virgen, reaplica el overlay y los 7 parches, compila
y verifica. Si el proceso termina bien, actualiza el archivo `UPSTREAM` para dejar
constancia de la versión base.

**Si un parche no aplica**, el proceso se detiene e indica cuál, en qué archivo y
cómo proceder. Los parches anteriores quedan aplicados. Ocurre cuando ArduPilot ha
movido el código parcheado, y la resolución es manual: ninguna herramienta puede
decidirla. El procedimiento está en [`patches/README.md`](patches/README.md).

El cambio de versión es **manual y explícito**. El script nunca salta de versión por
su cuenta, de forma que compilar hoy y dentro de un año produzca el mismo binario.

---

## 8. Los 7 parches, uno por uno

Es **todo** lo que este firmware modifica de ArduPilot: **59 líneas en 11 archivos**.
Cada `.patch` incluye su propia justificación sobre el cambio.

### `0001` — registrar el protocolo serie

**Archivos:** `libraries/AP_SerialManager/AP_SerialManager.h` y `.cpp`

Da de alta el protocolo número **100** con el nombre `NMEA_SBY_INS`. Sin él no es
posible asignar `SERIAL1_PROTOCOL=100` para activar la salida propia. El `.cpp`
añade el nombre a la lista que muestra Mission Planner.

### `0002` — enchufar la librería al vehículo

**Archivos:** `libraries/AP_Vehicle/AP_Vehicle.h` y `.cpp`

**El más crítico de los siete.** Hace tres cosas: instancia el objeto, registra su
parámetro `SBYN_RATE_MS` y **programa su ejecución a 50 Hz**.

Sin la última línea el firmware compila y arranca con normalidad, pero el código
propio **no se ejecuta nunca**: sin salida NMEA, sin `$GO_BOOT` y sin LEDs, y sin
ningún mensaje de error. De ahí la existencia de `verificar.sh`.

### `0003` — incluir la librería en la compilación

**Archivo:** `Tools/ardupilotwaf/ardupilotwaf.py`

Una línea. ArduPilot compila una lista fija de librerías, no todo lo que encuentra.
Su ausencia produce un error de enlazado, evidente de inmediato.

### `0004` — leer la antigüedad de las correcciones RTK

**Archivos:** `libraries/AP_GPS/AP_GPS.h`, `AP_GPS_NMEA.cpp`, `AP_GPS_NMEA.h`

El receptor publica en su GGA la antigüedad en segundos de las correcciones RTK
recibidas. ArduPilot descarta ese campo; el parche lo conserva para reemitirlo en la
salida propia.

Es el único **opcional**: sin él todo funciona, con ese campo vacío.

### `0005` — reconocer la IMU ADIS16467

**Archivo:** `libraries/AP_InertialSensor/AP_InertialSensor_ADIS1647x.cpp`

ArduPilot soporta los modelos 16470, 16477 y 16507, pero no el 16467 que monta la
placa. Sin el parche **la IMU primaria no se detecta** y la placa arranca solo con
la BMI088.

### `0006` — correcciones del STM32F413

**Archivo:** `libraries/AP_HAL_ChibiOS/hwdef/scripts/STM32F413xx.py`

Dos correcciones al generador de configuración de ArduPilot para este micro:
habilitar el USB (la base de datos del F413 usa un nombre que el generador no
reconoce) y corregir una opción de DMA que rompe el bus I2C de la BMI088.

Sin ellas no compila.

### `0007` — identificador de placa y bootloader

**Archivos:** `Tools/AP_Bootloader/board_types.txt` y `bl_protocol.cpp`

Registra el identificador `AP_HW_SBY_GPS_INS`. **Necesario para compilar el
firmware**, no solo el bootloader: la compilación lee ese archivo para traducir el
nombre a número.

El cambio en `bl_protocol.cpp` solo afecta a quien recompile el bootloader.

---

## 9. La comprobación que no hay que saltarse

Según lo descrito en el `0002`, existe un modo de fallo en el que el firmware queda
**roto pero aparentemente correcto**: compila, enlaza, arranca y no ejecuta nada del
código propio.

Por eso, tras cada compilación se buscan las cadenas propias dentro del binario:

```bash
strings -n 6 build/ardupilot/build/SBY_GPS_INS/bin/ardurover.bin \
    | grep -E 'GNGGA|PASHR|GO_BOOT'
```

Si no aparecen las tres, la librería no entró. `verificar.sh` lo automatiza y aborta
el proceso. **No debe grabarse una placa con un firmware que no pase esta
comprobación.**

---

## 10. Qué sale en `dist/` y cómo se graba

Tres formatos, para las tres vías de programación:

| Fichero | Herramienta | Dirección |
|---|---|---|
| `ardurover_with_bl.hex` | ST-LINK / SWD | contenida en el fichero |
| `ardurover_with_bl.bin` | DFU por USB, y cable serie tras `$GO_BOOT` | `0x08000000` |
| `ardurover.apj` | Mission Planner o `uploader.py`, por USB o USART1 | implícita |
| `manifest.json` | — | huellas SHA-256 y tamaños |

Los tres contienen el mismo firmware. El empaquetador lo verifica antes de
escribirlos: descomprime el `.apj`, parsea el `.hex` y aborta sin generar nada si
algo no coincide.

```bash
# ST-LINK / SWD  (produccion; graba bootloader + aplicacion)
STM32_Programmer_CLI -c port=SWD mode=UR -w dist/ardurover_with_bl.hex -v -rst

# DFU  (recuperacion; BOOT0 en alto + reset, aparece como 0483:df11)
dfu-util -a 0 -d 0483:df11 -s 0x08000000:leave -D dist/ardurover_with_bl.bin

# ArduPilot, por USB  (actualizacion normal, sin abrir el equipo)
python Tools/scripts/uploader.py --port COMx dist/ardurover.apj
#  o Mission Planner -> Install Firmware -> Load custom firmware

# ArduPilot, por USART1  (el mismo puerto que emite el NMEA)
#  Resetear la placa y lanzar esto en la ventana de arranque del bootloader:
python Tools/scripts/uploader.py --port COMx --baud-bootloader 115200        dist/ardurover.apj

# Cable serie  (tras enviar  $GO_BOOT,*6D  por SERIAL1 a 115200 8-N-1)
python -m stm32loader -p COMx -b 115200 -P even -a 0x08000000 -f F4 -e -w -v \
       dist/ardurover_with_bl.bin
```

> **Aviso:** `dist/` contiene **un solo `.bin`**, deliberadamente. La aplicación
> suelta se graba en otra dirección (`0x08010000`); confundirla con la combinada al
> usar DFU deja la placa sin bootloader.

Diferencia relevante entre vías: el `.apj` escribe **solo la aplicación** y no toca
el bootloader, por lo que un fallo a medias deja la placa recuperable. El `.hex` y
el `.bin` reescriben **también el bootloader**.

### Por USART1 caben dos protocolos distintos

El mismo par de cables que emite el NMEA sirve para dos cosas que **no** son la
misma, porque hablan con **dos bootloaders diferentes**:

| Se envía | Responde | Escribe | Cómo se entra |
|---|---|---|---|
| `ardurover.apj` | bootloader de **ArduPilot** | solo la aplicación, desde `0x08010000` | resetear la placa y lanzar `uploader.py` en su ventana de arranque |
| `ardurover_with_bl.bin` | bootloader **de fábrica del STM32** (AN3155) | todo, desde `0x08000000` | `$GO_BOOT,*6D` por SERIAL1, o BOOT0 |

El bootloader de ArduPilot escucha en `OTG1 USART1 UART5 USART6`
([`hwdef-bl.dat`](overlay/libraries/AP_HAL_ChibiOS/hwdef/SBY_GPS_INS/hwdef-bl.dat)),
así que la vía del `.apj` **no es exclusiva del USB**: funciona igual por el UART
del GPS. Es la más segura de las dos, porque no toca el bootloader.

La otra vía pasa por el ROM del micro, que ni siquiera es código de ArduPilot: usa
paridad par (8-EVEN-1), no 8-N-1, y reescribe el bootloader. Mandar por ella el
fichero equivocado deja la placa sin bootloader.

### Publicar una versión

Cuando una compilación se da por buena, sus binarios se publican en
[Releases](https://github.com/CarlosEGMWar/GPS_INS/releases) bajo una etiqueta de
versión. Así se puede grabar una placa sin montar el entorno, y queda constancia de
qué se entregó y cuándo.

Cada release contiene los tres formatos sueltos, el `manifest.json` con las huellas
SHA-256, y un `.zip` con todo junto más un `COMO_GRABAR.txt`.

Se publica con [`./scripts/publicar.sh`](#scriptspublicarsh--publicar-una-release).

Antes de grabar conviene verificar la integridad de la descarga:

```bash
sha256sum ardurover_with_bl.bin      # debe coincidir con manifest.json
```

---

## 11. Cosas que conviene saber

**Las ediciones dentro de `build/ardupilot/` no persisten.** `actualizar.sh` resetea
esa carpeta. Al modificar un archivo de ArduPilot hay que regenerar su parche antes.
`compilar.sh` lista los archivos modificados como recordatorio.

**El `$PASHR` emite radianes, no grados.** El estándar especifica grados; esta
implementación se aparta a propósito por compatibilidad con el software de SBY. Un
programa genérico interpretará mal esa salida. Está advertido en la cabecera del
driver.

**En Windows, los finales de línea rompen la compilación.** Si el árbol se clona con
`core.autocrlf=true`, git desde WSL considera modificados ~6000 archivos y la
compilación falla en la última tarea. Los scripts lo corrigen; la solución de raíz
es `git config --global core.autocrlf input`.

**El driver compila contra dos versiones de ArduPilot.** Usa los nombres antiguos de
`AP_GPS` comparados como enteros, presentes tanto en Rover-4.7.x como en master. Esa
adaptación es exclusiva de este fork y **no debe proponerse a ArduPilot**.

---

## 12. Licencia

ArduPilot se distribuye bajo **GPLv3**. Este repositorio contiene trabajo derivado
—parches y una librería— y se publica bajo la misma licencia.

ArduPilot es propiedad de sus autores:
[ArduPilot/ardupilot](https://github.com/ArduPilot/ardupilot).
