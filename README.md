# GPS_INS — firmware ArduPilot para la placa SBY_GPS_INS

Firmware de la placa **SBY GPS G3.1** de SBY Technologies, construido sobre
**ArduPilot Rover**.

Este repositorio **no contiene ArduPilot**. Contiene solo lo que SBY añade —unos
2.100 líneas— y unos scripts que descargan ArduPilot, le aplican esos cambios y
compilan. Por eso pesa 540 KB en vez de 2 GB.

---

## ¿Solo querés grabar una placa?

**No hace falta compilar nada.** Los binarios ya hechos están en
**[Releases](https://github.com/CarlosEGMWar/GPS_INS/releases)**:

| Descargá esto | Si vas a grabar con |
|---|---|
| `ardurover_with_bl.hex` | **ST-LINK / SWD** |
| `ardurover_with_bl.bin` | **DFU** por USB, o cable serie |
| `ardurover.apj` | **Mission Planner**, por USB |
| `SBY_GPS_INS-vX.Y.Z.zip` | los tres juntos, con instrucciones dentro |

Los comandos de grabación están en la [sección 10](#10-qué-sale-en-dist-y-cómo-se-graba)
y también dentro del zip.

El resto de este documento es para **compilar el firmware vos mismo**, que solo
hace falta si vas a modificarlo o a actualizarlo a una versión nueva de ArduPilot.

---

## 1. Qué es la placa

Una controladora GPS/INS: fusiona un receptor GNSS con dos unidades inerciales y
emite una solución de posición y actitud.

| | |
|---|---|
| **Microcontrolador** | STM32F413RHT3 (ARM Cortex-M4, 1,5 MB de flash) |
| **GNSS** | Septentrio mosaic-G5, hablando NMEA |
| **IMU primaria** | Analog Devices ADIS16467, por SPI |
| **IMU secundaria** | Bosch BMI088, por I2C |
| **No lleva** | brújula, barómetro ni salidas PWM |

### Qué le añade este firmware a ArduPilot

1. **Una salida NMEA propietaria** por USART1, con `$GNGGA` y `$PASHR`
   **alimentados por el EKF**, no por el GPS crudo. La posición sale de la
   solución fusionada GNSS+IMU, y el `$PASHR` lleva la actitud y los estados del
   filtro de Kalman. Esa es la razón de ser del producto.
2. **El comando `$GO_BOOT`**, que pone el micro en el bootloader de fábrica para
   reprogramarlo por cable serie, sin tocar la placa.
3. **Soporte del ADIS16467**, que ArduPilot no reconoce.
4. **Arreglos del STM32F413** en USB y DMA, sin los cuales la placa no arranca.

> El pinout completo está en
> [`overlay/GPS_G3_1_Conexiones_GPIO.xlsx`](overlay/GPS_G3_1_Conexiones_GPIO.xlsx).
> La configuración que usa el firmware está en
> [`hwdef.dat`](overlay/libraries/AP_HAL_ChibiOS/hwdef/SBY_GPS_INS/hwdef.dat),
> explicada en el [README de la placa](overlay/libraries/AP_HAL_ChibiOS/hwdef/SBY_GPS_INS/README.md).

---

## 2. La idea: overlay + parches

ArduPilot es un proyecto ajeno que se actualiza constantemente. Para no quedarnos
atrás ni perder nuestros cambios, estos se guardan **por separado** y se vuelven a
aplicar cada vez.

Los cambios son de **dos tipos**, y cada uno se maneja distinto:

```
ARCHIVOS NUEVOS            ->  overlay/   ->  se COPIAN
  archivos que no existen                     nunca fallan: nadie mas
  en ArduPilot                                los toca

ARCHIVOS DE ARDUPILOT      ->  patches/   ->  se APLICAN
  archivos suyos que                          aqui es donde puede haber
  nosotros editamos                           conflicto al actualizar
```

**La regla, para saber dónde va un cambio nuevo:** ¿el archivo ya existe en
ArduPilot? Si **no**, va a `overlay/`. Si **sí**, va como parche.

Un ejemplo de por qué importa: el `$GNGGA`, el `$PASHR` y el `$GO_BOOT` están
enteros dentro de nuestro propio driver, así que van en `overlay/` y **nunca dan
conflicto**. Solo 59 líneas repartidas en 7 parches tocan código de ArduPilot.

---

## 3. Estructura de carpetas

| Carpeta | Qué es | ¿Se sube a git? |
|---|---|---|
| `UPSTREAM` | Versión exacta de ArduPilot sobre la que se construye | Sí |
| `overlay/` | Nuestros archivos: el driver, la placa, el bootloader | Sí |
| `patches/` | Los 7 parches a ArduPilot, más su explicación | Sí |
| `scripts/` | Las herramientas: preparar, compilar, actualizar, verificar | Sí |
| `build/ardupilot/` | ArduPilot descargado. **Desechable**, se regenera | No |
| `dist/` | Los binarios listos para grabar | No |

Detalle de `overlay/`, que es donde vive el producto:

```
overlay/
  libraries/AP_NMEA_SBY_INS/                 nuestro driver
      AP_NMEA_SBY_INS.cpp                       genera $GNGGA y $PASHR, atiende $GO_BOOT
      AP_NMEA_SBY_INS.h
      AP_NMEA_SBY_INS_config.h
      PATCH_NOTES.md                            notas de integracion
  libraries/AP_HAL_ChibiOS/hwdef/SBY_GPS_INS/   definicion de la placa
      hwdef.dat                                 pines, puertos serie, IMUs, LEDs
      hwdef-bl.dat                              lo mismo para el bootloader
      defaults.parm                             parametros de fabrica
      README.md, LEDS.md                        documentacion
  Tools/bootloaders/SBY_GPS_INS_bl.bin        bootloader ya compilado
  Tools/scripts/sby_release.py                empaqueta los 3 formatos de grabacion
  GPS_G3_1_Conexiones_GPIO.xlsx               pinout autoritativo
  especificaciones_placa_SBY_GPS_INS.md       documento historico
```

> **`build/ardupilot/` es desechable a propósito.** Los scripts lo resetean y lo
> reconstruyen. Si editás algo ahí y no lo pasás a `overlay/` o a `patches/`, **lo
> perdés**. La verdad vive siempre en esas dos carpetas.

---

## 4. Requisitos

Hace falta **Linux, WSL o macOS**. Los scripts son bash POSIX y no tienen nada
específico de ninguna plataforma.

| Sistema | ¿Funciona? | Nota |
|---|---|---|
| Linux x86_64 | Sí | el caso natural |
| WSL sobre Windows | Sí | probado en Ubuntu 22.04 |
| macOS | Sí | usar el toolchain `mac` |
| Linux ARM (Raspberry, etc.) | Sí | usar el toolchain `aarch64-linux` |
| **Windows nativo** (cmd/PowerShell) | **No** | waf necesita POSIX |

> Que Windows nativo no sirva no es cosa nuestra: el instalador oficial de
> ArduPilot para Windows lo que hace es instalar Cygwin, otra capa POSIX.

Solo necesitás tener **`git`**, **`python3`** y **`binutils`** (para `strings`),
que suelen venir de serie. El compilador ARM y todo lo demás lo instalan los
scripts solos: ver la [sección 5](#5-instalación).

---

## 5. Instalación

**Dos comandos.** No hay que descargar ArduPilot ni instalar el compilador a
mano: los scripts detectan qué falta y lo preparan solos.

```bash
git clone https://github.com/CarlosEGMWar/GPS_INS.git
cd GPS_INS
./scripts/compilar.sh
```

La primera vez descarga unos **2,4 GB** y tarda un rato largo. Va diciendo qué
hace:

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

Las siguientes veces no descarga nada y compila en ~90 s.

### Qué instala, y dónde

| Qué | Dónde | Tamaño |
|---|---|---|
| ArduPilot, en la versión de `UPSTREAM` | `build/ardupilot/` | ~880 MB |
| Sus submódulos (ChibiOS, mavlink…) | `build/ardupilot/modules/` | ~460 MB |
| `empy`, `pymavlink`, `intelhex`, `future` | `pip --user` | pequeño |
| El compilador ARM | `~/opt/gcc-arm-none-eabi-*/` | ~150 MB |

Nada de eso toca directorios del sistema ni pide `sudo`.

### Si preferís usar tu propio compilador

Si tu sistema ya trae `arm-none-eabi-gcc`, los scripts lo usan y no descargan
nada. También podés apuntar al tuyo:

```bash
export ARM_TOOLCHAIN=/ruta/a/gcc-arm-none-eabi/bin
```

Si lo querés instalar por paquetes:

```bash
sudo apt install gcc-arm-none-eabi binutils      # Debian / Ubuntu
sudo dnf install arm-none-eabi-gcc-cs binutils   # Fedora
brew install --cask gcc-arm-embedded             # macOS
```

> ArduPilot recomienda la versión **10-2020-q4-major**, que es la que descargan
> los scripts. Con versiones muy distintas del compilador pueden salir avisos o
> cambiar el tamaño del binario.

### Preparar sin compilar

Si solo querés dejar el entorno listo y compilar más tarde:

```bash
./scripts/preparar.sh
```

Se puede correr las veces que quieras: solo hace lo que falte.

---

## 6. Los comandos

Son cuatro, pero en el día a día usás uno.

| Comando | Para qué |
|---|---|
| `compilar.sh` | **el del día a día**: compila lo que hay |
| `actualizar.sh` | reconstruir desde cero, y saltar de versión |
| `preparar.sh` | dejar el entorno listo (lo llaman los otros solos) |
| `verificar.sh` | comprobar el binario (lo llaman los otros solos) |

### `./scripts/compilar.sh` — el del día a día

Compila lo que hay ahora mismo y deja los binarios en `dist/`.
**No borra nada**, así que respeta lo que tengas a medias.

Cuánto tarda depende de qué toques:

| Cambiaste | Recompila | Tiempo |
|---|---|---|
| Nada | 0 archivos | ~85 s |
| Un `.cpp` | ese archivo | ~90 s |
| `hwdef.dat` o `defaults.parm` | ~1044 archivos | ~10 min |

El `hwdef.dat` es caro porque regenera un cabecero que incluye medio ArduPilot.

Opciones: `--sin-overlay` (no sincronizar `overlay/`, útil si estás editando esos
archivos dentro del árbol) y `--sin-dist` (solo compilar).

### `./scripts/actualizar.sh` — reconstruir desde cero

Deja ArduPilot virgen, copia el overlay, aplica los 7 parches en orden, compila y
verifica. Úsalo cuando quieras un resultado limpio y reproducible.

> ⚠️ **Borra lo que tengas editado en `build/ardupilot/` sin guardar.**

### `./scripts/preparar.sh` — dejar el entorno listo

Descarga ArduPilot, sus submódulos, las dependencias de Python y el compilador
ARM, pero **solo lo que falte**. `compilar.sh` y `actualizar.sh` lo llaman solos
cuando detectan que algo no está, así que casi nunca hace falta invocarlo a mano.

### `./scripts/verificar.sh` — comprobar el binario

Busca las cadenas propias dentro del firmware compilado. Corre solo al final de
`compilar.sh` y `actualizar.sh`, y corta el proceso si algo falta.
Ver [la sección 9](#9-la-comprobación-que-no-hay-que-saltarse).

---

## 7. Actualizar a una versión nueva de ArduPilot

```bash
./scripts/actualizar.sh --buscar          # ver que releases hay disponibles
./scripts/actualizar.sh Rover-4.7.2       # saltar a ese
```

Qué hace: descarga esa versión, la deja virgen, vuelve a aplicar el overlay y los
7 parches encima, compila y verifica. Si todo sale bien, actualiza el archivo
`UPSTREAM` para dejar constancia de sobre qué versión estás.

**Si un parche no entra**, el proceso se detiene ahí mismo y te dice cuál, en qué
archivo, y qué hacer. Los parches anteriores quedan aplicados. Eso pasa cuando
ArduPilot movió justo el código que parcheamos, y lo tiene que resolver una
persona: ninguna herramienta puede decidir por vos. El procedimiento está en
[`patches/README.md`](patches/README.md).

La versión se cambia **a mano y a propósito**. El script nunca salta solo, para
que compilar hoy y dentro de un año dé exactamente el mismo binario.

---

## 8. Los 7 parches, uno por uno

Esto es **todo** lo que el firmware le cambia a ArduPilot: **59 líneas en 11
archivos**. Cada `.patch` lleva dentro su propia explicación, encima del cambio.

### `0001` — registrar el protocolo serie

**Archivos:** `libraries/AP_SerialManager/AP_SerialManager.h` y `.cpp`

Da de alta el protocolo número **100** con el nombre `NMEA_SBY_INS`. Sin esto no
se puede poner `SERIAL1_PROTOCOL=100` para activar nuestra salida. El `.cpp`
añade el nombre a la lista que muestra Mission Planner.

### `0002` — enchufar la librería al vehículo ⚠️

**Archivos:** `libraries/AP_Vehicle/AP_Vehicle.h` y `.cpp`

**El más importante de los siete.** Hace tres cosas: crea el objeto, registra su
parámetro `SBYN_RATE_MS`, y **programa su ejecución 50 veces por segundo**.

Sin la última línea, el firmware compila y arranca igual pero nuestro código
**no se ejecuta nunca**: no hay salida NMEA, no hay `$GO_BOOT` y no hay LEDs. Sin
ningún mensaje de error. Por eso existe `verificar.sh`.

### `0003` — incluir la librería en la compilación

**Archivo:** `Tools/ardupilotwaf/ardupilotwaf.py`

Una línea. ArduPilot compila una lista fija de librerías, no todo lo que
encuentra. Si falta, da error de enlazado — ruidoso, se nota enseguida.

### `0004` — leer la antigüedad de las correcciones RTK

**Archivos:** `libraries/AP_GPS/AP_GPS.h`, `AP_GPS_NMEA.cpp`, `AP_GPS_NMEA.h`

El receptor publica en su GGA cuántos segundos hace que recibió correcciones
RTK. ArduPilot lo ignora; este parche lo guarda para que nuestra salida lo
reemita.

Es el único **opcional**: sin él todo funciona, solo que ese campo sale vacío.

### `0005` — reconocer la IMU ADIS16467

**Archivo:** `libraries/AP_InertialSensor/AP_InertialSensor_ADIS1647x.cpp`

ArduPilot soporta los modelos 16470, 16477 y 16507, pero no el 16467 que monta la
placa. Sin este parche **la IMU primaria no se detecta** y la placa arranca solo
con la BMI088.

### `0006` — arreglos del STM32F413

**Archivo:** `libraries/AP_HAL_ChibiOS/hwdef/scripts/STM32F413xx.py`

Dos correcciones al generador de configuración de ArduPilot para este micro:
habilitar el USB (la base de datos del F413 usa un nombre que el generador no
reconoce) y corregir una opción de DMA que rompe el bus I2C de la BMI088.

Sin esto no compila siquiera.

### `0007` — identificador de placa y bootloader

**Archivos:** `Tools/AP_Bootloader/board_types.txt` y `bl_protocol.cpp`

Registra el identificador `AP_HW_SBY_GPS_INS`. **Hace falta para compilar el
firmware**, no solo el bootloader: la compilación lee ese archivo para traducir el
nombre a número.

El cambio en `bl_protocol.cpp` solo afecta a quien recompile el bootloader.

---

## 9. La comprobación que no hay que saltarse

Como explica el `0002`, hay una forma de que el firmware salga **roto pero
aparentemente correcto**: compila, enlaza, arranca, y no hace nada de lo nuestro.

Por eso, tras cada compilación se buscan nuestras cadenas dentro del binario:

```bash
strings -n 6 build/ardupilot/build/SBY_GPS_INS/bin/ardurover.bin \
    | grep -E 'GNGGA|PASHR|GO_BOOT'
```

Si no aparecen las tres, la librería no entró. `verificar.sh` lo hace solo y corta
el proceso. **No grabes una placa con un firmware que no pasó esa comprobación.**

---

## 10. Qué sale en `dist/` y cómo se graba

Los tres formatos, para las tres formas de programar la placa:

| Fichero | Se graba con | Dirección |
|---|---|---|
| `ardurover_with_bl.hex` | **ST-LINK / SWD** | la lleva dentro |
| `ardurover_with_bl.bin` | **DFU** por USB, y cable serie tras `$GO_BOOT` | `0x08000000` |
| `ardurover.apj` | **Mission Planner** o `uploader.py`, por USB | implícita |
| `manifest.json` | — | huellas SHA-256 y tamaños |

Los tres contienen el mismo firmware. El empaquetador lo comprueba antes de
escribirlos: descomprime el `.apj`, parsea el `.hex`, y si algo no coincide,
aborta sin generar nada.

```bash
# ST-LINK / SWD  (produccion; graba bootloader + aplicacion)
STM32_Programmer_CLI -c port=SWD mode=UR -w dist/ardurover_with_bl.hex -v -rst

# DFU  (recuperacion; BOOT0 en alto + reset, aparece como 0483:df11)
dfu-util -a 0 -d 0483:df11 -s 0x08000000:leave -D dist/ardurover_with_bl.bin

# ArduPilot  (actualizacion normal por USB, sin abrir el equipo)
python Tools/scripts/uploader.py --port COMx dist/ardurover.apj
#  o Mission Planner -> Install Firmware -> Load custom firmware

# Cable serie  (tras enviar  $GO_BOOT,*6D  por SERIAL1 a 115200 8-N-1)
python -m stm32loader -p COMx -b 115200 -P even -a 0x08000000 -f F4 -e -w -v \
       dist/ardurover_with_bl.bin
```

> ⚠️ Hay **un solo `.bin`** en `dist/`, a propósito. La aplicación suelta se graba
> en otra dirección (`0x08010000`) y confundirla con la combinada al usar DFU deja
> la placa sin bootloader.

Diferencia importante entre vías: el `.apj` escribe **solo la aplicación** y no
toca el bootloader, así que si falla a medias la placa sigue siendo recuperable.
El `.hex` y el `.bin` reescriben **también el bootloader**.

### Publicar una versión

Cuando una compilación se da por buena, sus binarios se publican en
[Releases](https://github.com/CarlosEGMWar/GPS_INS/releases) con una etiqueta de
versión. Así cualquiera puede grabar una placa sin montar el entorno, y queda
constancia de qué se entregó y cuándo.

Cada release lleva los tres formatos sueltos, el `manifest.json` con las huellas
SHA-256, y un `.zip` con todo junto más un `COMO_GRABAR.txt`.

Antes de grabar, conviene comprobar que la descarga no se corrompió:

```bash
sha256sum ardurover_with_bl.bin      # debe coincidir con el manifest.json
```

---

## 11. Cosas que conviene saber

**No edites dentro de `build/ardupilot/` esperando que se guarde.**
`actualizar.sh` lo resetea. Si tocás un archivo de ArduPilot, regenerá su parche
antes. `compilar.sh` te lista lo que tengas modificado, como recordatorio.

**El `$PASHR` sale en radianes, no en grados.** El estándar dice grados; nos
apartamos a propósito por compatibilidad con el software de SBY. Un programa
genérico leerá mal esa salida. Está avisado en la cabecera del driver.

**En Windows, los finales de línea rompen la compilación.** Si el árbol se clona
con `core.autocrlf=true`, git desde WSL ve ~6000 archivos como modificados y la
compilación muere en la última tarea. Los scripts lo corrigen solos. Para
arreglarlo de raíz en tu equipo: `git config --global core.autocrlf input`.

**El driver compila en dos versiones de ArduPilot a la vez.** Usa los nombres
antiguos de `AP_GPS` comparados como enteros, que existen tanto en Rover-4.7.x
como en master. Esa adaptación es exclusiva de este fork y **no debe proponerse a
ArduPilot**.

---

## 12. Licencia

ArduPilot se distribuye bajo **GPLv3**. Este repositorio contiene trabajo derivado
—parches y una librería— y se publica bajo la misma licencia.

ArduPilot es propiedad de sus autores:
[ArduPilot/ardupilot](https://github.com/ArduPilot/ardupilot).
