// c++ -std=c++11 -Wall -Wextra -Werror -fsanitize=address,undefined Firmware/Checks.cpp -o /tmp/pe1-checks
#include "PerifitEdgeUno/PE1.h"
#include "PerifitEdgeUno/LoopHealth.h"
#include <assert.h>
#include <chrono>
#include <fcntl.h>
#include <string>
#include <unistd.h>

static uint8_t outputOne, outputTwo, outputThree;
void pe1Apply(uint8_t a, uint8_t b, uint8_t c) { outputOne = a; outputTwo = b; outputThree = c; }
static const std::string A(32, 'a'), B(32, 'b');
static void zero() { assert(outputOne == 0 && outputTwo == 0 && outputThree == 0); }
static void feed(PE1& p, const std::string& bytes, uint32_t now = 0) {
  for (unsigned char c : bytes) { assert(!p.pending()); p.tick(now); p.feed(c, now); }
}
static std::string take(PE1& p) { std::string s(p.response); p.sent(); return s; }
static void hello(PE1& p, const std::string& session = A, uint32_t now = 0) {
  feed(p, "PE1 HELLO " + session + "\n", now);
  assert(take(p) == "PE1 READY " + session + " 3 200 180 160 1000 TEST250\n"); zero();
}
static void command(PE1& p, const std::string& verb, unsigned seq,
                    const std::string& args = "", uint32_t now = 0,
                    const std::string& session = A) {
  feed(p, "PE1 " + verb + " " + session + " " + std::to_string(seq) + args + "\n", now);
}
static void expectAck(PE1& p, unsigned seq, const std::string& state,
                      const std::string& session = A) {
  assert(take(p) == "PE1 ACK " + session + " " + std::to_string(seq) + " " + state + "\n");
}
static void running(PE1& p, uint32_t now = 0) {
  hello(p, A, now); command(p, "ARM", 1, "", now); expectAck(p, 1, "ARMED 0 0 0");
  command(p, "SET", 2, " 120 72 40", now); expectAck(p, 2, "ARMED 120 72 40");
}
static void error(PE1& p, const char* code) {
  assert(take(p).find(std::string(" ") + code + "\n") != std::string::npos); zero();
}
static void checks() {
  { LoopHealth h;
    assert(!h.clockAdvanced(0)); assert(h.clockAdvanced(1));
    for (int i = 0; i < 10000; ++i) assert(!h.clockAdvanced(1));
    assert(h.clockAdvanced(UINT32_MAX)); assert(h.clockAdvanced(0));
    assert(!h.txStalled(UINT32_MAX - 49, true, false));
    assert(!h.txStalled(49, true, false)); assert(h.txStalled(50, true, false));
    assert(!h.txStalled(51, true, false)); assert(!h.txStalled(52, false, false));
    assert(!h.txStalled(60, true, true)); assert(!h.txStalled(159, true, false));
    assert(h.txStalled(160, true, false));
    puts("PASS clock-progress watchdog feeding and wrap-safe 100 ms TX stall"); }
  { PE1 stalled(200, 180, 160); running(stalled);
    command(stalled, "SET", 3, " 120 72 40"); // Leave this ACK partially transmitted.
    std::string response(stalled.response);
    stalled.fault(PE1::TX_STALL); zero(); stalled.tick(100);
    assert(response == stalled.response); take(stalled); stalled.tick(101);
    assert(take(stalled) == "PE1 FAULT " + A + " TX_STALL\n");
    command(stalled, "ARM", 4); error(stalled, "NEW_SESSION_REQUIRED");
    hello(stalled, B); command(stalled, "TEST", 1, " 8 0 0", 102, B);
    stalled.fault(PE1::TX_STALL); zero(); stalled.tick(400);
    assert(take(stalled) == "PE1 FAULT " + B + " TX_STALL\n");
    stalled.tick(500); assert(!stalled.pending());
    puts("PASS TX stall fail-off, deferred fault framing, consumed session and TEST cancellation"); }
  PE1 p(200, 180, 160); p.begin(); zero();
  feed(p, "PE1 HEL"); assert(!p.pending());
  feed(p, "LO " + A + "\r\n"); assert(take(p).find("READY") != std::string::npos);
  hello(p); // Duplicate HELLO before ARM is idempotent.
  command(p, "ARM", 1); expectAck(p, 1, "ARMED 0 0 0");
  command(p, "SET", 2, " 120 72 40"); expectAck(p, 2, "ARMED 120 72 40");
  command(p, "SET", 3, " 0 0 0"); expectAck(p, 3, "ARMED 0 0 0"); zero();
  command(p, "SET", 4, " 80 36 0"); expectAck(p, 4, "ARMED 80 36 0");
  command(p, "STOP", 5); expectAck(p, 5, "DISARMED 0 0 0"); zero();
  command(p, "SET", 6, " 1 1 0"); error(p, "NOT_ARMED");
  feed(p, "PE1 HELLO " + A + "\n"); error(p, "NEW_SESSION_REQUIRED");
  hello(p, B); command(p, "ARM", 1, "", 0, B); expectAck(p, 1, "ARMED 0 0 0", B);
  command(p, "SET", 2147483647, " 200 180 0", 0, B); expectAck(p, 2147483647, "ARMED 200 180 0", B);
  command(p, "SET", 2147483647, " 1 1 0", 999, B); error(p, "BAD_SEQUENCE");

  for (const std::string& bad : {
      "PE1 SET " + A + " 3 201 1\n", "PE1 SET " + A + " 3 1 181\n",
      "PE1 SET " + A + " 3 -1 0\n", "PE1 SET " + A + " 3 1.0 0\n",
      "PE1 SET " + A + " 3 999999999999999999999999999999 0\n",
      "PE1 SET " + A + " 0 1 1\n", "PE1 SET " + A + " 2147483648 1 1\n",
      "PE1 SET " + A + " +3 1 1\n", "PE1 SET " + A + " 3 1\n",
      "PE1  SET " + A + " 3 1 1\n", "PE1 SET " + A + " 3 1 1 extra\n",
      "PE1 SET " + B + " 3 1 1\n", "PE1 ARM " + A + " 3\n",
      "PE1 HELLO " + A + "\n", "PE1 WHAT " + A + " 3\n", std::string("\n")}) {
    PE1 invalid(200, 180, 160); running(invalid); feed(invalid, bad, 999);
    assert(take(invalid).find("PE1 ERR ") == 0); zero();
    command(invalid, "ARM", 4); error(invalid, "NEW_SESSION_REQUIRED");
  }
  { PE1 independent(200, 180, 160); running(independent);
    command(independent, "SET", 7, " 0 72 0"); expectAck(independent, 7, "ARMED 0 72 0");
    assert(outputOne == 0 && outputTwo == 72);
    independent.tick(999); assert(!independent.pending()); independent.tick(1000);
    assert(take(independent) == "PE1 FAULT " + A + " WATCHDOG\n"); zero(); }
  for (uint32_t start : {0U, UINT32_MAX - 100U}) {
    PE1 timed(200, 180, 160); running(timed, start);
    timed.tick(start + 999); assert(outputOne == 120); timed.tick(start + 1000); zero();
    assert(take(timed) == "PE1 FAULT " + A + " WATCHDOG\n");
    hello(timed, B, start + 1001);
    command(timed, "TEST", 1, " 0 8 0", start + 1001, B); assert(!timed.pending());
    assert(outputOne == 0 && outputTwo == 8);
    timed.tick(start + 1250); assert(!timed.pending()); assert(outputTwo == 8);
    timed.tick(start + 1251); zero(); expectAck(timed, 1, "DISARMED 0 0 0", B);
    timed.tick(start + 2000); assert(!timed.pending());
    command(timed, "TEST", 2, " 8 0 0", start + 2001, B); error(timed, "NEW_SESSION_REQUIRED");
  }
  for (const std::string& cancel : {"PE1 STOP " + A + " 2\n", "PE1 HELLO " + B + "\n",
       "PE1 SET " + A + " 2 1 0\n", "PE1 ARM " + A + " 2\n",
       "PE1 TEST " + A + " 2 8 0\n", std::string("bad\n")}) {
    PE1 pulse(200, 180, 160); hello(pulse); command(pulse, "TEST", 1, " 8 0 0");
    assert(outputOne == 8 && !pulse.pending()); feed(pulse, cancel, 100); zero();
    assert(!take(pulse).empty()); pulse.tick(1000); assert(!pulse.pending());
  }
  for (const std::string& levels : {" 0 0 0", " 8 8 0", " 201 0 0", " 0 181 0"}) {
    PE1 pulse(200, 180, 160); hello(pulse); command(pulse, "TEST", 1, levels); error(pulse, "OUT_OF_RANGE");
    command(pulse, "TEST", 2, " 8 0 0"); error(pulse, "NEW_SESSION_REQUIRED");
  }
  for (unsigned char badByte : {0, 9, 127, 255}) {
    PE1 malformed(200, 180, 160); running(malformed);
    feed(malformed, std::string(1, char(badByte))); error(malformed, "BAD_FRAME");
    feed(malformed, "PE1 HELLO " + B + "\n"); assert(!malformed.pending());
    hello(malformed, B);
  }
  { PE1 overflow(200, 180, 160); running(overflow);
    feed(overflow, std::string(127, 'x')); assert(!overflow.pending());
    feed(overflow, "x"); error(overflow, "OVERFLOW");
    feed(overflow, "PE1 HELLO " + B + "\n"); assert(!overflow.pending()); hello(overflow, B); }
  { PE1 partial(200, 180, 160); running(partial);
    feed(partial, "PE1 SET " + A + " 3 1", 999); partial.tick(1000); zero();
    assert(take(partial).find("WATCHDOG") != std::string::npos);
    feed(partial, " 1 0\n", 1001); error(partial, "NOT_ARMED"); }
  { PE1 blockedTX(200, 180, 160); hello(blockedTX); command(blockedTX, "ARM", 1);
    // A congested transmitter must not delay OFF or overwrite a partial reply.
    blockedTX.tick(1000); zero(); expectAck(blockedTX, 1, "ARMED 0 0 0");
    blockedTX.tick(1001); assert(take(blockedTX).find("WATCHDOG") != std::string::npos); }
  { PE1 locked(0, 0, 0); locked.begin(); feed(locked, "PE1 HELLO " + A + "\n"); error(locked, "NOT_CONFIGURED");
    command(locked, "ARM", 1); error(locked, "NOT_CONFIGURED"); zero(); }
  { PE1 zeros(200, 180, 160); hello(zeros, std::string(32, '0')); }
  { PE1 limited(8, 8, 8, true); limited.begin();
    feed(limited, "PE1 HELLO " + A + "\n");
    assert(take(limited) == "PE1 READY " + A + " 3 8 8 8 1000 TEST250\n");
    command(limited, "ARM", 1); error(limited, "TEST_ONLY");
    feed(limited, "PE1 HELLO " + B + "\n"); take(limited);
    command(limited, "SET", 1, " 8 0 0", 0, B); error(limited, "TEST_ONLY");
    feed(limited, "PE1 HELLO " + A + "\n"); take(limited);
    command(limited, "TEST", 1, " 9 0 0"); error(limited, "OUT_OF_RANGE");
    feed(limited, "PE1 HELLO " + B + "\n"); take(limited);
    command(limited, "TEST", 1, " 8 0 0", 0, B); assert(outputOne == 8 && outputTwo == 0);
    assert(!limited.pending()); limited.tick(250); zero(); expectAck(limited, 1, "DISARMED 0 0 0", B);
    command(limited, "TEST", 2, " 8 0 0", 251, B); error(limited, "NEW_SESSION_REQUIRED");
    command(limited, "STOP", 3, "", 252, B); expectAck(limited, 3, "DISARMED 0 0 0", B);
    puts("PASS restricted test-only build: ARM/SET blocked, maximum 8, timed single pulse and STOP"); }
  { PE1 limited(8, 16, 8, true); limited.begin();
    feed(limited, "PE1 HELLO " + A + "\n");
    assert(take(limited) == "PE1 READY " + A + " 3 8 16 8 1000 TEST250\n");
    command(limited, "TEST", 1, " 0 16 0"); assert(outputOne == 0 && outputTwo == 16);
    limited.tick(250); zero(); expectAck(limited, 1, "DISARMED 0 0 0");
    feed(limited, "PE1 HELLO " + B + "\n"); take(limited);
    command(limited, "TEST", 1, " 0 17 0", 0, B); error(limited, "OUT_OF_RANGE");
    puts("PASS M2-only 16/255 timed pulse and ceiling"); }
  { PE1 manual(255, 255, 255, true); manual.begin();
    feed(manual, "PE1 HELLO " + A + "\n"); take(manual);
    command(manual, "ARM", 1); error(manual, "TEST_ONLY");
    feed(manual, "PE1 HELLO " + B + "\n"); take(manual);
    command(manual, "TEST", 1, " 0 255 0", 0, B); assert(outputOne == 0 && outputTwo == 255);
    manual.tick(250); zero(); expectAck(manual, 1, "DISARMED 0 0 0", B);
    puts("PASS manual test command range: ARM denied, TEST still ends at 250 ms"); }
  { PE1 m3(200, 180, 160); running(m3);
    assert(outputThree == 40);
    command(m3, "SET", 3, " 0 0 160"); expectAck(m3, 3, "ARMED 0 0 160");
    assert(outputOne == 0 && outputTwo == 0 && outputThree == 160);
    command(m3, "SET", 4, " 0 0 161"); error(m3, "OUT_OF_RANGE");
    hello(m3, B); command(m3, "TEST", 1, " 0 0 8", 0, B);
    assert(outputThree == 8); m3.tick(250); zero(); expectAck(m3, 1, "DISARMED 0 0 0", B);
    hello(m3, A); command(m3, "TEST", 1, " 8 0 8"); error(m3, "OUT_OF_RANGE");
    puts("PASS M3 full range, independent zero, bounds, TEST250 and shared shutdown"); }
  puts("PASS PE1 golden exchange, parser, caps, sessions, independent outputs, deadman, TEST250, wrap and locked build");
}

int main(int argc, char**) {
  if (argc == 1) { checks(); return 0; }
  // Native transport fixture uses the exact firmware state machine, real clock.
  fcntl(STDIN_FILENO, F_SETFL, O_NONBLOCK);
  PE1 p(200, 180, 160); p.begin();
  const auto start = std::chrono::steady_clock::now();
  for (;;) {
    uint32_t now = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - start).count();
    p.tick(now);
    if (p.pending()) { fputs(p.response, stdout); fflush(stdout); p.sent(); }
    else { unsigned char byte; ssize_t n = read(STDIN_FILENO, &byte, 1);
      if (n == 0) return 0;
      if (n > 0) p.feed(byte, now); else usleep(1000); }
  }
}
