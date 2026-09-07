// permitir funciones double (igual que AP_NMEA_Output) para el formateo de lat/lng
#define AP_MATH_ALLOW_DOUBLE_FUNCTIONS 1

#include "AP_NMEA_SBY_INS.h"

#if AP_NMEA_SBY_INS_ENABLED

#include <AP_Math/AP_Math.h>
#include <AP_Math/definitions.h>
#include <AP_RTC/AP_RTC.h>
#include <AP_GPS/AP_GPS.h>
#include <AP_AHRS/AP_AHRS.h>
#include <AP_InertialSensor/AP_InertialSensor.h>
#include <AP_SerialManager/AP_SerialManager.h>
#include <AP_Common/NMEA.h>
#include <AP_NavEKF/AP_Nav_Common.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

extern const AP_HAL::HAL& hal;

// LEDs de estado activos en alto por defecto (1=encendido). Override en hwdef si fuera al reves.
#ifndef SBY_LED_ACTIVE_HIGH
#define SBY_LED_ACTIVE_HIGH 1
#endif
#if SBY_LED_ACTIVE_HIGH
#define SBY_LED_ON  1
#define SBY_LED_OFF 0
#else
#define SBY_LED_ON  0
#define SBY_LED_OFF 1
#endif

/*
  ============================================================================
  ADAPTACION DE COMPATIBILIDAD  -  NO SUBIR NUNCA A ARDUPILOT UPSTREAM
  ============================================================================
  El tipo que devuelve AP_GPS::status() cambio de nombre entre las dos lineas
  de ArduPilot que usa SBY:

      Rover-4.7.x   ->  enum  AP_GPS::GPS_Status        (GPS_OK_FIX_3D_...)
      master        ->  enum class AP_GPS_FixType       (AP_GPS_FixType::...)

  Los VALORES NUMERICOS son identicos en ambas (0..8); solo cambian los nombres.
  Ademas master conserva los nombres viejos como alias:

      // Aliases for AP_GPS_FixType values, for backwards compatibility
      static constexpr uint8_t GPS_OK_FIX_3D_RTK_FIXED = (uint8_t)AP_GPS_FixType::RTK_FIXED;

  Por eso este archivo usa los NOMBRES VIEJOS comparados como uint8_t: asi el
  MISMO codigo compila en Rover-4.7.x y en master, sin ningun #if.

  REGLA PARA EL EQUIPO: esta adaptacion es exclusiva del fork de SBY. NO tiene
  sentido proponerla a ArduPilot upstream (alli el enum nuevo es el correcto) y
  NO debe incluirse en ningun pull request hacia ArduPilot/ardupilot.
  ============================================================================
*/

const AP_Param::GroupInfo AP_NMEA_SBY_INS::var_info[] = {
    // @Param: RATE_MS
    // @DisplayName: SBY NMEA output period
    // @Description: Periodo de emision de las sentencias NMEA (GNGGA + PASHR) por el puerto SBY_INS (SERIALx_PROTOCOL=100), en milisegundos. 100 ms = 10 Hz (igual que el receptor, configurado con msec100). Minimo efectivo 20 ms (la tarea del scheduler corre a 50 Hz).
    // @Units: ms
    // @Range: 20 10000
    // @User: Standard
    AP_GROUPINFO("RATE_MS", 1, AP_NMEA_SBY_INS, _interval_ms, AP_NMEA_SBY_INS_INTERVAL_MS_DEFAULT),

    AP_GROUPEND
};

void AP_NMEA_SBY_INS::init()
{
    const AP_SerialManager& sm = AP::serialmanager();

    _boot_request_ms = 0;
    memset(_rx_len, 0, sizeof(_rx_len));

    _num_outputs = 0;
    for (uint8_t i = 0; i < ARRAY_SIZE(_uart); i++) {
        _uart[i] = sm.find_serial(AP_SerialManager::SerialProtocol_NMEA_SBY_INS, i);
        if (_uart[i] == nullptr) {
            break;
        }
        _num_outputs++;
    }

#if defined(SBY_LED_RED_PIN) && defined(SBY_LED_GREEN_PIN) && defined(SBY_LED_BLUE_PIN)
    hal.gpio->pinMode(SBY_LED_RED_PIN,   HAL_GPIO_OUTPUT);
    hal.gpio->pinMode(SBY_LED_GREEN_PIN, HAL_GPIO_OUTPUT);
    hal.gpio->pinMode(SBY_LED_BLUE_PIN,  HAL_GPIO_OUTPUT);
#endif
}

// LEDs de estado: rojo (energizado), verde (INS), azul (GPS).
void AP_NMEA_SBY_INS::update_leds()
{
#if defined(SBY_LED_RED_PIN) && defined(SBY_LED_GREEN_PIN) && defined(SBY_LED_BLUE_PIN)
    const uint32_t now = AP_HAL::millis();
    const bool blink_1hz = (now % 1000) < 500;   // 1 Hz  (parpadeo cada 1 s)
    const bool blink_2hz = (now % 500)  < 250;   // 2 Hz  (cada 500 ms)

    // ROJO (PB0): fijo encendido al energizar.
    hal.gpio->write(SBY_LED_RED_PIN, SBY_LED_ON);

    // VERDE (PB1, sobre la IMU): off=sin IMU, 1Hz=solucion parcial del INS, fijo=full navigation.
    bool green_on;
    if (AP::ins().get_accel_count() == 0) {
        green_on = false;                                  // no hay IMU
    } else {
        nav_filter_status fs {};
        AP::ahrs().get_filter_status(fs);
        const bool full_nav = fs.flags.attitude && fs.flags.horiz_pos_abs && fs.flags.vert_pos;
        green_on = full_nav ? true : blink_1hz;            // full=fijo, parcial=1Hz
    }
    hal.gpio->write(SBY_LED_GREEN_PIN, green_on ? SBY_LED_ON : SBY_LED_OFF);

    // AZUL (PB2, sobre el GPS): off=<3D, 1Hz=SPP(3D), 500ms=DGNSS/float, fijo=RTK fixed.
    bool blue_on;
    // nombres viejos + uint8_t: compila en 4.7.x y en master (ver cabecera)
    switch ((uint8_t)AP::gps().status()) {
    case AP_GPS::GPS_OK_FIX_3D_RTK_FIXED:
        blue_on = true;            break;                  // RTK fixed: fijo
    case AP_GPS::GPS_OK_FIX_3D_DGPS:
    case AP_GPS::GPS_OK_FIX_3D_RTK_FLOAT:
        blue_on = blink_2hz;       break;                  // DGNSS/float: 500 ms
    case AP_GPS::GPS_OK_FIX_3D:
        blue_on = blink_1hz;       break;                  // SPP (3D): 1 Hz
    default:
        blue_on = false;           break;                  // NO_GPS/NO_FIX/2D: apagado
    }
    hal.gpio->write(SBY_LED_BLUE_PIN, blue_on ? SBY_LED_ON : SBY_LED_OFF);
#endif
}

// ==========================================================================
// ---- Recepcion de comandos NMEA por el puerto SBY_INS --------------------
// ==========================================================================
// Se escuchan los MISMOS puertos por los que sale el GNGGA/PASHR (SERIAL1 =
// USART1 en la G3.1). Solo se atiende $GO_BOOT; el resto del trafico (RTCM que
// entra por ese net hacia el Septentrio, sentencias sueltas, ruido) se descarta
// silenciosamente porque no pasa la validacion de checksum NMEA.

// checksum NMEA: XOR de todos los bytes entre '$' y '*' (ambos excluidos)
static uint8_t sby_nmea_checksum(const char* s, uint16_t len)
{
    uint8_t crc = 0;
    for (uint16_t i = 0; i < len; i++) {
        crc ^= (uint8_t)s[i];
    }
    return crc;
}

// convierte dos digitos hex ASCII en un byte. false si alguno no es hex.
static bool sby_hex2(char hi, char lo, uint8_t& out)
{
    uint8_t v = 0;
    const char in[2] = { hi, lo };
    for (uint8_t i = 0; i < 2; i++) {
        const char c = in[i];
        uint8_t d;
        if (c >= '0' && c <= '9')      { d = c - '0'; }
        else if (c >= 'A' && c <= 'F') { d = c - 'A' + 10; }
        else if (c >= 'a' && c <= 'f') { d = c - 'a' + 10; }
        else { return false; }
        v = (v << 4) | d;
    }
    out = v;
    return true;
}

// Lee los bytes disponibles y arma lineas completas terminadas en CR o LF.
// Llamada a 50 Hz (antes del gate de _interval_ms), no cada _interval_ms.
void AP_NMEA_SBY_INS::read_input()
{
    for (uint8_t i = 0; i < _num_outputs; i++) {
        uint32_t n = _uart[i]->available();
        // tope por pasada: a 115200 caben ~230 bytes entre llamadas de 20 ms,
        // 256 vacia el buffer sin monopolizar la tarea del scheduler.
        if (n > 256) {
            n = 256;
        }
        for (uint32_t j = 0; j < n; j++) {
            uint8_t b;
            if (!_uart[i]->read(b)) {
                break;
            }
            const char c = (char)b;
            if (c == '$') {
                // inicio de trama: lo acumulado antes era basura
                _rx_len[i] = 0;
            }
            if (c == '\r' || c == '\n') {
                if (_rx_len[i] > 0) {
                    _rx_buf[i][_rx_len[i]] = '\0';
                    handle_sentence(_rx_buf[i], i);
                    _rx_len[i] = 0;
                }
                continue;
            }
            if (_rx_len[i] < AP_NMEA_SBY_INS_RX_BUFFER - 1) {
                _rx_buf[i][_rx_len[i]++] = c;
            } else {
                // trama mas larga de lo esperado: descartar y resincronizar
                _rx_len[i] = 0;
            }
        }
    }
}

// Valida el checksum y despacha. 'sentence' es la linea sin CR/LF.
void AP_NMEA_SBY_INS::handle_sentence(const char* sentence, uint8_t port_idx)
{
    const uint16_t len = strlen(sentence);

    // formato minimo: "$T*hh"
    if (len < 5 || sentence[0] != '$' || sentence[len - 3] != '*') {
        return;
    }

    // "XX" desactiva la comprobacion (permite mandar comandos a mano por
    // terminal); es lo mismo que acepta el firmware de test de SBY.
    const char hi = sentence[len - 2];
    const char lo = sentence[len - 1];
    if (!(hi == 'X' && lo == 'X')) {
        uint8_t rx_crc;
        if (!sby_hex2(hi, lo, rx_crc)) {
            return;
        }
        // payload: entre '$' (exclusive) y '*' (exclusive)
        if (rx_crc != sby_nmea_checksum(&sentence[1], len - 4)) {
            return;
        }
    }

    // tipo = entre '$' y la primera ',' (o el '*' si la trama no lleva comas)
    const uint8_t TYPE_MAX = 16;
    char type[TYPE_MAX];
    uint8_t t = 0;
    for (uint16_t i = 1; i < len && t < TYPE_MAX - 1; i++) {
        if (sentence[i] == ',' || sentence[i] == '*') {
            break;
        }
        type[t++] = sentence[i];
    }
    type[t] = '\0';

    // La herramienta de SBY manda "$GO_BOOT,*6D" (con coma y campo vacio); se
    // acepta tambien "$GO_BOOT*41" sin coma.
    if (strcmp(type, "GO_BOOT") == 0) {
        go_boot(port_idx);
    }
}

/*
  $GO_BOOT: dejar el micro en el bootloader de ROM (AN3155) para grabar por UART.

  El hardware de la G3.1 lleva el pin de BOOT0 a un capacitor: poniendo el GPIO
  SBY_GO_BOOT_PIN (PB3) en alto se carga, y la carga MANTIENE BOOT0 en alto
  mientras dura el reset. Al arrancar, el micro entra en el bootloader de ROM en
  vez de en el firmware, y la herramienta del PC graba por USART1 a 115200 8-E-1.

  Secuencia (identica a la del firmware de test de SBY, que es la que espera
  la herramienta del PC):
    1. responder "$GO_BOOT*41"
    2. poner el GPIO de BOOT0 en alto (carga del capacitor)
    3. esperar 3 s -> se hace en check_pending_boot(), NO bloqueando aqui:
       una espera de 3 s dentro de una tarea del scheduler dispararia el watchdog
    4. reset
*/
void AP_NMEA_SBY_INS::go_boot(uint8_t port_idx)
{
#ifdef SBY_GO_BOOT_PIN
    // 1) ACK con la trama EXACTA que espera la herramienta del PC.
    //    Se responde SIEMPRE, tambien a los reintentos: la herramienta manda el
    //    comando hasta 3 veces y aborta si un intento se queda sin confirmacion,
    //    asi que callarse en el 2do/3ro la haria fallar aunque el reset ya
    //    estuviera armado. Lo que NO se re-arma es la cuenta de 3 s.
    _uart[port_idx]->write("$GO_BOOT*41\r\n");
    _uart[port_idx]->flush();

    if (_boot_request_ms != 0) {
        return;   // ya armado: no reiniciar la cuenta atras
    }

    // 2) cargar el capacitor de BOOT0
    hal.gpio->pinMode(SBY_GO_BOOT_PIN, HAL_GPIO_OUTPUT);
    hal.gpio->write(SBY_GO_BOOT_PIN, 1);

    // 3) el reset se dispara en check_pending_boot()
    _boot_request_ms = AP_HAL::millis();
    if (_boot_request_ms == 0) {
        _boot_request_ms = 1;   // 0 esta reservado para "sin peticion"
    }
#else
    (void)port_idx;   // placa sin circuito de BOOT0: comando ignorado
#endif
}

// Ejecuta el reset cuando pasaron los 3 s desde el ACK. No retorna.
void AP_NMEA_SBY_INS::check_pending_boot()
{
#ifdef SBY_GO_BOOT_PIN
    if (_boot_request_ms == 0) {
        return;
    }
    if (AP_HAL::millis() - _boot_request_ms < AP_NMEA_SBY_INS_GO_BOOT_DELAY_MS) {
        return;
    }
    hal.scheduler->reboot(false);
#endif
}

void AP_NMEA_SBY_INS::update()
{
    // LEDs de estado: actualizar SIEMPRE (independiente de que haya o no salida NMEA).
    update_leds();

    if (_num_outputs == 0) {
        return;
    }

    // Entrada de comandos y reset diferido: a 50 Hz, NO cada _interval_ms.
    read_input();
    check_pending_boot();

    // periodo configurable (parametro SBYN_RATE_MS), limitado a 20..10000 ms
    const uint32_t interval_ms = constrain_int16(_interval_ms.get(), 20, 10000);

    const uint32_t now_ms = AP_HAL::millis();
    if ((now_ms - _last_run_ms) < interval_ms) {
        return;
    }
    _last_run_ms = now_ms;

    // hora UTC desde el RTC. Si aun no hay hora del GPS, time_usec=0 y se emite
    // igual (el campo de hora sale como 000000.00); asi la salida funciona en banco
    // sin fix, con la actitud y los estados del EKF en el PASHR.
    uint64_t time_usec = 0;
    AP::rtc().get_utc_usec(time_usec);
    const time_t time_sec = time_usec / 1000000;
    struct tm tmd {};
    struct tm* tm = gmtime_r(&time_sec, &tmd);

    char tstring[10];
    hal.util->snprintf(tstring, sizeof(tstring), "%02u%02u%05.2f",
                       tm->tm_hour, tm->tm_min,
                       tm->tm_sec + (time_usec % 1000000) * 1.0e-6);

    auto &ahrs = AP::ahrs();
    const auto &gps = AP::gps();
    const uint8_t gps_status = (uint8_t)gps.status();   // ver cabecera de compatibilidad

    // ---- POSICION FUSIONADA POR EL EKF/INS (no GPS crudo) ----
    // get_location() devuelve la solucion del EKF (con dead-reckoning),
    // a diferencia de gps.location() que seria el GPS crudo.
    Location loc;
    const bool pos_valid = ahrs.get_location(loc);

    // latitud
    char lat_string[13];
    double deg = fabs(loc.lat * 1.0e-7f);
    double min_dec = ((fabs(loc.lat) - (unsigned)deg * 1.0e7)) * 60 * 1.e-7f;
    hal.util->snprintf(lat_string, sizeof(lat_string), "%02u%08.5f,%c",
                       (unsigned)deg, min_dec, loc.lat < 0 ? 'S' : 'N');

    // longitud
    char lng_string[14];
    deg = fabs(loc.lng * 1.0e-7f);
    min_dec = ((fabs(loc.lng) - (unsigned)deg * 1.0e7)) * 60 * 1.e-7f;
    hal.util->snprintf(lng_string, sizeof(lng_string), "%03u%08.5f,%c",
                       (unsigned)deg, min_dec, loc.lng < 0 ? 'W' : 'E');

    uint32_t space_required = 0;

    // ================= GNGGA (posicion del EKF) =================
    // Calidad del fix; 6 = INS dead reckoning cuando no hay GPS pero el EKF
    // mantiene posicion valida.
    uint8_t fix_quality;
    switch (gps_status) {
    default:
    case AP_GPS::NO_GPS:
    case AP_GPS::NO_FIX:
    case AP_GPS::GPS_OK_FIX_2D:
        fix_quality = pos_valid ? 6 : 0;
        break;
    case AP_GPS::GPS_OK_FIX_3D:
        fix_quality = 1;
        break;
    case AP_GPS::GPS_OK_FIX_3D_DGPS:
        fix_quality = 2;
        break;
    case AP_GPS::GPS_OK_FIX_3D_RTK_FLOAT:
        fix_quality = 5;
        break;
    case AP_GPS::GPS_OK_FIX_3D_RTK_FIXED:
        fix_quality = 4;
        break;
    }

    // Campo 13 del GGA = age of differential/RTK corrections (segundos). El
    // backend NMEA lo parsea del GGA del mosaic-G5 y lo deja en rtk_age_ms.
    // Vacio si no hay correcciones activas (rtk_age_ms == 0).
    char age_string[12] = "";
    const uint32_t rtk_age_ms = gps.get_rtk_age_ms();
    if (rtk_age_ms > 0 && rtk_age_ms != 0xFFFFFFFFU) {
        hal.util->snprintf(age_string, sizeof(age_string), "%.1f", rtk_age_ms * 0.001f);
    }

    // Talker "GN" fijo (multi-constelacion). La sentencia se GENERA aqui a partir
    // del EKF, no se reenvia la del receptor, asi que el prefijo no depende de lo
    // que llegue por el puerto del mosaic (GP/GN/GL/GA...).
    char gga[100];
    const uint16_t gga_length = nmea_printf_buffer(gga, sizeof(gga),
                                "$GNGGA,%s,%s,%s,%01d,%02d,%04.1f,%07.2f,M,0.0,M,%s,",
                                tstring,
                                lat_string,
                                lng_string,
                                fix_quality,
                                gps.num_sats(),
                                gps.get_hdop() * 0.01,
                                loc.alt * 0.01f,
                                age_string);
    space_required += gga_length;

    // ================= PASHR (actitud del EKF + estados del filtro) =================
    // ANGULOS EN RADIANES, rango [-pi, pi], 3 decimales.
    // El PASHR estandar los define en grados; aqui se emiten en radianes a
    // proposito, igual que hace el firmware SBY del Trimble/mosaic (que es lo
    // que consume el software de SBY). El heading se envuelve a [-pi, pi]
    // (equivale al "if (val > 180) val -= 360" de aquel firmware), no a [0, 2pi).
    const float roll_rad  = wrap_PI(ahrs.get_roll_rad());
    const float pitch_rad = wrap_PI(ahrs.get_pitch_rad());
    const float yaw_rad   = wrap_PI(ahrs.get_yaw_rad());
    const float heave_m   = 0;   // heave va en METROS: no se convierte

    // campos de precision (tambien en radianes; hoy siempre 0)
    const float roll_rad_accuracy = 0;
    const float pitch_rad_accuracy = 0;
    const float heading_rad_accuracy = 0;

    // --- Campo 10: HEALTH del filtro Kalman (EKF) ---
    const uint8_t ekf_health = ahrs.healthy() ? 1 : 0;

    // --- Campo 11: bitmask de estados del filtro (get_filter_status) ---
    // nav_filter_status.value es uint32 (bits 0..18): attitude, horiz_vel, vert_vel,
    // horiz_pos_rel, horiz_pos_abs, vert_pos, terrain_alt, const_pos_mode, ...,
    // using_gps(13), gps_glitching(14), gps_quality_good(15), initalized(16),
    // rejecting_airspeed(17), dead_reckoning(18). Se emite el valor COMPLETO de 32
    // bits (no truncar a 16: se perderian initalized y dead_reckoning).
    nav_filter_status filt_status {};
    ahrs.get_filter_status(filt_status);
    const uint32_t ekf_status_bits = filt_status.value;

    char pashr[110];
    const uint16_t pashr_length = nmea_printf_buffer(pashr, sizeof(pashr),
                            "$PASHR,%s,%.3f,T,%c%.3f,%c%.3f,%c%.2f,%.3f,%.3f,%.3f,%u,%u",
                            tstring,
                            yaw_rad,                                 // rumbo verdadero (rad)
                            roll_rad < 0 ? '-' : '+',  fabs(roll_rad),
                            pitch_rad < 0 ? '-' : '+', fabs(pitch_rad),
                            heave_m < 0 ? '-' : '+',   fabs(heave_m),   // metros
                            roll_rad_accuracy,
                            pitch_rad_accuracy,
                            heading_rad_accuracy,
                            (unsigned)ekf_health,        // campo 10
                            (unsigned)ekf_status_bits);  // campo 11
    space_required += pashr_length;

    // ---- emitir a todos los puertos asignados ----
    for (uint8_t i = 0; i < _num_outputs; i++) {
        if (_uart[i]->txspace() < space_required) {
            continue;
        }
        _uart[i]->write(gga);
        _uart[i]->write(pashr);
    }
}

#endif  // AP_NMEA_SBY_INS_ENABLED
