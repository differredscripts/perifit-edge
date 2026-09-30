#include <AFMotor.h>
#include <avr/wdt.h>
#include "Config.h"
#include "PE1.h"
#include "LoopHealth.h"

#if !defined(__AVR_ATmega328P__)
#error "This wiring and timer configuration requires an Uno ATmega328P"
#endif

// Runs before C++ constructors. The bootloader must also support watchdog reset.
void earlyWatchdogOff() __attribute__((naked, section(".init3"), used));
void earlyWatchdogOff() { MCUSR = 0; wdt_disable(); }

AF_DCMotor* motors[3];
const uint8_t pwmPins[3] = {11, 3, 6};
PE1 protocol(PE1_MAX_M1, PE1_MAX_M2, PE1_MAX_M3, PE1_TEST_ONLY);
uint8_t txOffset = 0;
LoopHealth health;
#ifdef PE1_WATCHDOG_PROBE
#if PE1_MAX_M1 != 0 || PE1_MAX_M2 != 0 || PE1_MAX_M3 != 0
#error "Watchdog probe must use the locked motor configuration"
#endif
// Diagnostic only: retained RAM makes the deliberate hang run once per marker.
uint32_t watchdogProbeMarker __attribute__((section(".noinit")));
#endif

void pe1Apply(uint8_t one, uint8_t two, uint8_t three) {
  const uint8_t levels[3] = {one, two, three};
  for (uint8_t i = 0; i < 3; ++i) {
    if (levels[i]) {
      motors[i]->run(FORWARD);
      motors[i]->setSpeed(levels[i]);
    } else {
      motors[i]->setSpeed(0);
      motors[i]->run(RELEASE);
      // AFMotor writes OCR2x=0 in fast PWM mode, which can leave a narrow
      // pulse. digitalWrite disconnects the compare output and holds EN low.
      digitalWrite(pwmPins[i], LOW);
    }
  }
  // digitalWrite above disconnects PWM. Reconnect only nonzero channels.
  if (one) TCCR2A |= _BV(COM2A1);
  if (two) TCCR2A |= _BV(COM2B1);
  if (three) TCCR0A |= _BV(COM0A1);
}

void setup() {
  digitalWrite(MOTORENABLE, HIGH); pinMode(MOTORENABLE, OUTPUT); // 74HC595 /OE
  for (uint8_t i = 0; i < 3; ++i) { digitalWrite(pwmPins[i], LOW); pinMode(pwmPins[i], OUTPUT); }
  static AF_DCMotor m1(1, MOTOR12_1KHZ);
  static AF_DCMotor m2(2, MOTOR12_1KHZ);
  // M3 uses OC0A/D6. AFMotor's Uno implementation preserves Timer0's prescaler/millis().
  static AF_DCMotor m3(3, MOTOR34_1KHZ);
  motors[0] = &m1; motors[1] = &m2; motors[2] = &m3;
  protocol.begin();
  Serial.begin(115200, SERIAL_8N1);
  strcpy(protocol.response, "PE1 BOOT 1\n");
  wdt_enable(WDTO_120MS);
}

void loop() {
#ifdef PE1_WATCHDOG_PROBE
  if (Serial.available() > 0 && watchdogProbeMarker != PE1_WATCHDOG_PROBE) {
    watchdogProbeMarker = PE1_WATCHDOG_PROBE;
    Serial.println(F("PE1 FAULT 00000000000000000000000000000000 WATCHDOG_PROBE"));
    Serial.flush(); // Diagnostic build only, 60 bytes at 115200 baud.
#ifdef PE1_TIMEBASE_PROBE
    TIMSK0 &= ~_BV(TOIE0); // Freeze millis(), while leaving loop/UART running.
#else
    for (;;) {} // The hardware watchdog must reset this, then stay responsive.
#endif
  }
#endif
  const uint32_t now = millis();
  protocol.tick(now);
  bool progressed = false;
  if (protocol.pending()) {
    if (Serial.availableForWrite() > 0) {
      Serial.write(protocol.response[txOffset++]);
      progressed = true;
      if (!protocol.response[txOffset]) { protocol.sent(); txOffset = 0; }
    }
  } else if (Serial.available() > 0) {
    protocol.feed(uint8_t(Serial.read()), now);
  }
  if (health.txStalled(now, protocol.pending(), progressed)) protocol.fault(PE1::TX_STALL);
  if (health.clockAdvanced(now)) wdt_reset();
}
