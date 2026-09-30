#pragma once
// Default protocol command range. These are PWM command
// ceilings, not measured current/thermal ratings. Set all three to 0 to lock output.
#ifndef PE1_MAX_M1
#define PE1_MAX_M1 255
#endif
#ifndef PE1_MAX_M2
#define PE1_MAX_M2 255
#endif
#ifndef PE1_MAX_M3
#define PE1_MAX_M3 255
#endif
#ifndef PE1_TEST_ONLY
// Temporary functional check only: 250 ms TEST pulses, no ARM/SET. These
// command ceilings are not electrically verified continuous motor ratings.
#define PE1_TEST_ONLY 0
#endif
#if PE1_TEST_ONLY && (PE1_MAX_M1 < 1 || PE1_MAX_M2 < 1 || PE1_MAX_M3 < 1)
#error "Test-only firmware requires explicit nonzero command ceilings"
#endif
#if PE1_MAX_M1 < 0 || PE1_MAX_M1 > 255 || PE1_MAX_M2 < 0 || PE1_MAX_M2 > 255 || PE1_MAX_M3 < 0 || PE1_MAX_M3 > 255
#error "PWM caps must be 0 (locked) or 1..255"
#endif
#if (PE1_MAX_M1 == 0) != (PE1_MAX_M2 == 0) || (PE1_MAX_M1 == 0) != (PE1_MAX_M3 == 0)
#error "Configure all three motors or leave all locked"
#endif
