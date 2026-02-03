// ============================================
// filename: lowlevel_serial_csv_pwm_with_timestamp.ino
// Serial line input: "a,b\n" where a,b in [-100..100]
// Output: two complementary PWM pairs:
//   Pair1: (A,B) from 'a'
//   Pair2: (C,D) from 'b'
// Also prints: timestamp_ms,a,b,dutyA,dutyB,dutyC,dutyD
// ============================================

#include <Arduino.h>

// UNO PWM pins
static const uint8_t PIN_A = 3;  // pair1 left
static const uint8_t PIN_B = 5;  // pair1 right
static const uint8_t PIN_C = 6;  // pair2 left
static const uint8_t PIN_D = 9;  // pair2 right

static const long BAUD = 2000000;

// --- line buffer ---
static const uint8_t LINE_MAX = 48;
static char lineBuf[LINE_MAX];
static uint8_t lineLen = 0;

static inline int clamp100(int v) {
  if (v > 100) return 100;
  if (v < -100) return -100;
  return v;
}

static inline uint8_t duty255_from_abs100(int abs_0_100) {
  if (abs_0_100 < 0) abs_0_100 = -abs_0_100;
  if (abs_0_100 > 100) abs_0_100 = 100;
  // round(255 * x / 100)
  return (uint8_t)((255L * abs_0_100 + 50L) / 100L);
}

// Apply one signed command to one output pair (leftPin,rightPin)
// Also returns the actually-written duties for logging.
static void applyPair(uint8_t leftPin, uint8_t rightPin, int cmd_m100_p100,
                      uint8_t &dutyLeftOut, uint8_t &dutyRightOut) {
  cmd_m100_p100 = clamp100(cmd_m100_p100);

  if (cmd_m100_p100 == 0) {
    dutyLeftOut  = 0;
    dutyRightOut = 0;
    analogWrite(leftPin, 0);
    analogWrite(rightPin, 0);
    return;
  }

  uint8_t duty = duty255_from_abs100(abs(cmd_m100_p100));

  if (cmd_m100_p100 > 0) {
    dutyLeftOut  = duty;
    dutyRightOut = 0;
    analogWrite(leftPin, duty);
    analogWrite(rightPin, 0);
  } else {
    dutyLeftOut  = 0;
    dutyRightOut = duty;
    analogWrite(leftPin, 0);
    analogWrite(rightPin, duty);
  }
}

// Parse "a,b" (commas required). Returns true if parsed.
static bool parseLine_ab(const char* s, int &a_out, int &b_out) {
  char *end1 = nullptr;
  long a = strtol(s, &end1, 10);
  if (end1 == s) return false;
  while (*end1 == ' ' || *end1 == '\t') end1++;
  if (*end1 != ',') return false;
  end1++;
  while (*end1 == ' ' || *end1 == '\t') end1++;

  char *end2 = nullptr;
  long b = strtol(end1, &end2, 10);
  if (end2 == end1) return false;
  while (*end2 == ' ' || *end2 == '\t') end2++;

  if (*end2 != '\0' && *end2 != '\r') return false;

  a_out = (int)a;
  b_out = (int)b;
  return true;
}

void setup() {
  pinMode(PIN_A, OUTPUT);
  pinMode(PIN_B, OUTPUT);
  pinMode(PIN_C, OUTPUT);
  pinMode(PIN_D, OUTPUT);

  analogWrite(PIN_A, 0);
  analogWrite(PIN_B, 0);
  analogWrite(PIN_C, 0);
  analogWrite(PIN_D, 0);

  Serial.begin(BAUD);
  Serial.println(F("Ready. Send CSV lines: a,b (each in [-100..100])"));
  Serial.println(F("Log format: t_ms,a,b,dutyA,dutyB,dutyC,dutyD"));
}

void loop() {
  while (Serial.available() > 0) {
    char c = (char)Serial.read();

    if (c == '\n') {
      lineBuf[lineLen] = '\0';

      int a = 0, b = 0;
      uint8_t dutyA=0, dutyB=0, dutyC=0, dutyD=0;

      if (parseLine_ab(lineBuf, a, b)) {
        a = clamp100(a);
        b = clamp100(b);

        // Low-level output
        applyPair(PIN_A, PIN_B, a, dutyA, dutyB);
        applyPair(PIN_C, PIN_D, b, dutyC, dutyD);

        // ---- ADDED: timestamped write log ----
        unsigned long t_ms = millis();
        Serial.print(t_ms); Serial.print(',');
        Serial.print(a);    Serial.print(',');
        Serial.print(b);    Serial.print(',');
        Serial.print(dutyA);Serial.print(',');
        Serial.print(dutyB);Serial.print(',');
        Serial.print(dutyC);Serial.print(',');
        Serial.println(dutyD);
      } else {
        // Parse fail -> fail-safe OFF
        applyPair(PIN_A, PIN_B, 0, dutyA, dutyB);
        applyPair(PIN_C, PIN_D, 0, dutyC, dutyD);

        unsigned long t_ms = millis();
        Serial.print(t_ms); Serial.println(F(",PARSE_FAIL"));
      }

      lineLen = 0;
      break;
    }

    if (c == '\r') continue;

    if (lineLen < LINE_MAX - 1) {
      lineBuf[lineLen++] = c;
    } else {
      // Overflow -> fail-safe OFF + reset
      uint8_t da=0, db=0, dc=0, dd=0;
      applyPair(PIN_A, PIN_B, 0, da, db);
      applyPair(PIN_C, PIN_D, 0, dc, dd);

      unsigned long t_ms = millis();
      Serial.print(t_ms); Serial.println(F(",LINE_OVERFLOW"));

      lineLen = 0;
    }
  }

  delay(0);
}
