#pragma once
#include <stdint.h>

// Shared by the actual Uno loop and native fault-injection checks.
struct LoopHealth {
  uint32_t fedAt = 0, progressAt = 0;
  bool transmitting = false, stalled = false;
  bool clockAdvanced(uint32_t now) {
    if (now == fedAt) return false;
    fedAt = now; return true;
  }
  bool txStalled(uint32_t now, bool pending, bool progressed) {
    if (!pending) { transmitting = stalled = false; return false; }
    if (!transmitting || progressed) { progressAt = now; transmitting = true; }
    if (!stalled && uint32_t(now - progressAt) >= 100) { stalled = true; return true; }
    return false;
  }
};
