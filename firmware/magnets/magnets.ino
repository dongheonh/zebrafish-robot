// filename: magnet.ino
// 1. Binary packet RX (PC → Arduino):
//   [HEADER][duty_L][duty_H][CRC]  = 4 bytes
// 2. Pin assignment (1 magnet, 2 complementary pins):
//   GP0: duty_L (forward direction)
//   GP1: duty_H (reverse direction)
//   Normal use: one pin active, other = 0
// 3. PWM: 10-bit resolution (0–1023), PWM_FREQ_HZ (tunable below)
// 4. Telemetry TX (Arduino → PC):
//   "timestamp_ms,duty_L,duty_H,pwm_L,pwm_H\n"
// 5. Safety: if no packet received for TIMEOUT_MS, both pins are zeroed.
// 6. Packet parser: latest-value overwrite 

#include <Arduino.h>

// USER SETTINGS
static const uint32_t PWM_FREQ_HZ  = 100000;  // PWM frequency: 100 kHz
static const uint8_t  PWM_BITS     = 10;       // PWM resolution: 10-bit (0–1023)
static const uint32_t SERIAL_BAUD  = 2000000;  // Serial baud rate
static const uint32_t TX_PERIOD_MS = 10;       // Telemetry echo period (ms)
static const uint32_t TIMEOUT_MS   = 500;      // Zero magnet if no RX for this long

static const uint8_t  FRAME_HEADER = 0xAB;     // Binary packet header byte
static const uint16_t PWM_MAX      = (1 << PWM_BITS) - 1;  // 1023 for 10-bit

// Pin assignments
static const uint8_t PIN_L = 0;  // GP0: forward (duty_L)
static const uint8_t PIN_H = 1;  // GP1: reverse (duty_H)

// State 
static volatile uint8_t  g_duty_L     = 0;
static volatile uint8_t  g_duty_H     = 0;
static volatile uint32_t g_last_rx_ms = 0;

// latest-value overwrite 
static void parse_packets() {
    while (Serial.available() >= 4) {
        uint8_t b = Serial.read();
        if (b != FRAME_HEADER) {
            continue;  // re-sync
        }
        if (Serial.available() < 3) break;

        uint8_t duty_L = Serial.read();
        uint8_t duty_H = Serial.read();
        uint8_t crc    = Serial.read();

        if ((duty_L ^ duty_H) != crc) {
            continue;  // corrupted frame
        }

        g_duty_L     = min(duty_L, (uint8_t)100);
        g_duty_H     = min(duty_H, (uint8_t)100);
        g_last_rx_ms = millis();
    }
}

void setup() {
    Serial.begin(SERIAL_BAUD);

    analogWriteFreq(PWM_FREQ_HZ);
    analogWriteResolution(PWM_BITS);

    analogWrite(PIN_L, 0);
    analogWrite(PIN_H, 0);

    g_last_rx_ms = millis();
}

static uint32_t last_tx_ms = 0;

void loop() {
    parse_packets();

    uint32_t now = millis();

    // Safety timeout
    if ((now - g_last_rx_ms) > TIMEOUT_MS) {
        g_duty_L = 0;
        g_duty_H = 0;
    }

    // Apply to pins: map 0..100 → 0..PWM_MAX (10-bit)
    uint16_t pwm_L = (uint16_t)map((long)g_duty_L, 0L, 100L, 0L, (long)PWM_MAX);
    uint16_t pwm_H = (uint16_t)map((long)g_duty_H, 0L, 100L, 0L, (long)PWM_MAX);
    analogWrite(PIN_L, pwm_L);
    analogWrite(PIN_H, pwm_H);

    // Telemetry
    if ((now - last_tx_ms) >= TX_PERIOD_MS) {
        last_tx_ms = now;
        Serial.printf("%lu,%u,%u,%u,%u\n",
            (unsigned long)now,
            (unsigned)g_duty_L, (unsigned)g_duty_H,
            (unsigned)pwm_L,    (unsigned)pwm_H);
    }
}
