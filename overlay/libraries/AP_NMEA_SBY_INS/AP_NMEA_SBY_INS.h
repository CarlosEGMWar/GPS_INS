#pragma once

#include "AP_NMEA_SBY_INS_config.h"

#if AP_NMEA_SBY_INS_ENABLED

#include <AP_HAL/AP_HAL.h>
#include <AP_Param/AP_Param.h>

// numero maximo de puertos serie que pueden emitir esta salida
#ifndef AP_NMEA_SBY_INS_MAX_OUTPUTS
#define AP_NMEA_SBY_INS_MAX_OUTPUTS 2
#endif

// periodo de emision por defecto (ms). 100 ms = 10 Hz. Configurable: parametro SBYN_RATE_MS.
// Coincide con el receptor: el mosaic-G5 se configura con "setNMEAOutput, ..., msec100".
#ifndef AP_NMEA_SBY_INS_INTERVAL_MS_DEFAULT
#define AP_NMEA_SBY_INS_INTERVAL_MS_DEFAULT 100
#endif

// tamano del buffer de recepcion NMEA por puerto. La trama de comando mas larga
// que se espera es "$GO_BOOT,*6D" (12 bytes); 96 deja margen de sobra.
#ifndef AP_NMEA_SBY_INS_RX_BUFFER
#define AP_NMEA_SBY_INS_RX_BUFFER 96
#endif

// espera entre el ACK de $GO_BOOT y el reset (ms). La herramienta del PC cuenta
// con estos 3 s para cerrar el puerto y reabrirlo a 8-EVEN-1 (AN3155).
#ifndef AP_NMEA_SBY_INS_GO_BOOT_DELAY_MS
#define AP_NMEA_SBY_INS_GO_BOOT_DELAY_MS 3000
#endif

/*
  Salida NMEA personalizada SBY_INS.
  Emite GNGGA y PASHR alimentados por el EKF/INS (no por GPS crudo):
    - GNGGA: posicion/altitud fusionadas (AP::ahrs().get_location()). El talker
      es SIEMPRE "GN" (multi-constelacion), con independencia de lo que emita el
      receptor: la sentencia se genera aqui, no se reenvia la del modulo.
    - PASHR: actitud del EKF en RADIANES (no grados), rango [-pi, pi], 3
      decimales. Ademas codifica estados del filtro Kalman:
        * campo 10 = health del filtro (AP::ahrs().healthy())
        * campo 11 = bitmask de get_filter_status() (nav_filter_status.value)
  Reclama los puertos cuyo SERIALx_PROTOCOL = SerialProtocol_NMEA_SBY_INS (100).
  Coexiste con el NMEA estandar (AP_NMEA_Output); no lo reemplaza.

  Ademas ESCUCHA esos mismos puertos y atiende el comando $GO_BOOT (ver go_boot()).
*/
class AP_NMEA_SBY_INS {
public:
    AP_NMEA_SBY_INS() {
        AP_Param::setup_object_defaults(this, var_info);
    }

    /* Do not allow copies */
    CLASS_NO_COPY(AP_NMEA_SBY_INS);

    // localiza los puertos serie asignados a este protocolo
    void init();

    // arma y emite las sentencias (llamada periodica desde el scheduler)
    void update();

private:
    // maneja los LEDs de estado (rojo energizado, verde INS, azul GPS)
    void update_leds();

    // ---- recepcion de comandos NMEA por los mismos puertos de salida ----
    // lee bytes disponibles y arma lineas terminadas en CR/LF
    void read_input();
    // valida checksum y despacha una sentencia completa (sin CR/LF)
    void handle_sentence(const char* sentence, uint8_t port_idx);
    // atiende $GO_BOOT: ACK + carga del capacitor de BOOT0 + reset diferido
    void go_boot(uint8_t port_idx);
    // ejecuta el reset cuando se cumplen los 3 s desde el ACK
    void check_pending_boot();

public:

    static const struct AP_Param::GroupInfo var_info[];

private:
    // periodo de emision (ms), configurable: parametro SBYN_RATE_MS (200 ms por defecto)
    AP_Int16 _interval_ms;

    uint8_t _num_outputs;
    AP_HAL::UARTDriver* _uart[AP_NMEA_SBY_INS_MAX_OUTPUTS];
    uint32_t _last_run_ms;

    // ---- estado del parser de entrada ----
    char    _rx_buf[AP_NMEA_SBY_INS_MAX_OUTPUTS][AP_NMEA_SBY_INS_RX_BUFFER];
    uint8_t _rx_len[AP_NMEA_SBY_INS_MAX_OUTPUTS];

    // millis() del ACK de $GO_BOOT. 0 = sin peticion pendiente.
    uint32_t _boot_request_ms;
};

#endif  // AP_NMEA_SBY_INS_ENABLED
