# Cola de parches — SBY_GPS_INS sobre ArduPilot

Estos son **todos** los cambios que el firmware de SBY le hace al código de
ArduPilot: **7 parches, 59 líneas, 11 archivos**. Todo lo demás que necesita la
placa son archivos propios y está en `../overlay/`.

```
overlay/   archivos que NO existen en ArduPilot   ->  se COPIAN   (nunca fallan)
patches/   archivos que SI existen y editamos     ->  se APLICAN  (aqui puede chocar)
```

Versión de ArduPilot sobre la que están hechos: ver `../UPSTREAM`.

---

## Cómo se aplican: cola al estilo quilt

Esto **es** una cola de parches al modelo de quilt, la herramienta que Debian y
el kernel de Linux usan desde hace veinte años para mantener cambios propios
sobre un código ajeno que se mueve:

- El archivo **`series`** define **qué parches hay y en qué orden**.
- Se aplican **uno a uno**, de arriba abajo.
- Si uno falla, **la cola se detiene ahí mismo** y dice cuál. Los anteriores
  quedan aplicados; los posteriores ni se intentan.

Lo hace `../scripts/actualizar.sh`. No hay que aplicarlos a mano.

```bash
while read parche; do
    git apply --3way "patches/$parche"  ||  { echo "FALLO en $parche"; exit 1; }
done < patches/series
```

### La única diferencia con quilt de verdad

quilt aplica con `patch(1)`, que trabaja **por contexto y con *fuzz***: si
ArduPilot movió el código, puede colocar el cambio en el sitio equivocado
**sin avisar**. Aquí se usa `git apply --3way`, que hace un **merge a 3 bandas**
con los blobs reales: o lo coloca bien, o falla y avisa. Nunca a medias.

Mismo modelo mental, mismos archivos, mejor motor.

### Si algún día se prefiere quilt real

Estos archivos son directamente compatibles: `patches/` + `series` es
exactamente el formato que espera quilt. Basta con:

```bash
sudo apt install quilt        # solo en Linux/WSL
quilt push -a                 # aplica toda la cola
quilt pop -a                  # la retira entera
quilt refresh                 # regenera el parche actual tras editarlo
```

| Operación | Con los scripts | Con quilt |
|---|---|---|
| Aplicar todo | `scripts/actualizar.sh` | `quilt push -a` |
| Volver a ArduPilot limpio | `git reset --hard` + `git clean -fd` | `quilt pop -a` |
| Regenerar un parche editado | `git diff HEAD -- <archivos>` | `quilt refresh` |

### El orden

Los 7 parches tocan archivos distintos y no se solapan, así que el orden no es
crítico hoy. Se respeta igual para que el resultado sea **siempre idéntico** y
para que, si algún día dos parches tocaran el mismo archivo, la cola siga
siendo determinista.

---

## Los 7 parches

| # | Parche | Toca | Líneas | ¿Obligatorio? |
|---|--------|------|--------|---------------|
| 1 | `serialmanager-protocolo-100` | `AP_SerialManager.h` `.cpp` | 3 | Sí |
| 2 | `vehicle-registrar-libreria-sby` | `AP_Vehicle.h` `.cpp` | 15 | **Sí, crítico** |
| 3 | `waf-anadir-libreria` | `ardupilotwaf.py` | 1 | Sí |
| 4 | `gps-nmea-age-del-gga` | `AP_GPS.h` `AP_GPS_NMEA.cpp` `.h` | 15 | No, es una función |
| 5 | `ins-adis16467` | `AP_InertialSensor_ADIS1647x.cpp` | 13 | Sí |
| 6 | `chibios-f413-usb-y-dma` | `STM32F413xx.py` | 4 | Sí |
| 7 | `bootloader-f413-y-board-id` | `bl_protocol.cpp` `board_types.txt` | 8 | Sí |

Cada `.patch` lleva **su propia cabecera** explicando qué hace, en qué parte
exacta del archivo va, y qué pasa si falta. Ábrelo con cualquier editor: el
texto de arriba es la explicación, y el `diff --git` de abajo es el cambio.

---

## El parche 0002 es el peligroso

Es el único donde un fallo **no se nota**. Registra la librería en tres sitios
de `AP_Vehicle`, y si un rebase pierde alguna línea:

| Línea que se pierde | Consecuencia | ¿Avisa? |
|---|---|---|
| miembro `sby_nmea` | no compila | Sí, ruidoso |
| `AP_SUBGROUPINFO` `SBYN_` (60) | desaparece el parámetro `SBYN_RATE_MS` | **NO** |
| `sby_nmea.init()` | no reclama el puerto serie | **NO** |
| `SCHED_TASK_CLASS` (181) | `update()` **no corre nunca** | **NO** |

Ese último caso es el peor: el firmware compila, enlaza y arranca, pero se
queda **sin salida NMEA, sin `$GO_BOOT` y sin LEDs de estado**, en silencio.

**Comprobación obligatoria antes de grabar una placa:**

```bash
strings -n 6 build/SBY_GPS_INS/bin/ardurover.bin | grep -E 'GNGGA|PASHR|GO_BOOT'
```

Deben salir las tres. Si falta alguna, la librería no entró.
Esto lo hace automáticamente `../scripts/verificar.sh`.

---

## Identificadores reservados

Estos números son nuestros. Si algún día ArduPilot los ocupa, hay que moverlos:

| Qué | Valor | Dónde | Upstream hoy |
|---|---|---|---|
| Protocolo serie | `100` | `AP_SerialManager.h` | llega a 50 |
| Índice de parámetro | `60` | `AP_Vehicle.cpp` var_info | usa 2–33 |
| Id de tarea del scheduler | `181` | `AP_Vehicle.cpp` | usa 180 |
| Board ID | `AP_HW_SBY_GPS_INS` | `board_types.txt` | libre |

---

## Si un parche falla al actualizar

1. El script se detiene y dice **cuál** parche y **qué archivo**.
2. Abre el `.patch`: la cabecera explica qué hace y dónde va.
3. Aplica el cambio a mano sobre la versión nueva del archivo.
4. Regenera el parche:
   ```bash
   git -C build/ardupilot diff HEAD -- <archivos> > patches/<nombre>.patch
   ```
   (conservando la cabecera de texto)
5. Vuelve a correr `actualizar.sh` desde cero.

Ninguna herramienta resuelve esto sola: si ArduPilot movió el código que
parcheamos, alguien tiene que decidir cómo encaja.

---

## Qué NO va aquí

- **Nada del driver propio.** El `$GNGGA`, el `PASHR` en radianes y el
  `$GO_BOOT` viven enteros en `../overlay/libraries/AP_NMEA_SBY_INS/`. Son
  archivos nuestros, no ediciones a ArduPilot.
- **Nada de la placa.** El `hwdef.dat` y sus parámetros están en
  `../overlay/libraries/AP_HAL_ChibiOS/hwdef/SBY_GPS_INS/`.
- **Binarios.** Un `.patch` es texto. El bootloader compilado va en el overlay.

Regla para decidir dónde va un cambio nuevo: **¿el archivo ya existe en
ArduPilot?** Si no, overlay. Si sí, parche.
