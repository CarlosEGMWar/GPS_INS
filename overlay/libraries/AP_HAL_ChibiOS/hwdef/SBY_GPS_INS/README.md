# SBY_GPS_INS (G3.1) — controladora GPS/INS

Board **"SBY GPS G3.1 mod G5 - Main"** de **SBY Technologies**.
Firmware **ArduPilot Rover**. Salida propietaria NMEA `SBY_INS` (GPGGA + PASHR del EKF) + telemetría MAVLink.

- **MCU:** STM32F413RHT3 (LQFP-64, 1.5 MB flash físico, HSE 8 MHz).
- **APJ_BOARD_ID:** `AP_HW_SBY_GPS_INS`.
- **Pinout autoritativo:** `GPS_G3_1_Conexiones_GPIO.xlsx` (raíz del repo).

> Sin brújula, sin barómetro, sin salidas PWM / control de motores. El rumbo (yaw) sin brújula lo da el EKF3 por GSF/GPS.

---

## 1. IMUs (redundancia)

| IMU | Bus | Pines | Rol | Notas |
|-----|-----|-------|-----|-------|
| **ADIS16467** | SPI1 | SCK=PA5, MISO=PA6, MOSI=PA7, CS=PA4, **DR=PA1** (EXTI1) | **IMU0 (primaria)** | Mode 3. Ver caveat driver ⚠️ |
| **BMI088** | I2C1 | SCL=PB6, SDA=PB7 | IMU1 (redundancia) | Dir **0x19/0x69** (SDO a VDD, PS alto). Polling (INT sin cablear). |

- Alimentación de las IMUs: **PB5 = IMU_EN** (load-switch U6 SIP32510 → VCC_IMU). `OUTPUT HIGH` = encendido al arrancar.
- El driver `AP_InertialSensor_ADIS1647x` **ya reconoce el ADIS16467** (PROD_ID 0x4053), configurado como variante **-2** (±500 °/s, ±40 g, 2 kHz). Detecta al conectarla. El PROD_ID no distingue -1/-2/-3; si la placa montara -1 o -3, ajustar `gyro_scale` en el `case PROD_ID_16467` del driver.
- Si la ADIS **no está conectada** físicamente (conector externo H4), la BMI088 pasa a ser IMU0 y la placa funciona igual con una sola IMU.
- **Rotaciones:** BMI088 = `ROTATION_ROLL_180_YAW_90` (confirmada: montada boca abajo + 90° yaw; horizonte y ejes verificados). ADIS = `ROTATION_NONE` provisional (ajustar en banco cuando se conecte). Las rotaciones son por-IMU (en la directiva `IMU`), independientes entre sí.

## 2. Puertos serie

| SERIALx | Puerto | Pines | Protocolo | Uso |
|---------|--------|-------|-----------|-----|
| SERIAL0 | USB (OTG1) | PA11/PA12 | MAVLink2 | USB-C. Enumera `ArduPilot (COMx)`, VID 0x1209 / PID 0x5741. **(consola)** |
| SERIAL1 | USART1 | PA9/PA10 | NMEA_SBY_INS | Salida NMEA propietaria (RS232 ch1) + entrada del comando `$GO_BOOT` (§2.1). RTCM-in sin enrutar. |
| SERIAL2 | UART5 | PC12/PD2 | MAVLink2 | Telemetría al companion WL52 (RS232 ch2, puerto físicamente accesible). |
| SERIAL3 | USART2 | PA2/PA3 | GPS | GNSS mosaic-G5. |
| SERIAL4 | **USART6** | PC6/PC7 | MAVLink2 | Telemetría **TTL 3.3 V** hacia el WL52 (G3/G4). |

> ⚠️ **La numeración `SERIALx` NO es el número de periférico del STM32.** `SERIALx` es la
> posición dentro de `SERIAL_ORDER` en el `hwdef.dat`. Por eso **el USART6 del micro se
> configura en Mission Planner como `SERIAL4_PROTOCOL` / `SERIAL4_BAUD` / `SERIAL4_OPTIONS`** —
> **no existe ningún parámetro `SERIAL6_*` en esta placa** (solo hay 5 puertos: SERIAL0..SERIAL4).
> Si en Mission Planner no aparece `SERIAL4_*`, el firmware grabado es anterior a que USART6
> entrara en `SERIAL_ORDER`: recompilar y regrabar.

> ⚠️ **Por qué el USB es SERIAL0 y la NMEA es SERIAL1 (no al revés):** ArduPilot **fuerza SERIAL0 a MAVLink** cuando la placa tiene USB (`#ifdef HAL_OTG1_CONFIG` en `AP_SerialManager.cpp`: si `state[0].protocol` no es MAVLink, lo pisa a MAVLink2). Asume SERIAL0 = consola USB. Si se pone la NMEA en SERIAL0, el firmware la sobreescribe a MAVLink y **la salida NMEA nunca funciona**. Por eso la NMEA va en SERIAL1. El puerto físico de la NMEA sigue siendo USART1 (PA9).

- **Canales MAVLink resultantes** (el orden lo fija el arranque, entre los puertos con protocolo
  MAVLink): SERIAL0 → `MAV1_*`, SERIAL2 → `MAV2_*`, SERIAL4 → `MAV3_*`. Los `MAVn_*` (stream rates,
  antes `SRn_*`) **solo aparecen si ese puerto arrancó como MAVLink**. El firmware admite hasta 5
  canales (`MAVLINK_COMM_NUM_BUFFERS = 5` en placas de ≤1 MB), así que los 3 entran de sobra.
- **Reservados (no usados hoy, existen en HW):**
  - USART3 (PB10/PC5, conector IMU H2) → IMU serie interna futura (ej. MicroStrain 3DM-CV7).
  - UART4 TX (PA0) → reservado (PA1 es el DR del ADIS, en uso).
  - Si se agregan, entrarían al final de `SERIAL_ORDER` como SERIAL5 / SERIAL6.
- **RTCM:** las correcciones RTK entran por USART1 RX pero están **puenteadas directo al puerto del módulo Septentrio** — el micro NO las enruta (solo podría escucharlas). Por eso USART1 en firmware es solo NMEA out.
- **PPS** del GNSS: **PC4** (EXTI4).
- **STDOUT** (consola early-boot): **UART5 (SD5)** — es el mismo puerto del companion WL52.

### 2.1 `$GO_BOOT` — entrar al bootloader de ROM para grabar por UART

La herramienta de producción (`GestorGpsSBY`) graba el firmware por **USART1** usando el
**bootloader de ROM de ST (AN3155)**, no el de ArduPilot. Para llegar ahí manda un comando
NMEA por el mismo puerto de la salida SBY_INS (SERIAL1):

| Sentido | Trama | Qué pasa |
|---------|-------|----------|
| PC → FC | `$GO_BOOT,*6D` | comando (se acepta también `$GO_BOOT*41`, y `*XX` salta el checksum) |
| FC → PC | `$GO_BOOT*41` | ACK — se responde a **cada** intento (la herramienta reintenta 3 veces) |
| FC | — | pone **PB3** en alto → carga el capacitor de **BOOT0** |
| FC | — | a los **3 s**, reset. BOOT0 sigue alto por el capacitor → arranca el bootloader de ROM |
| PC | — | reabre el puerto a **115200 8-EVEN-1** y graba (0x7F, erase, write, Go) |

**Comprobado en placa (2026-08-31)** por este mismo camino, con `stm32loader` (`pip install
stm32loader`) en vez de la herramienta de SBY:

```bash
# 1) poner la placa en el ROM: mandar $GO_BOOT,*6D por COM9 a 115200 8-N-1
#    responde $GO_BOOT*41 y a los 3 s resetea al bootloader de ROM
# 2) grabar la imagen COMBINADA (bootloader + app) en 0x08000000, 8-EVEN-1
python -m stm32loader -p COM9 -b 115200 -P even -a 0x08000000 -f F4 -e -w -v \
       dist/ardurover_with_bl.bin
# 3) arrancar sin ciclo de alimentacion
python -m stm32loader -p COM9 -b 115200 -P even -g 0x08000000
```

> **Va el `.bin`, no el `.hex`.** AN3155 es un protocolo crudo: recibe una direccion y
> bytes, no entiende Intel HEX (que es texto ASCII y lleva las direcciones dentro). El
> `.hex` es para STM32CubeProgrammer / ST-LINK, que si lo parsean.

> ⚠️ Por esta via se reescribe **tambien el bootloader** (la imagen empieza en
> `0x08000000`). Si el proceso se corta a medias, la placa queda sin bootloader **y** sin
> app: hay que recuperarla con el boton BOOT0 + reset y volver a grabar por ROM, o por
> SWD. La via del `.apj` (bootloader de ArduPilot) es mas segura porque solo escribe la
> app desde `0x08010000` y deja el bootloader intacto.

Lo implementa `AP_NMEA_SBY_INS::go_boot()`; el pin sale de `define SBY_GO_BOOT_PIN 84` en el
`hwdef.dat`. Es el **mismo mecanismo y el mismo pin** que usa el firmware de test de SBY
(`CommandLogic::ProcessBootloaderMode`), así que la herramienta del PC no cambia.

> Esto es independiente del bootloader de ArduPilot (los primeros 64 KB), que se sigue
> usando para `uploader.py` / Mission Planner. `$GO_BOOT` es la vía de producción/recuperación.

### 2.2 Salida NMEA SBY_INS — formato

- Cadencia por defecto **100 ms (10 Hz)**, parámetro `SBYN_RATE_MS`. Coincide con el
  receptor, que se configura con `setNMEAOutput, Stream1, COM1, GGA+RMC, msec100`.
- Talker **`GN` fijo** (`$GNGGA`): la sentencia la genera el EKF, no se reenvía la del
  módulo, así que no depende de si el mosaic emite `GP`, `GN`, `GL`…
- **PASHR en radianes** (heading/roll/pitch y las 3 precisiones), 3 decimales, heading
  envuelto a `[-pi, pi]`; el heave sigue en metros. Se aparta del PASHR estándar (que es
  en grados) a propósito: es lo que consume el software de SBY. Detalle y justificación en
  `libraries/AP_NMEA_SBY_INS/PATCH_NOTES.md`.

## 3. LEDs

- **RGB a bordo (LED1)** — PB12=R, PB13=G, PB14=B, **ánodo común = activo bajo** (default de ArduPilot). Notify estándar vía `AP_NOTIFY_GPIO_LED_RGB` (GPIO 0/1/2).
- **LEDs de estado (ULN2001, activo alto)** — PB0=Power, PB1=IMU, PB2=GPS. Manejados por `AP_NMEA_SBY_INS` (`SBY_LED_ACTIVE_HIGH=1`, independiente del RGB).

## 4. Otros

- **SWD:** PA13=SWDIO, PA14=SWCLK, NRST, BOOT0 (botón BOOT1).
  **PB3 ya NO es SWO**: se declara como GPIO de salida (`SBY_GO_BOOT`, GPIO 84) para el
  comando `$GO_BOOT` — ver §2.1. El SWD normal no se ve afectado; solo se pierde el
  trace SWO, que ArduPilot no usa.
- **CAN:** CAN1 (PB9 TX/PB8 RX) y CAN3 (PA15 TX/PA8 RX) con transceivers TCAN332 — **sin habilitar** (se agregan cuando haya periférico DroneCAN).
- **Flash:** el chip es 1.5 MB pero se declara `FLASH_SIZE_KB 1024` (usamos ~700 KB + `minimize_features`; soportar 1536 requeriría ~5 parches en las tablas de flash de ChibiOS, sin beneficio funcional).

---

## 5. ⚠️ Parches CORE requeridos (fuera de este directorio)

USB + doble IMU en el F413 es terreno **no pavimentado** en ArduPilot. Este board **no compila** sin estos 3 parches. Reaplicarlos tras un `git pull`/rebase de ArduPilot.

1. **`libraries/AP_HAL_ChibiOS/hwdef/scripts/STM32F413xx.py`** — agregar a `AltFunction_map` (habilita USB):
   ```python
   "PA11:OTG_FS_DM": 10,
   "PA12:OTG_FS_DP": 10,
   ```
   (El DB del F413 solo trae `USB_FS_*`, que el generador no reconoce; el F405 usa `OTG_FS_*`.)

2. **`libraries/AP_HAL_ChibiOS/hwdef/scripts/STM32F413xx.py`** — en `DMA_Map`, quitar la opción incompatible de `I2C1_TX`:
   ```python
   "I2C1_TX" : [(1,6,1),(1,7,1)],   # se quitó (1,1,0): el F413 lo permite pero el I2Cv1 de ChibiOS solo acepta Stream6/7
   ```

3. **`Tools/AP_Bootloader/bl_protocol.cpp`** (`jump_to_app()`) — el F413 no tiene OTG_HS:
   ```c
   #if defined(rccResetOTG_HS) && defined(RCC_AHB1RSTR_OTGHRST)
       rccResetOTG_HS();
   #endif
   ```

4. **`libraries/AP_GPS/AP_GPS_NMEA.cpp` + `.h`** — parsear el **campo 13 del GGA entrante** (age of differential) y guardarlo en `state.rtk_age_ms` (miembro `_new_gga_age_ms` + `case _GPS_SENTENCE_GGA + 13` + asignación al completar la sentencia). Necesario para que el age RTK del mosaic-G5 (que habla NMEA) llegue a la salida.

5. **`libraries/AP_GPS/AP_GPS.h`** — getter público `get_rtk_age_ms()` (lee `state[instance].rtk_age_ms`).

> Con (4) y (5), la lib propia `AP_NMEA_SBY_INS` emite el age en el **campo 13 de su GGA de salida** (segundos; vacío si no hay correcciones). El valor real aparece solo con el mosaic conectado y RTK/DGNSS activo.

> Nota DMA: en el hwdef se usa `NODMA USART*` porque el I2Cv1 del F4 **requiere** DMA y con SPI1+I2C1 los streams DMA1 se pelean con las UARTs. Las UARTs a 115200 andan por IRQ.

## 6. Compilación (WSL)

Toolchain ARM + prereqs Python (empy 3.3.4, pymavlink, future, dronecan, intelhex) + make/gcc host + ccache. PATH: `~/.ccache-bin:~/.local/bin:<toolchain>/bin:$PATH`.

```bash
# Firmware (app)
python3 ./waf configure --board SBY_GPS_INS
python3 ./waf rover
# Bootloader (USB)
python3 ./waf configure --board SBY_GPS_INS --bootloader
python3 ./waf bootloader
```

> **Ojo: el entorno de build depende de la máquina.** En el PC de mjime se compila en
> `Ubuntu -u mjime` sobre `/mnt/d/.../ardupilot`. En otras máquinas eso no existe —
> comprobar con `wsl -l -v` y `whoami` antes de copiar el comando.

#### Montar el entorno desde cero en un WSL limpio (verificado 2026-08-31)

```bash
# 1) submodulos (basta con estos; gtest/gbenchmark/gsoap/CrashDebug son solo para SITL)
git submodule update --init modules/waf modules/mavlink modules/ChibiOS modules/lwip     modules/littlefs modules/Micro-CDR modules/Micro-XRCE-DDS-Client     modules/DroneCAN/DSDL modules/DroneCAN/dronecan_dsdlc modules/DroneCAN/libcanard     modules/DroneCAN/pydronecan

# 2) toolchain ARM (el que espera ArduPilot) y dependencias de Python
mkdir -p ~/opt && cd ~/opt
wget -c https://firmware.ardupilot.org/Tools/STM32-tools/gcc-arm-none-eabi-10-2020-q4-major-x86_64-linux.tar.bz2
tar xjf gcc-arm-none-eabi-10-2020-q4-major-x86_64-linux.tar.bz2
python3 -m pip install --user "empy==3.3.4" pymavlink future intelhex pexpect

# 3) compilar
export PATH=$HOME/opt/gcc-arm-none-eabi-10-2020-q4-major/bin:$HOME/.local/bin:$PATH
cd /mnt/c/.../GPS_INS
python3 ./waf configure --board SBY_GPS_INS && python3 ./waf rover -j$(nproc)
```

> ⚠️ **Clones en Windows con `core.autocrlf=true`:** el checkout deja los `.py` de
> `Tools/scripts/` en CRLF, y waf ejecuta `make_intel_hex.py` por su shebang → el build
> muere al final con `/usr/bin/env: 'python3
': No such file or directory` (compila
> todo y solo falla al generar el `.hex`). El blob commiteado **es LF**; lo rompe el
> checkout. Arreglo puntual: `python3 -c "p='Tools/scripts/make_intel_hex.py';
> d=open(p,'rb').read(); open(p,'wb').write(d.replace(b'
',b'
'))"`.
> Arreglo definitivo para ese clon: `git config core.autocrlf false` y volver a
> hacer checkout. Los `.sh` no sufren porque `.gitattributes` ya les fuerza `eol=lf`.

Salidas en `build/SBY_GPS_INS/bin/`:
- `ardurover.apj` → update por USB (MAVLink / uploader.py).
- `ardurover.bin` → app cruda.
- `ardurover_with_bl.hex` → **imagen combinada (bootloader+app)** para SWD. La genera `waf` automáticamente.
- `ardurover_with_bl.bin` → imagen combinada para DFU. **`waf` NO la genera** (ver abajo).

### `Tools/scripts/sby_release.py` — los tres ficheros de una sola pasada

Script que compila y deja **los tres formatos juntos** en `dist/`, en vez de tener que
sacarlos uno a uno. **Un solo comando, también desde Windows:**

```powershell
python Tools\scripts\sby_release.py
```

Detecta que waf necesita POSIX y **delega la compilación en WSL sin que tengas que entrar
ahí**; luego empaqueta en Windows. Desde Linux/WSL funciona igual, sin intermediario.

```bash
python3 Tools/scripts/sby_release.py --skip-build   # no compilar, solo empaquetar
python3 Tools/scripts/sby_release.py --bootloader   # recompilar tambien el bootloader
python3 Tools/scripts/sby_release.py -o "D:/ruta/dist"
python3 Tools/scripts/sby_release.py --no-wsl       # no delegar en WSL
python3 Tools/scripts/sby_release.py --distro Ubuntu-22.04
```

Busca el toolchain dentro de WSL en `$HOME/opt/gcc-arm-none-eabi-*/bin` (donde lo deja la
receta de arriba) y avisa con un mensaje claro si no lo encuentra. Se puede lanzar desde
cualquier directorio: localiza la raíz del repo por su cuenta (sube buscando el `wscript`
junto a `Tools/ardupilotwaf/`), y `dist/` sale siempre en la raíz del repo.

#### Qué recompila y cuánto tarda (medido en esta placa)

waf es incremental, así que **no hay que pensar en qué recompilar**: se lanza el script y ya.

| Qué cambiaste | Ficheros recompilados | Tiempo |
|---------------|----------------------|--------|
| Nada | 0 | ~85 s |
| Un `.cpp` | ese fichero | ~90 s |
| `hwdef.dat` / `defaults.parm` | ~1044 (casi todo incluye `hwdef.h`) | ~10 min |

> ⚠️ **Por qué el script lanza `waf configure` siempre:** `waf rover` **NO** detecta
> cambios en `hwdef.dat` — comprobado: editas un pin, recompila sin quejarse y te entrega un
> binario que **ignora el cambio**. Solo `configure` regenera `hwdef.h`. Cuesta ~5 s y no
> invalida nada: si el `hwdef.h` sale idéntico, waf recompila **0** ficheros (las firmas de
> waf son por contenido, no por fecha).

> El suelo de ~85 s sin cambios no es compilar: es waf recorriendo las ~1000 firmas sobre
> `/mnt/c` (el 9p de WSL es lento con muchos ficheros pequeños) más el relink, que ArduPilot
> marca `always_run`. Se bajaría bastante moviendo el árbol al disco nativo de WSL.

Reproducibilidad verificada: cambiar un fuente y revertirlo devuelve el binario al
**mismo SHA-256** de partida.

| Fichero | Para grabar con |
|---------|-----------------|
| `ardurover_with_bl.hex` | **ST-LINK / SWD** (STM32CubeProgrammer) |
| `ardurover_with_bl.bin` | **DFU** (dfu-util) y el bootloader de ROM por UART (tras `$GO_BOOT`) |
| `ardurover.apj` | **ArduPilot** (uploader.py / Mission Planner) |
| `manifest.json` | commit, tamaños y SHA-256 de cada uno (incluido el de la app suelta) |

> La app cruda (`ardurover.bin`) **no se copia a `dist/` a propósito**. Sería un segundo
> `.bin` de nombre casi idéntico al combinado pero que va en **`0x08010000`** en vez de
> `0x08000000`: grabarlo por error por DFU machaca el bootloader y la placa solo se
> recupera por SWD. Así en la carpeta hay **un solo `.bin`, y siempre va en `0x08000000`**.
> Es el mismo criterio que sigue `make_intel_hex.py` de ArduPilot al emitir un único `.hex`.
> Si alguna vez hace falta, está en `build/SBY_GPS_INS/bin/`.

El `.bin` combinado lo arma el propio script (bootloader + relleno `0xFF` hasta los 64 KB
de `FLASH_RESERVE_START_KB` + app), que es exactamente lo que sale de
`arm-none-eabi-objcopy -I ihex -O binary --gap-fill 0xFF ardurover_with_bl.hex ...`
— comprobado byte a byte. Layout: bootloader en los primeros 64 KB, app en 0x08010000.

Antes de escribir nada, el script **verifica que los tres lleven el mismo firmware**:
descomprime la imagen del `.apj` y la compara con el `.bin`, parsea el `.hex` y comprueba
que el bootloader esté en `0x08000000` y la app en `0x08010000` byte a byte, y avisa si el
árbol tiene cambios sin commitear. Si algo no cuadra, aborta sin generar nada.
Solo necesita Python 3 (sin dependencias) para la parte de empaquetado; para compilar,
el toolchain ARM en WSL como arriba.

- **1ª vez / recuperación (DFU del ROM):** BOOT0 ALTO + reset → `0483:df11`. `dfu-util -a 0 -d 0483:df11 -s 0x08000000:leave -D ardurover_with_bl.bin`. BOOT0 BAJO + reset.
- **Actualizaciones (bootloader USB ya instalado): SIN BOOT0.**
  - **uploader.py (CLI, siempre confiable):** `python Tools/scripts/uploader.py --port COMx ardurover.apj`. Manda el reboot-a-bootloader a ciegas y sincroniza; **graba siempre** (no compara CRC).
  - **Mission Planner (GUI, confirmado OK):** Setup → Install Firmware → **Load custom firmware** → `ardurover.apj`. MP envía `PREFLIGHT_REBOOT_SHUTDOWN param1=3`, el bootloader retiene, MP detecta *board type 5400 / blrev 5*, compara CRC y hace **Erase → Program → Verify**.
- **Producción en masa:** SWD con STM32CubeProgrammer + ST-Link (gang programming).
  **Comprobado en placa (2026-08-31)** con una ST-LINK V3MINI:

  ```bash
  STM32_Programmer_CLI -c port=SWD mode=UR -w dist/ardurover_with_bl.hex -v -rst
  ```

  Aquí va el **`.hex`**, no el `.bin`: CubeProgrammer parsea el Intel HEX y saca de ahí las
  direcciones, así que no hay que indicarle ninguna. Graba bootloader + app de una vez
  (~11 s de descarga + 2 s de verificación).

  Dos cosas que hay que saber, ambas verificadas:
  - **`mode=UR` (under reset) es obligatorio.** Con `mode=HOTPLUG` la sonda no engancha
    (`Unable to get core ID`): con el firmware corriendo, el núcleo duerme en el hilo idle
    y no se puede adjuntar en caliente.
  - Al terminar aparece **`MCU Reset / Error: Unable to run MCU! / Error code: 19`**.
    Es **cosmético**: el `Download verified successfully` previo es el que cuenta, el reset
    sí ocurre y la placa arranca (comprobado: emite NMEA a 10 Hz justo después). El error
    es de CubeProgrammer al intentar reengancharse tras soltar el reset. o DFU con jig BOOT0. Grabar siempre la **imagen combinada** (bootloader+app) para dejar la placa actualizable por USB.

### ⚠️ Troubleshooting Mission Planner

- **"MP resetea el micro pero no graba / se queda buscando puerto"** → casi siempre es que el `.apj` tiene **el mismo CRC** que el firmware ya grabado. MP lo detecta (`FW File 0x... == Current 0x...`) y **NO regraba** (muestra un cartel de "firmware idéntico"). **No es una falla** — es correcto. Para forzar una grabación, subir un firmware realmente distinto (cualquier cambio de código cambia el CRC).
- **USB "mudo" tras varios intentos fallidos** → el CDC puede quedar trabado (0 bytes, sin responder). Solución: **power-cycle físico** (desenchufar/enchufar el USB).
- **Ruido en el escaneo de puertos** → los COM de **Bluetooth** (p.ej. COM4/COM7) dan "access denied" y ensucian la búsqueda. Conviene **apagar Bluetooth** al flashear.
- Identidad: VID `0x1209` / PID `0x5741`, board_id **5400**, bootloader **blrev 5**.

## 8. Pendientes

- Verificar en la placa G3.1 real que la **ADIS (SPI1) detecte** (caveat driver) y que ambas IMUs entren al EKF3.
- Ajustar **rotaciones** de ADIS y BMI088 en banco.
- Verificar el **age NMEA** con el mosaic-G5 conectado y RTK/DGNSS activo.
- CAN, UARTs extra (USART3 / UART4), RTCM-in de USART1: sin usar por ahora (agregar según necesidad).

### ⚠️ BUG CONOCIDO: el PPS no se usa (detectado 2026-08-31)

El `hwdef.dat` dice que el flanco PPS sella el instante del fix para el EKF. **No ocurre.**

La interrupción del PPS se engancha en un único sitio, dentro del backend **UBLOX**:

```
libraries/AP_GPS/AP_GPS_UBLOX.cpp:1274
    attach_interrupt(HAL_GPIO_PPS, ...&AP_GPS_UBLOX::pps_interrupt..., INTERRUPT_FALLING)
```

Esta placa fuerza `GPS1_TYPE=5` (backend **NMEA**), así que el driver UBLOX nunca se
instancia y **nadie engancha la interrupción**. Consecuencias, ambas confirmadas sobre el
firmware en marcha:

- Los `NAMED_VALUE_FLOAT` de diagnóstico `PPS` y `PPSU` salen **siempre 0** (26 muestras
  capturadas por MAVLink, `min=0 max=0`).
- El sellado de tiempo genérico de `GPS_Backend.cpp:251` hace
  `if (_last_pps_time_us != 0 && fix >= 2D)`, y `_last_pps_time_us` **solo lo escribe la ISR
  de UBLOX** → la condición nunca se cumple y el PPS **no entra en la solución**.

Arreglo (pendiente): mover el `attach_interrupt` a un sitio agnóstico del backend
(`AP_GPS::init()`, o el propio backend NMEA) escribiendo el `_last_pps_time_us` de la clase
base `AP_GPS_Backend`. La parte genérica de `GPS_Backend.cpp` ya sirve para cualquier
backend; lo único mal ubicado es el enganche de la interrupción.

> Mientras no se arregle, los contadores `PPS`/`PPSU` que publica `AP_NMEA_SBY_INS` no
> significan nada en esta placa: un 0 NO indica que falte el pulso en PC4.
