# SBY_GPS_INS (G3.1) — Patrones y estados de los LEDs

La placa tiene **dos sistemas de LED complementarios**:

- **3 LEDs de estado frontales** (uno por subsistema: Power / IMU / GPS) → lógica propia en `AP_NMEA_SBY_INS::update_leds()`.
- **1 LED RGB a bordo** (estado global de ArduPilot) → notify estándar `RGBLed` / `AP_NOTIFY_GPIO_LED_RGB`.

---

## 1. LEDs de estado frontales — PB0 / PB1 / PB2

- Driver: **ULN2001D**, **activo ALTO** (GPIO en alto → LED encendido).
- Lógica: `libraries/AP_NMEA_SBY_INS/AP_NMEA_SBY_INS.cpp` (`update_leds()`).
- Parpadeos: **1 Hz** = 500 ms encendido / 500 ms apagado · **2 Hz** = 250 ms / 250 ms.

| LED | Pin | Señal | Condición | Patrón |
|-----|-----|-------|-----------|--------|
| 🔴 **Rojo — Power** | PB0 | PW | Placa energizada | **Fijo encendido** (siempre) |
| 🟢 **Verde — IMU / INS** | PB1 | SV | Sin IMU detectada | Apagado |
| | | | Solución INS parcial | Parpadeo **1 Hz** |
| | | | Navegación completa (actitud + pos horiz. abs. + pos vert.) | **Fijo** |
| 🔵 **Azul — GPS** | PB2 | RK | Fix < 3D (sin fix / 2D) | Apagado |
| | | | 3D (SPP, posicionamiento estándar) | Parpadeo **1 Hz** |
| | | | DGNSS o RTK float | Parpadeo **2 Hz** (rápido) |
| | | | RTK fixed | **Fijo** |

**Criterio "navegación completa" (verde fijo):** `attitude && horiz_pos_abs && vert_pos` del filtro EKF.

---

## 2. LED RGB a bordo — PB12 (R) / PB13 (G) / PB14 (B)

- LED1 NH-B1010RGBT-HF, **ánodo común = activo BAJO** (0 = encendido).
- Driver: notify estándar de ArduPilot (`RGBLed::get_colour_sequence()`), igual que un Pixhawk.
- Se evalúa **por prioridad, de arriba hacia abajo** (el primero que aplica gana).

| Prioridad | Estado del sistema | Color · patrón |
|-----------|--------------------|----------------|
| 1 | Inicializando | 🔴↔🔵 **rojo/azul alternando** |
| 2 | Calibración (brújula / ESC / trim / temperatura) | 🔴🔵🟢 **cicla rojo-azul-verde** |
| 3 | Fuga detectada (leak, solo Sub) | ⚪ **blanco** (parpadeo failsafe) |
| 4 | EKF malo (`ekf_bad`) | 🔴 **rojo** (parpadeo failsafe) |
| 5 | GPS glitch | 🔵 **azul** (parpadeo failsafe) |
| 6 | Failsafe de radio / GCS / batería | ⚫ **apagado** |
| 7 | **Armado** + GPS ≥ 3D + ubicación buena | 🟢 **verde fijo** |
| 8 | **Armado** sin GPS / sin ubicación | 🔵 **azul fijo** |
| 9 | Pre-arm fallando | 🟡 **amarillo, doble parpadeo** |
| 10 | Desarmado · GPS ≥ DGPS/RTK + ubicación | 🟢 **verde, parpadeo rápido** (alternado) |
| 11 | Desarmado · GPS ≥ 3D + ubicación | 🟢 **verde, parpadeo lento** |
| 12 | Desarmado · GPS malo / sin ubicación | 🔵 **azul, parpadeo lento** |

### Patrones de parpadeo del RGB
| Patrón | Descripción |
|--------|-------------|
| Fijo (solid) | Encendido continuo |
| Lento (slow) | ~1 destello lento (≈0.8 s ciclo) |
| Rápido / alternado | Alterna color↔apagado rápido |
| Failsafe | Destellos del color de la falla |
| Doble parpadeo (pre-arm) | Dos destellos + pausa (amarillo) |

---

## 3. Lectura rápida (uso normal, sin armar)

| Querés saber… | Mirá… |
|---------------|-------|
| ¿Tiene alimentación? | 🔴 Rojo frontal (fijo) |
| ¿La IMU/INS navega? | 🟢 Verde frontal (fijo = full nav) |
| ¿Calidad del GPS? | 🔵 Azul frontal (fijo = RTK fixed) |
| ¿Estado general / listo para armar? | 🌈 LED RGB (verde parpadeo = listo; azul = sin GPS; amarillo = pre-arm falla) |

> Referencias de código: `AP_NMEA_SBY_INS.cpp::update_leds()` (frontales) · `AP_Notify/RGBLed.cpp` + `RGBLed.h` (RGB). Pines y polaridad en `hwdef.dat`.
