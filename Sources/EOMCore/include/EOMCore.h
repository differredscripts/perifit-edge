#ifndef PERIFIT_EOM_CORE_H
#define PERIFIT_EOM_CORE_H
#include <stdbool.h>
#include <stdint.h>

typedef struct {
    int32_t sensitivity_threshold, arousal_decay_rate, pressure_smoothing;
    bool use_average_values;
    int32_t cooldown_delay_ms, cooldown_random_ms, arousal_holdoff_ms;
    int32_t motor_min_speed, motor_max_speed, motor_ramp_time_s, update_frequency_hz;
    int32_t od_mode, od_sustained_threshold, od_sustained_fallback_ms;
    int32_t od_sustained_dropout_ms, od_peak_min_amplitude, od_rhythmic_min_peaks;
    int32_t od_rhythmic_interval_min_ms, od_rhythmic_interval_max_ms;
    int32_t od_rhythmic_interval_variance_ms, od_rhythmic_timeout_ms;
    int32_t od_arousal_gate_percent, od_recovery_ms;
    bool od_clench_arousal_boost;
    int32_t od_clench_arousal_boost_amount;
    bool od_detection_armed;
} EOMConfig;

enum { EOM_EDGE = 1, EOM_DETECTED = 2, EOM_MANUAL_EDGE = 4 };
typedef struct {
    uint16_t pressure, average, arousal, pending_peak, peak_trough;
    int32_t control_phase, detection_phase;
    float motor_speed;
    uint32_t events;
    bool wants_power, rhythmic;
    uint32_t sustained_ms, peak_count;
    uint16_t last_interval_ms;
} EOMSnapshot;

typedef struct EOMEngine EOMEngine;
EOMConfig eom_default_config(void);
float eom_ramp_increment(uint8_t start, uint8_t target, float seconds, float frequency);
bool eom_valid_config(EOMConfig config);
EOMEngine *eom_create(EOMConfig config, uint32_t seed);
void eom_destroy(EOMEngine *engine);
bool eom_set_sensitivity(EOMEngine *engine, int32_t threshold);
void eom_set_armed(EOMEngine *engine, bool armed, uint64_t now_ms);
void eom_manual_edge(EOMEngine *engine, uint64_t now_ms);
void eom_hold_cooldown(EOMEngine *engine, uint64_t now_ms);
EOMSnapshot eom_step(EOMEngine *engine, uint16_t pressure, uint64_t now_ms);
#endif
