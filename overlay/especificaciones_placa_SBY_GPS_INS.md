> ⚠️ **DOCUMENTO DESACTUALIZADO (placa VIEJA).** Describe el hardware anterior
> (STM32F413RG, ADIS en SPI4/PA11, sin USB). **NO aplica a la placa actual G3.1.**
> Pinout y configuración vigentes:
>   - `GPS_G3_1_Conexiones_GPIO.xlsx` (raíz del repo) — pinout autoritativo.
>   - `libraries/AP_HAL_ChibiOS/hwdef/SBY_GPS_INS/README.md` — doc del board.
> Se conserva solo como referencia histórica.

---

## 4. Mapa de pines

STM32F413RG – pines utilizados por el firmware, agrupados por función.

**Consola PC — USART1 (115200 baud, 8N1)**

| Pin  | Señal      | I/O | Descripción                        |
|------|------------|-----|------------------------------------|
| PA9  | USART1_TX  | OUT | TX micro → adaptador USB-UART (PC) |
| PA10 | USART1_RX  | IN  | RX micro ← adaptador USB-UART (PC) |

**GPS — USART2 (9600 baud, 8N1)**

| Pin  | Señal      | I/O | Descripción                        |
|------|------------|-----|------------------------------------|
| PA2  | USART2_TX  | OUT | TX micro → GPS RX   |
| PA3  | USART2_RX  | IN  | RX micro ← GPS TX                  |

**IMU ADIS16467 — SPI4 (≈390 kHz, Mode 3, 16-bit MSB)**

| Pin  | Señal      | I/O | Descripción                        |
|------|------------|-----|------------------------------------|
| PA1  | SPI4_MOSI  | OUT | Datos micro → IMU (DIN)            |
| PA11 | SPI4_MISO  | IN  | Datos IMU → micro (DOUT) ¹         |
| PB13 | SPI4_SCK   | OUT | Reloj SPI                          |
| PA0  | IMU_CS     | OUT | Chip Select (activo-bajo)          |
| PC6  | IMU_RST    | OUT | Reset hardware IMU (activo-bajo)   |
| PC7  | IMU_DR     | IN  | Data Ready IMU (activo-alto)       |

**LED y Bootloader DFU**

| Pin  | Señal      | I/O | Descripción                        |
|------|------------|-----|------------------------------------|
| PB14 | LED        | OUT | Heartbeat 2 Hz vía TIM2 ISR        |
| PB3  | BOOT0_CAP  | OUT | Carga capacitor BOOT0 para DFU ²   |