// Adapted from Maus-Tec Edge-o-Matic 3000, MIT; pinned revision in PROVENANCE.md.
#include "EOMCore.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

typedef enum { OD_STATE_IDLE, OD_STATE_SUSTAINED, OD_STATE_RHYTHMIC, OD_STATE_DETECTED } orgasm_detect_state_t;
typedef enum { OD_MODE_AUTO, OD_MODE_SUSTAINED, OD_MODE_RHYTHMIC } orgasm_detect_mode_t;
typedef enum { OC_STATE_RUNNING, OC_STATE_COOLDOWN, OC_STATE_RESUMING } oc_control_state_t;
typedef struct { unsigned long timestamp_ms; uint16_t amplitude; } peak_record_t;
#define PEAK_RING_SIZE 8
typedef struct { uint16_t buffer[64]; size_t window, index; uint32_t sum; uint16_t averaged; } running_average_t;

struct EOMEngine {
    EOMConfig config;
    uint64_t now_ms, last_ms;
    uint16_t raw_pressure;
    uint32_t events, random_seed;
    bool has_time;
    running_average_t average;
    struct {
        running_average_t *average;
        uint16_t last_value, pressure_value, peak_start, arousal;
        uint8_t update_flag;
    } arousal;
    struct {
        bool control_motor;
        float motor_speed;
        oc_control_state_t control_state;
        unsigned long cooldown_start_ms, resume_start_ms, cooldown_jitter_ms;
    } output;
    struct { float motor_speed; uint16_t arousal; } ramp;
    struct {
        orgasm_detect_state_t state;
        float baseline;
        bool baseline_initialized;
        unsigned long sustained_start_ms, last_above_threshold_ms;
        uint16_t prev_pressure[3];
        uint8_t prev_count;
        uint16_t peak_trough;
        peak_record_t peaks[8];
        uint8_t peak_write_idx, peak_count;
        bool last_was_rhythmic;
        unsigned long detected_at_ms;
        uint16_t last_interval_ms;
    } detection;
};

static uint16_t saturate(uint32_t value) { return value > UINT16_MAX ? UINT16_MAX : (uint16_t)value; }
static uint32_t next_random(EOMEngine *engine) {
    uint32_t x = engine->random_seed;
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    return engine->random_seed = x;
}
static void running_average_add_value(running_average_t *average, uint16_t value) {
    average->sum -= average->buffer[average->index];
    average->buffer[average->index] = value;
    average->sum += value;
    average->index = (average->index + 1) % average->window;
    average->averaged = (uint16_t)(average->sum / average->window);
}
static uint16_t running_avergae_get_average(running_average_t *average) { return average->averaged; }

#define Config (engine->config)
#define arousal_state (engine->arousal)
#define output_state (engine->output)
#define state (engine->ramp)
// 'det.state' must remain a member name, so the ramp alias is expanded only locally below.
#undef state
#define det (engine->detection)
#define esp_timer_get_time() (engine->now_ms * 1000UL)
#define eom_hal_get_pressure_reading() (engine->raw_pressure)
#define ESP_LOGD(...) ((void)0)
#define ESP_LOGI(...) ((void)0)
#define ocTRUE 1
#define EVT_ORGASM_START EOM_DETECTED
#define EVT_ORGASM_DENIAL EOM_EDGE
#define EVT_ORGASM_PERMIT 0
#define event_manager_dispatch(event, unused, value) (engine->events |= (event))
#define update_check(variable, value) do { if ((variable) != (value)) { (variable) = (value); arousal_state.update_flag = 1; } } while (0)
#define _set_speed(speed) ((void)(speed))
#define calculate_increment(start, target, time_s) eom_ramp_increment(start, target, time_s, Config.update_frequency_hz)
