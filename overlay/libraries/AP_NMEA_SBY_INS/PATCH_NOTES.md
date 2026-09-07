# AP_NMEA_SBY_INS — notas de integración (para actualizar ArduPilot sin sorpresas)

Salida serie personalizada de SBY: emite **GNGGA** y **PASHR** alimentados por el
**EKF/INS** (no por GPS crudo). En el PASHR los campos **10** y **11** llevan
estados del filtro Kalman:

- **Campo 10** = health del filtro → `AP::ahrs().healthy()` (0/1)
- **Campo 11** = bitmask de `AP::ahrs().get_filter_status()` (`nav_filter_status.value`)

### Convenciones de formato (IMPORTANTE, se apartan del NMEA estándar)

- **Talker `GN` fijo.** El GGA se **genera** a partir del EKF, no se reenvía el del
  receptor, así que el prefijo es siempre `$GNGGA` con independencia de lo que emita
  el módulo (`GP`/`GN`/`GL`/`GA`…).
- **PASHR en RADIANES, no en grados.** `heading`, `roll`, `pitch` y los tres campos de
  precisión van en radianes con **3 decimales**; el `heave` sigue en **metros**. El
  heading se envuelve a **[-pi, pi]** (no `[0, 2pi)`).
  El PASHR estándar define esos campos en **grados**: un parser genérico leerá mal esta
  salida. Se hace así a propósito, por compatibilidad con el firmware SBY del
  Trimble/mosaic (`CommandLogic::ProcessSeptHRPData` y las dos rutas Unicore hacen
  exactamente la misma conversión), que es contra lo que está escrito el software de SBY.

### Entrada: comando `$GO_BOOT`

La librería también **escucha** los puertos que reclama y atiende un único comando,
copiado del firmware SBY del Trimble (`CommandLogic::ProcessBootloaderMode`):

```
PC  -> $GO_BOOT,*6D      (también se acepta $GO_BOOT*41 y el bypass de checksum *XX)
FC  -> $GO_BOOT*41       (ACK; se responde a CADA intento, la herramienta reintenta 3 veces)
FC  :  pone SBY_GO_BOOT_PIN en alto -> carga el capacitor de BOOT0
FC  :  a los 3 s -> reset -> el micro arranca en el bootloader de ROM (AN3155)
```

Requiere `define SBY_GO_BOOT_PIN <n>` en el hwdef (en la G3.1 es **PB3**, GPIO 84).
Sin ese define el comando se ignora y la librería compila igual.

La espera de 3 s **no bloquea**: se arma un timestamp y el reset lo dispara
`check_pending_boot()` en una pasada posterior de `update()`. Un `delay(3000)` dentro
de una tarea del scheduler dispararía el watchdog.

El resto del tráfico de entrada (RTCM hacia el Septentrio, sentencias del receptor,
ruido) se descarta: no pasa la validación de checksum NMEA.

Protocolo serie asignado: **`SerialProtocol_NMEA_SBY_INS = 100`** (número alto/privado,
elegido para no colisionar con futuras adiciones de ArduPilot upstream).

## Archivos NUEVOS (no generan conflicto al actualizar)
- `libraries/AP_NMEA_SBY_INS/AP_NMEA_SBY_INS_config.h`
- `libraries/AP_NMEA_SBY_INS/AP_NMEA_SBY_INS.h`
- `libraries/AP_NMEA_SBY_INS/AP_NMEA_SBY_INS.cpp`
- `libraries/AP_NMEA_SBY_INS/PATCH_NOTES.md` (este archivo)
- `libraries/AP_HAL_ChibiOS/hwdef/SBY_GPS_INS/*` (placa propia)
- `Tools/scripts/sby_release.py` (empaquetador .hex/.bin/.apj; prefijo `sby_` para
  distinguirlo de los scripts de upstream al hacer rebase)

NOTA: el auto-glob de `libraries/*` aplica a builds de examples/tests, NO a los
vehículos. Los vehículos compilan una lista curada → ver punto 4.

## Puntos TOCADOS del core (revisar si hay conflicto tras `git rebase` upstream)

1a. **`libraries/AP_SerialManager/AP_SerialManager.h`** — 1 línea:
   se añadió `SerialProtocol_NMEA_SBY_INS = 100,` justo antes de
   `SerialProtocol_NumProtocols`.

1b. **`libraries/AP_SerialManager/AP_SerialManager.cpp`** — 1 línea (la de `@Values`
   del parámetro SERIALx_PROTOCOL): se añadió `, 100:NMEA SBY INS` al final, para que
   la opción aparezca por nombre en el desplegable de Mission Planner.
   OJO: esta línea es la de MAYOR probabilidad de conflicto al actualizar (upstream
   la edita en cada protocolo nuevo). Si choca, reañadir `100:NMEA SBY INS`.

2. **`libraries/AP_Vehicle/AP_Vehicle.h`** — 2 inserciones:
   - `#include <AP_NMEA_SBY_INS/AP_NMEA_SBY_INS.h>` (junto al include de AP_NMEA_Output)
   - miembro, junto al de `nmea`:
     ```cpp
     #if AP_NMEA_SBY_INS_ENABLED
         AP_NMEA_SBY_INS sby_nmea;
     #endif
     ```

3. **`libraries/AP_Vehicle/AP_Vehicle.cpp`** — 3 inserciones:
   - en el `var_info[]` de AP_Vehicle, junto al grupo `NMEA_`:
     ```cpp
     #if AP_NMEA_SBY_INS_ENABLED
         AP_SUBGROUPINFO(sby_nmea, "SBYN_", 60, AP_Vehicle, AP_NMEA_SBY_INS),
     #endif
     ```
     (índice de parámetro **60**, libre; expone el parámetro `SBYN_RATE_MS`.)
   - en `init()`, junto a `nmea.init();`:
     ```cpp
     #if AP_NMEA_SBY_INS_ENABLED
         sby_nmea.init();
     #endif
     ```
   - en la tabla `scheduler_tasks[]`, junto a la tarea de `AP_NMEA_Output`:
     ```cpp
     #if AP_NMEA_SBY_INS_ENABLED
         SCHED_TASK_CLASS(AP_NMEA_SBY_INS, &vehicle.sby_nmea, update, 50, 50, 181),
     #endif
     ```
     (id de scheduler **181**, libre; el NMEA estándar conserva el 180.)

Parámetro expuesto: **`SBYN_RATE_MS`** (periodo de emisión en ms, default **100 = 10 Hz**,
igual que el receptor, configurado con `setNMEAOutput, ..., msec100`).
OJO: si la placa ya tiene un valor guardado en EEPROM (p.ej. 200 de un firmware
anterior), cambiar el default NO lo pisa — hay que poner `SBYN_RATE_MS=100` a mano en
Mission Planner o resetear parámetros.
La salida ya NO requiere hora UTC del GPS: emite siempre (en banco sale el PASHR con
actitud y estados del EKF; la posición del GGA queda en cero hasta tener fix).

3b. **`.gitignore`** — 3 líneas al final: `/dist/`, la carpeta de salida de
   `Tools/scripts/sby_release.py`. Conflicto poco probable (se añade al final del
   fichero); si upstream toca esa zona, reponer la entrada.

4. **`Tools/ardupilotwaf/ardupilotwaf.py`** — 1 línea:
   se añadió `'AP_NMEA_SBY_INS',` a la lista `COMMON_VEHICLE_DEPENDENT_LIBRARIES`
   (justo después de `'AP_NMEA_Output',`). Sin esto, el linker da
   "undefined reference to AP_NMEA_SBY_INS::init/update" porque los vehículos
   solo compilan las librerías de esa lista curada.

Todo está bajo `#if AP_NMEA_SBY_INS_ENABLED`, que por defecto es **0**
(ver `AP_NMEA_SBY_INS_config.h`); solo se activa con `define AP_NMEA_SBY_INS_ENABLED 1`
en el hwdef de la placa. Es decir: estos cambios son **inertes** para cualquier otra
placa/vehículo de ArduPilot.

## Coexistencia
No se desactiva el NMEA estándar (`AP_NMEA_Output`, protocolo 20): ambos conviven.
Esta salida es un protocolo adicional y seleccionable por `SERIALx_PROTOCOL = 100`.

## ⚠️ El riesgo real al actualizar: el fallo SILENCIOSO

De los puntos del core, el más peligroso es el **3** (`AP_Vehicle.cpp`), porque si un
conflicto se resuelve perdiendo una línea, **el firmware compila y enlaza igual**:

| Línea que se pierde | Qué pasa | ¿Avisa? |
|---------------------|----------|---------|
| `SCHED_TASK_CLASS(AP_NMEA_SBY_INS, ...)` | `update()` no corre nunca: sin salida NMEA, sin `$GO_BOOT`, sin LEDs de estado | **NO** — compila limpio |
| `AP_SUBGROUPINFO(sby_nmea, "SBYN_", 60, ...)` | desaparece el parámetro `SBYN_RATE_MS` | **NO** |
| `sby_nmea.init()` | no reclama el puerto: sin salida | **NO** |
| `'AP_NMEA_SBY_INS',` en `ardupilotwaf.py` | error de enlazado | sí, ruidoso |
| `SerialProtocol_NMEA_SBY_INS = 100` | error de compilación | sí, ruidoso |

Comprobación rápida tras cualquier rebase, **antes de grabar nada**: buscar las cadenas en
el binario, que es la prueba de que la librería entró de verdad.

```bash
strings -n 6 build/SBY_GPS_INS/bin/ardurover.bin | grep -E '\$GNGGA|\$PASHR|GO_BOOT'
```

Deben salir las tres: el formato del `$GNGGA`, el del `$PASHR` y el ACK `$GO_BOOT*41`.
Y en la placa, comprobar que sale NMEA a 10 Hz por SERIAL1.

## Flujo recomendado para actualizar ArduPilot
1. `git fetch upstream && git rebase upstream/master` (o merge) sobre tu rama.
2. Si hay conflicto, será en uno de los 3 archivos del core de arriba → reaplicar
   las pocas líneas listadas.
3. Recompilar: `./waf configure --board SBY_GPS_INS && ./waf rover`.
