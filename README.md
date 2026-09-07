# GPS_INS — firmware ArduPilot para la placa SBY_GPS_INS

Soporte de la placa **SBY GPS G3.1** de SBY Technologies sobre **ArduPilot Rover**,
mantenido como **cola de parches** en vez de como un fork completo.

Este repositorio pesa unos 500 KB y contiene **solo lo propio**: el driver, la
definición de la placa y los 7 parches que ArduPilot necesita. ArduPilot en sí
(1,9 GB) no está aquí — lo descarga el script cuando hace falta, en la versión
exacta que dice el archivo [`UPSTREAM`](UPSTREAM).

---

## Qué es la placa, en corto

- **MCU:** STM32F413RHT3 (Cortex-M4, 1,5 MB de flash)
- **GNSS:** Septentrio mosaic-G5, hablando NMEA
- **IMUs:** ADIS16467 por SPI (primaria) + Bosch BMI088 por I2C (redundancia)
- **Sin brújula, sin barómetro, sin salidas PWM**

Lo que aporta este firmware sobre ArduPilot estándar:

- Una salida NMEA propietaria por USART1 con **`$GNGGA` y `$PASHR` alimentados por
  el EKF**, no por el GPS crudo. La posición sale de la solución fusionada
  GNSS+IMU, y el `$PASHR` lleva actitud y estados del filtro Kalman.
- El comando **`$GO_BOOT`**, que deja el micro en el bootloader de ROM para
  grabarlo por UART sin tocar la placa.
- Soporte del **ADIS16467**, que ArduPilot no reconoce.
- Arreglos del **STM32F413** (USB y DMA) necesarios para que la placa arranque.

> **Pinout completo:** [`overlay/GPS_G3_1_Conexiones_GPIO.xlsx`](overlay/GPS_G3_1_Conexiones_GPIO.xlsx)
> es la referencia autoritativa. La configuración que realmente usa el firmware está en
> [`overlay/libraries/AP_HAL_ChibiOS/hwdef/SBY_GPS_INS/hwdef.dat`](overlay/libraries/AP_HAL_ChibiOS/hwdef/SBY_GPS_INS/hwdef.dat),
> y su explicación en el [README de la placa](overlay/libraries/AP_HAL_ChibiOS/hwdef/SBY_GPS_INS/README.md).

---

## Cómo funciona

```
overlay/    archivos que NO existen en ArduPilot   ->  se COPIAN    (nunca fallan)
patches/    archivos que SI existen y editamos     ->  se APLICAN   (aqui puede chocar)
```

Los scripts montan un árbol de ArduPilot **desechable** en `build/ardupilot/`,
le vuelcan el overlay, le aplican la cola de parches y compilan. Ese árbol se
regenera entero cuando haga falta: **la verdad vive en `overlay/` y `patches/`**.

---

## Puesta en marcha (una sola vez)

Hace falta **Linux o WSL**: el sistema de compilación de ArduPilot no corre en
Windows nativo.

```bash
# 1. clonar este repositorio
git clone https://github.com/CarlosEGMWar/GPS_INS.git
cd GPS_INS

# 2. traer ArduPilot en la version que dice UPSTREAM
git clone https://github.com/ArduPilot/ardupilot.git build/ardupilot
git -C build/ardupilot checkout $(head -1 UPSTREAM)
git -C build/ardupilot submodule update --init \
    modules/waf modules/mavlink modules/ChibiOS modules/lwip modules/littlefs \
    modules/Micro-CDR modules/Micro-XRCE-DDS-Client modules/DroneCAN/DSDL \
    modules/DroneCAN/dronecan_dsdlc modules/DroneCAN/libcanard modules/DroneCAN/pydronecan

# 3. toolchain ARM y dependencias de Python
mkdir -p ~/opt && cd ~/opt
wget -c https://firmware.ardupilot.org/Tools/STM32-tools/gcc-arm-none-eabi-10-2020-q4-major-x86_64-linux.tar.bz2
tar xjf gcc-arm-none-eabi-10-2020-q4-major-x86_64-linux.tar.bz2
python3 -m pip install --user "empy==3.3.4" pymavlink future intelhex pexpect
cd -
```

Los scripts buscan el toolchain en `~/opt/gcc-arm-none-eabi-*/bin` y avisan si
no lo encuentran. Solo se hace una vez: ocupa ~2,4 GB entre ArduPilot y el compilador.

---

## Uso diario

### Compilar lo que hay

```bash
./scripts/compilar.sh
```

Sincroniza el overlay, compila y deja los binarios en `dist/`.
**No resetea nada**, así que respeta lo que tengas editado en `build/ardupilot/`
— es el que usás mientras estás probando cosas.

Opciones: `--sin-overlay` (no pisar tus archivos si los editás dentro del árbol),
`--sin-dist` (solo compilar).

Cuánto tarda, según lo que cambies:

| Cambio | Recompila | Tiempo |
|---|---|---|
| Nada | 0 archivos | ~85 s |
| Un `.cpp` | ese archivo | ~90 s |
| `hwdef.dat` o `defaults.parm` | ~1044 archivos | ~10 min |

El `hwdef.dat` es caro porque regenera `hwdef.h`, y medio ArduPilot lo incluye.

### Reconstruir desde cero

```bash
./scripts/actualizar.sh
```

Deja ArduPilot virgen, vuelca el overlay, aplica los 7 parches en orden, compila
y verifica. **Hace `git reset --hard` sobre `build/ardupilot`: pierdes lo que
tengas editado ahí sin guardar.**

### Actualizar a un release nuevo de ArduPilot

```bash
./scripts/actualizar.sh --buscar          # ver que releases hay
./scripts/actualizar.sh Rover-4.7.2       # saltar a ese
```

Descarga la versión, la deja virgen y reaplica todo encima. Si un parche no entra,
**se detiene ahí** y te dice cuál, qué archivo y qué hacer. Si todo sale bien,
actualiza el archivo `UPSTREAM` al final.

La mayoría de actualizaciones salen limpias. Cuando una choca, es porque ArduPilot
movió justo el código que parcheamos, y eso lo tiene que resolver una persona:
ver [`patches/README.md`](patches/README.md).

---

## Qué sale en `dist/`

Los tres formatos de programación, verificados entre sí antes de escribirse:

| Fichero | Para grabar con | Dirección |
|---|---|---|
| `ardurover_with_bl.hex` | **ST-LINK / SWD** (STM32CubeProgrammer) | va dentro del fichero |
| `ardurover_with_bl.bin` | **DFU** por USB, y bootloader de ROM por UART | `0x08000000` |
| `ardurover.apj` | **ArduPilot** (uploader.py / Mission Planner) | implícita |
| `manifest.json` | commit, tamaños y SHA-256 de cada uno | — |

Los tres llevan el mismo firmware; el script lo comprueba descomprimiendo el
`.apj` y parseando el `.hex` antes de generarlos. Si algo no cuadra, aborta.

### Cómo grabar cada uno

```bash
# ST-LINK / SWD  (produccion; graba bootloader + app)
STM32_Programmer_CLI -c port=SWD mode=UR -w dist/ardurover_with_bl.hex -v -rst

# DFU  (recuperacion; BOOT0 alto + reset, aparece 0483:df11)
dfu-util -a 0 -d 0483:df11 -s 0x08000000:leave -D dist/ardurover_with_bl.bin

# ArduPilot  (actualizacion normal por USB, sin tocar la placa)
python Tools/scripts/uploader.py --port COMx dist/ardurover.apj
#  o Mission Planner -> Install Firmware -> Load custom firmware

# UART  (tras mandar  $GO_BOOT,*6D  por SERIAL1, a 115200 8-N-1)
python -m stm32loader -p COMx -b 115200 -P even -a 0x08000000 -f F4 -e -w -v \
       dist/ardurover_with_bl.bin
```

> ⚠️ Solo hay **un** `.bin` en `dist/` a propósito. La app suelta va en
> `0x08010000` y confundirla con la combinada al grabar por DFU deja la placa
> sin bootloader.

---

## Estructura

```
UPSTREAM              version de ArduPilot sobre la que se construye
overlay/              archivos propios, se copian tal cual al arbol
patches/              los 7 parches al core + series + README
scripts/
   compilar.sh        desarrollo: compila lo que hay, sin resetear
   actualizar.sh      ciclo limpio, y salto de version
   verificar.sh       comprueba que el binario esta completo
   comun.sh           funciones compartidas
build/ardupilot/      arbol desechable          (ignorado por git)
dist/                 binarios generados        (ignorado por git)
```

---

## Cosas que conviene saber

**Nunca edites dentro de `build/ardupilot/` pensando que se guarda.**
`actualizar.sh` lo resetea. Si tocás un archivo de ArduPilot, regenerá su
`.patch` antes de volver a correrlo. `compilar.sh` te lista lo que tengas
modificado sin guardar, como recordatorio.

**El `$PASHR` sale en radianes, no en grados.** Se aparta del estándar a
propósito, por compatibilidad con el software de SBY. Un parser genérico lo
leerá mal. Está documentado en la cabecera del driver.

**En clones de Windows, `core.autocrlf` rompe el build.** Deja los `.py` de
`Tools/scripts` en CRLF y waf muere en la última tarea, al generar el `.hex`,
tras compilar las 999 anteriores. Los scripts lo normalizan solos en cada
pasada. Para arreglarlo de raíz: `git config --global core.autocrlf input`.

**Comprobación antes de grabar una placa.** Si el parche `0002` se perdiera en
una actualización, el firmware compila igual pero se queda sin salida NMEA, sin
`$GO_BOOT` y sin LEDs, en silencio. `verificar.sh` lo detecta buscando las
cadenas dentro del binario, y corre solo al final de los dos scripts.

---

## Licencia

ArduPilot es **GPLv3**. Este repositorio contiene trabajo derivado —parches y
un driver— y se publica bajo la misma licencia. ArduPilot es propiedad de sus
autores; ver [ArduPilot/ardupilot](https://github.com/ArduPilot/ardupilot).
