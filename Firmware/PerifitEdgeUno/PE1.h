#pragma once
#include <stdint.h>
#include <stdio.h>
#include <string.h>

// The adapter must write both driver levels before returning. No ramps or boosts.
void pe1Apply(uint8_t one, uint8_t two, uint8_t three);

class PE1 {
 public:
  PE1(uint8_t maxOne, uint8_t maxTwo, uint8_t maxThree, bool onlyTests = false)
      : capOne(maxOne), capTwo(maxTwo), capThree(maxThree), testOnly(onlyTests) {}
  // One bounded response at a time; the adapter drains it without blocking.
  char response[96] = {};
  void begin() { off(); }
  bool pending() const { return response[0] != 0; }
  void sent() { response[0] = 0; }
  enum Fault : uint8_t { NONE, WATCHDOG, TX_STALL };
  void fault(Fault code) { off(); used = true; if (pendingFault == NONE) pendingFault = code; }

  void tick(uint32_t now) {
    if (armed && uint32_t(now - renewedAt) >= 1000) {
      fault(WATCHDOG);
    }
    if (testing && uint32_t(now - testAt) >= 250) {
      off(); ack(sequence);
    }
    if (pendingFault != NONE && !pending()) {
      snprintf(response, sizeof(response), "PE1 FAULT %s %s\n", session,
               pendingFault == WATCHDOG ? "WATCHDOG" : "TX_STALL");
      pendingFault = NONE;
    }
  }

  // Call tick before feed, and do not feed while a response is pending.
  void feed(uint8_t byte, uint32_t now) {
    if (discard) {
      if (byte == '\n') discard = false;
      return;
    }
    if (byte == '\n') {
      if (length && input[length - 1] == '\r') --length;
      input[length] = 0;
      length = 0;
      line(now);
      return;
    }
    if (length == sizeof(input) - 1) {
      reject("OVERFLOW"); discard = true; length = 0; return;
    }
    if ((byte < 32 && byte != '\r') || byte > 126 ||
        (length && input[length - 1] == '\r')) {
      reject("BAD_FRAME"); discard = true; length = 0; return;
    }
    input[length++] = char(byte);
  }

 private:
  const uint8_t capOne, capTwo, capThree;
  const bool testOnly;
  char input[128] = {};
  char session[33] = "00000000000000000000000000000000";
  uint8_t length = 0, one = 0, two = 0, three = 0;
  uint32_t sequence = 0, renewedAt = 0, testAt = 0;
  bool haveSession = false, used = true, armed = false, testing = false;
  bool discard = false;
  Fault pendingFault = NONE;

  void off() { pe1Apply(0, 0, 0); one = two = three = 0; armed = testing = false; }
  void reject(const char* code, uint32_t seq = 0) {
    off(); used = true;
    snprintf(response, sizeof(response), "PE1 ERR %s %lu %s\n",
             session, (unsigned long)seq, code);
  }
  void ack(uint32_t seq) {
    snprintf(response, sizeof(response), "PE1 ACK %s %lu %s %u %u %u\n", session,
             (unsigned long)seq, armed ? "ARMED" : "DISARMED", one, two, three);
  }
  static bool nonce(const char* s) {
    if (strlen(s) != 32) return false;
    for (uint8_t i = 0; i < 32; ++i)
      if (!((s[i] >= '0' && s[i] <= '9') || (s[i] >= 'a' && s[i] <= 'f'))) return false;
    return true;
  }
  static bool number(const char* s, uint32_t maximum, uint32_t& value) {
    value = 0;
    if (!*s) return false;
    for (; *s; ++s) {
      if (*s < '0' || *s > '9') return false;
      uint8_t digit = *s - '0';
      if (value > maximum / 10 || (value == maximum / 10 && digit > maximum % 10)) return false;
      value = value * 10 + digit;
    }
    return true;
  }
  void line(uint32_t now) {
    char* fields[7] = {input};
    uint8_t count = 1;
    for (char* p = input; *p; ++p) {
      if (*p == ' ') {
        if (count == 7) { reject("BAD_FRAME"); return; }
        *p = 0; fields[count++] = p + 1;
      }
    }
    uint32_t seq = 0;
    bool validSeq = count >= 4 && number(fields[3], 2147483647UL, seq) && seq > 0;
    if (!validSeq) seq = 0;
    for (uint8_t i = 0; i < count; ++i)
      if (!*fields[i]) { reject("BAD_FRAME", seq); return; }
    if (count < 3 || strcmp(fields[0], "PE1")) { reject("BAD_FRAME", seq); return; }
    if (!nonce(fields[2])) { reject("BAD_SESSION", seq); return; }
    if (!strcmp(fields[1], "HELLO")) {
      if (count != 3) { reject("BAD_FRAME", seq); return; }
      if (haveSession && !strcmp(fields[2], session) && used) {
        reject("NEW_SESSION_REQUIRED"); return;
      }
      off();
      if (!haveSession || strcmp(fields[2], session)) {
        strcpy(session, fields[2]); sequence = 0; used = false; haveSession = true;
      }
      if (!capOne || !capTwo || !capThree) { reject("NOT_CONFIGURED"); return; }
      snprintf(response, sizeof(response), "PE1 READY %s 3 %u %u %u 1000 TEST250\n", session, capOne, capTwo, capThree);
      return;
    }
    if (!haveSession || strcmp(fields[2], session)) { reject("BAD_SESSION", seq); return; }
    if (!validSeq || seq <= sequence) { reject("BAD_SEQUENCE", seq); return; }
    if (!capOne || !capTwo || !capThree) { reject("NOT_CONFIGURED", seq); return; }
    const char* verb = fields[1];
    bool set = !strcmp(verb, "SET"), test = !strcmp(verb, "TEST");
    bool arm = !strcmp(verb, "ARM"), stop = !strcmp(verb, "STOP");
    if (!(set || test || arm || stop) || count != ((set || test) ? 7 : 4)) {
      reject("BAD_FRAME", seq); return;
    }
    if (testOnly && (arm || set)) { reject("TEST_ONLY", seq); return; }
    uint32_t a = 0, b = 0, c = 0;
    if ((set || test) && (!number(fields[4], capOne, a) || !number(fields[5], capTwo, b) || !number(fields[6], capThree, c))) {
      reject("OUT_OF_RANGE", seq); return;
    }
    if ((arm || test) && used) { reject("NEW_SESSION_REQUIRED", seq); return; }
    if (set && !armed) { reject("NOT_ARMED", seq); return; }
    if (test && (int(a > 0) + int(b > 0) + int(c > 0) != 1)) { reject("OUT_OF_RANGE", seq); return; }
    if (stop) { off(); used = true; }
    if (arm) { off(); armed = true; used = true; renewedAt = now; }
    if (set || test) {
      pe1Apply(uint8_t(a), uint8_t(b), uint8_t(c)); one = a; two = b; three = c;
      if (set) renewedAt = now;
      else { used = true; testing = true; testAt = now; }
    }
    sequence = seq;
    if (!test) ack(seq);
  }
};
