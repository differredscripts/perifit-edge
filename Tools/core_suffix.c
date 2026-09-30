float eom_ramp_increment(uint8_t start, uint8_t target, float seconds, float frequency) {
    if (target < start || !isfinite(seconds) || !isfinite(frequency) || seconds <= 0 || frequency <= 0) return 0;
    return ((float)(target - start) / seconds) / frequency;
}
EOMConfig eom_default_config(void) {
    return (EOMConfig){
        .sensitivity_threshold=600, .arousal_decay_rate=60, .pressure_smoothing=5,
        .cooldown_delay_ms=1000, .cooldown_random_ms=1000, .arousal_holdoff_ms=1000,
        .motor_min_speed=10, .motor_max_speed=128, .motor_ramp_time_s=30, .update_frequency_hz=50,
        .od_sustained_threshold=200, .od_sustained_fallback_ms=5000, .od_sustained_dropout_ms=500,
        .od_peak_min_amplitude=40, .od_rhythmic_min_peaks=4, .od_rhythmic_interval_min_ms=500,
        .od_rhythmic_interval_max_ms=1200, .od_rhythmic_interval_variance_ms=200,
        .od_rhythmic_timeout_ms=1500, .od_arousal_gate_percent=70, .od_recovery_ms=3000,
        .od_clench_arousal_boost_amount=5, .od_detection_armed=true
    };
}
bool eom_valid_config(EOMConfig c) {
    return c.sensitivity_threshold >= 10 && c.sensitivity_threshold <= 65535 &&
        c.arousal_decay_rate >= 1 && c.arousal_decay_rate <= 99 &&
        c.pressure_smoothing >= 1 && c.pressure_smoothing <= 64 && c.update_frequency_hz == 50 &&
        c.cooldown_delay_ms >= 0 && c.cooldown_delay_ms <= 3600000 &&
        c.cooldown_random_ms >= 0 && c.cooldown_random_ms <= 3600000 &&
        c.arousal_holdoff_ms >= 0 && c.arousal_holdoff_ms <= 60000 &&
        c.motor_min_speed >= 1 && c.motor_max_speed >= c.motor_min_speed && c.motor_max_speed <= 255 &&
        c.motor_ramp_time_s >= 0 && c.motor_ramp_time_s <= 3600 &&
        c.od_mode >= 0 && c.od_mode <= 2 && c.od_sustained_threshold >= 1 && c.od_sustained_threshold <= 65535 &&
        c.od_sustained_fallback_ms >= 20 && c.od_sustained_fallback_ms <= 60000 &&
        c.od_sustained_dropout_ms >= 20 && c.od_sustained_dropout_ms <= 60000 &&
        c.od_peak_min_amplitude >= 1 && c.od_peak_min_amplitude <= 65535 &&
        c.od_rhythmic_min_peaks >= 3 && c.od_rhythmic_min_peaks <= 8 &&
        c.od_rhythmic_interval_min_ms >= 20 && c.od_rhythmic_interval_max_ms >= c.od_rhythmic_interval_min_ms &&
        c.od_rhythmic_interval_max_ms <= 60000 && c.od_rhythmic_interval_variance_ms >= 0 &&
        c.od_rhythmic_interval_variance_ms <= 60000 && c.od_rhythmic_timeout_ms >= 20 &&
        c.od_rhythmic_timeout_ms <= 60000 && c.od_arousal_gate_percent >= 0 && c.od_arousal_gate_percent <= 100 &&
        c.od_recovery_ms >= 20 && c.od_recovery_ms <= 60000 &&
        c.od_clench_arousal_boost_amount >= 0 && c.od_clench_arousal_boost_amount <= 50;
}
EOMEngine *eom_create(EOMConfig config, uint32_t seed) {
    if (!eom_valid_config(config)) return NULL;
    EOMEngine *engine = calloc(1, sizeof(*engine));
    if (!engine) return NULL;
    engine->config = config;
    engine->random_seed = seed ? seed : 1;
    engine->average.window = (size_t)config.pressure_smoothing;
    arousal_state.average = &engine->average;
    output_state.control_state = OC_STATE_RESUMING;
    orgasm_detection_init(engine);
    return engine;
}
void eom_destroy(EOMEngine *engine) { free(engine); }
bool eom_set_sensitivity(EOMEngine *engine, int32_t threshold) {
    if (!engine || threshold < 10 || threshold > 65535) return false;
    engine->config.sensitivity_threshold = threshold;
    return true;
}
void eom_set_armed(EOMEngine *engine, bool armed, uint64_t now_ms) {
    if (!engine) return;
    if (armed && !output_state.control_motor) {
        output_state.control_state = OC_STATE_RESUMING;
        output_state.resume_start_ms = now_ms;
        output_state.motor_speed = ramp_start(engine);
    } else if (!armed) {
        output_state.motor_speed = ramp_stop(engine);
    }
    output_state.control_motor = armed;
}
void eom_manual_edge(EOMEngine *engine, uint64_t now_ms) {
    if (!engine || !output_state.control_motor) return;
    output_state.control_state = OC_STATE_COOLDOWN;
    output_state.cooldown_start_ms = now_ms;
    output_state.cooldown_jitter_ms = Config.cooldown_random_ms > 0 ? next_random(engine) % Config.cooldown_random_ms : 0;
    output_state.motor_speed = ramp_stop(engine);
    engine->events |= EOM_MANUAL_EDGE;
}
void eom_hold_cooldown(EOMEngine *engine, uint64_t now_ms) {
    if (!engine || !output_state.control_motor) return;
    if (output_state.control_state != OC_STATE_COOLDOWN) {
        eom_manual_edge(engine, now_ms);
    } else {
        // Refresh the quiet period without rerolling jitter on every sample.
        output_state.cooldown_start_ms = now_ms;
        output_state.motor_speed = ramp_stop(engine);
    }
}
EOMSnapshot eom_step(EOMEngine *engine, uint16_t pressure, uint64_t now_ms) {
    if (!engine) return (EOMSnapshot){0};
    engine->events = 0;
    // Monotonic input is a trust boundary; do not let unsigned timers underflow.
    if (engine->has_time && now_ms < engine->last_ms) {
        eom_set_armed(engine, false, engine->last_ms);
        now_ms = engine->last_ms;
    }
    engine->has_time = true;
    engine->now_ms = engine->last_ms = now_ms;
    engine->raw_pressure = pressure;
    orgasm_control_updateArousal(engine);
    orgasm_control_updateMotorSpeed(engine);
    uint16_t p = Config.use_average_values ? engine->average.averaged : pressure;
    orgasm_detection_tick(engine, p, arousal_state.arousal);
    if (Config.od_clench_arousal_boost && (det.state == OD_STATE_SUSTAINED || det.state == OD_STATE_RHYTHMIC))
        arousal_state.arousal = saturate((uint32_t)arousal_state.arousal + Config.od_clench_arousal_boost_amount);
    uint16_t pending_peak = arousal_state.last_value > arousal_state.peak_start
        ? arousal_state.last_value - arousal_state.peak_start : 0;
    if (pending_peak < Config.sensitivity_threshold / 10) pending_peak = 0;
    return (EOMSnapshot){ .pressure=pressure, .average=engine->average.averaged,
        .arousal=arousal_state.arousal, .pending_peak=pending_peak, .peak_trough=arousal_state.peak_start,
        .control_phase=output_state.control_state, .detection_phase=det.state,
        .motor_speed=output_state.motor_speed, .events=engine->events,
        .wants_power=output_state.control_motor && output_state.motor_speed > 0,
        .rhythmic=det.last_was_rhythmic, .peak_count=det.peak_count, .last_interval_ms=det.last_interval_ms,
        .sustained_ms=det.state == OD_STATE_IDLE ? 0 : (uint32_t)(now_ms - det.sustained_start_ms) };
}
