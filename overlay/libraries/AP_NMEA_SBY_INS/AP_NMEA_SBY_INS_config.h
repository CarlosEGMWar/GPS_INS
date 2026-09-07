#pragma once

#include <AP_HAL/AP_HAL_Boards.h>
#include <AP_AHRS/AP_AHRS_config.h>

// Salida NMEA personalizada de SBY Technologies (GPGGA + PASHR alimentados
// por el EKF/INS, con estados del filtro Kalman en los campos 10 y 11 del PASHR).
// Desactivada por defecto; se habilita en el hwdef de la placa con:
//     define AP_NMEA_SBY_INS_ENABLED 1
#ifndef AP_NMEA_SBY_INS_ENABLED
#define AP_NMEA_SBY_INS_ENABLED 0
#endif

// Necesita el EKF (AHRS) para obtener posicion/actitud/estado del filtro.
#if AP_NMEA_SBY_INS_ENABLED && !AP_AHRS_ENABLED
#error "AP_NMEA_SBY_INS requiere AP_AHRS_ENABLED"
#endif
