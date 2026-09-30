#!/usr/bin/env python3
"""Compare the portable engine with original, unmodified algorithm bodies.

Builds an independent global-state reference harness in a temporary directory.
The reference initializes the original average deterministically and widens its
sum, as documented in PROVENANCE.md. Normal-range arithmetic is otherwise the
upstream code, not reimplemented expectations or the generated portable code.
"""
import ctypes as C
import math
import random
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / 'Vendor/EdgeOMatic'
header = (ROOT / 'Sources/EOMCore/include/EOMCore.h').read_text()


def c_structure(name):
    body = re.search(r'typedef struct \{([^{}]+)\} ' + name + ';', header).group(1)
    types = {'int32_t': C.c_int32, 'uint32_t': C.c_uint32, 'uint16_t': C.c_uint16,
             'bool': C.c_bool, 'float': C.c_float}
    fields = []
    for declaration in body.split(';'):
        if not declaration.strip():
            continue
        kind, names = declaration.strip().split(None, 1)
        fields.extend((name.strip(), types[kind]) for name in names.split(','))
    return type(name, (C.Structure,), {'_fields_': fields})


def function(source, name):
    match = re.search(r'(?m)^(?:static )?[\w* ]+\b' + name + r'\([^;{}]*?\)\s*\{', source)
    assert match, name
    end = source.index('{', match.start()) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[match.start():end]


def strip_includes(source):
    return re.sub(r'(?m)^#include.*\n|^static const char\* TAG.*\n', '', source)


control = (VENDOR / 'src/orgasm_control.c').read_text()
detect = strip_includes((VENDOR / 'src/orgasm_detection.c').read_text())
ramp = strip_includes((VENDOR / 'src/vibration_modes/ramp_stop_controller.c').read_text())
arousal = re.search(r'static struct \{.*?\} arousal_state;', control, re.S).group(0)
output = re.search(r'static struct \{[^{}]+\} output_state;', control, re.S).group(0)

reference = r'''
#include "EOMCore.h"
#include <stdlib.h>
#include <string.h>
#include <math.h>
typedef int orgasm_output_mode_t;
typedef int vibration_mode_t;
typedef enum { OC_STATE_RUNNING, OC_STATE_COOLDOWN, OC_STATE_RESUMING } oc_control_state_t;
typedef enum { OD_STATE_IDLE, OD_STATE_SUSTAINED, OD_STATE_RHYTHMIC, OD_STATE_DETECTED } orgasm_detect_state_t;
typedef enum { OD_MODE_AUTO, OD_MODE_SUSTAINED, OD_MODE_RHYTHMIC } orgasm_detect_mode_t;
enum { OC_MANUAL_CONTROL, OC_AUTOMAITC_CONTROL, OC_PLUGIN_CONTROL };
typedef struct { uint16_t buffer[64]; size_t window, index; uint32_t sum; uint16_t averaged; } running_average_t;
typedef struct { float (*start)(void); float (*increment)(void); float (*stop)(void); float (*on_edge)(void); void (*tick)(float,uint16_t); } vibration_mode_controller_t;
static EOMConfig Config;
static uint16_t raw;
static unsigned long timestamp;
static uint32_t events, seed;
static running_average_t average;
#define ESP_LOGD(...) ((void)0)
#define ESP_LOGI(...) ((void)0)
#define ocTRUE 1
#define EVT_ORGASM_START EOM_DETECTED
#define EVT_ORGASM_DENIAL EOM_EDGE
#define EVT_ORGASM_PERMIT 0
#define EVT_AROUSAL_CHANGE 0
#define event_manager_dispatch(event,unused,value) (events |= (event))
#define websocket_driver_broadcast_arousal(...) ((void)0)
#define eom_hal_set_encoder_rgb(...) ((void)0)
#define eom_hal_get_pressure_reading() raw
#define esp_timer_get_time() (timestamp * 1000UL)
#define update_check(variable,value) do { if ((variable) != (value)) { (variable) = (value); arousal_state.update_flag = 1; } } while (0)
#define _set_speed(...) ((void)0)
#define calculate_increment(start,target,time_s) ((time_s > 0 && Config.update_frequency_hz > 0) ? ((float)(target-start)/((float)time_s))/Config.update_frequency_hz : 0)
static uint32_t ref_random(void) { uint32_t x=seed; x ^= x<<13; x ^= x>>17; x ^= x<<5; return seed=x; }
#define random() ref_random()
static void running_average_add_value(running_average_t *a, uint16_t v) {
    a->sum -= a->buffer[a->index]; a->buffer[a->index]=v; a->sum += v;
    a->index=(a->index+1)%a->window; a->averaged=a->sum/a->window;
}
static uint16_t running_avergae_get_average(running_average_t *a) { return a->averaged; }
'''
reference += '\n' + arousal + '\n' + output + '\n' + ramp
reference += '\nstatic const vibration_mode_controller_t *orgasm_control_getVibrationMode(void) { return &RampStopController; }\n'
reference += function(control, 'orgasm_control_get_motor_speed') + '\n'
reference += function(control, 'orgasm_control_get_arousal_percent') + '\n'
reference += detect + '\n'
reference += function(control, 'orgasm_control_updateArousal') + '\n'
reference += function(control, 'orgasm_control_updateMotorSpeed') + '\n'
reference += r'''
void reference_reset(EOMConfig c, uint32_t s) {
    Config=c; seed=s; timestamp=0; events=0;
    memset(&arousal_state,0,sizeof(arousal_state)); memset(&output_state,0,sizeof(output_state));
    memset(&state,0,sizeof(state)); memset(&average,0,sizeof(average));
    average.window=c.pressure_smoothing; arousal_state.average=&average;
    orgasm_detection_init();
    output_state.control_motor=1; output_state.output_mode=OC_AUTOMAITC_CONTROL;
    output_state.control_state=OC_STATE_RESUMING; output_state.motor_speed=start();
}
EOMSnapshot reference_step(uint16_t pressure, uint64_t time) {
    raw=pressure; timestamp=time; events=0;
    orgasm_control_updateArousal(); orgasm_control_updateMotorSpeed();
    orgasm_detection_tick(Config.use_average_values ? average.averaged : raw, arousal_state.arousal);
    if (Config.od_clench_arousal_boost && (det.state==OD_STATE_SUSTAINED || det.state==OD_STATE_RHYTHMIC))
        arousal_state.arousal += Config.od_clench_arousal_boost_amount;
    uint16_t pending = arousal_state.last_value > arousal_state.peak_start ? arousal_state.last_value-arousal_state.peak_start : 0;
    if (pending < Config.sensitivity_threshold/10) pending=0;
    return (EOMSnapshot){ .pressure=pressure, .average=average.averaged, .arousal=arousal_state.arousal,
        .pending_peak=pending, .peak_trough=arousal_state.peak_start,
        .control_phase=output_state.control_state, .detection_phase=det.state,
        .motor_speed=output_state.motor_speed, .events=events,
        .wants_power=output_state.motor_speed>0, .rhythmic=det.last_was_rhythmic,
        .peak_count=det.peak_count, .last_interval_ms=det.last_interval_ms,
        .sustained_ms=det.state==OD_STATE_IDLE ? 0 : time-det.sustained_start_ms };
}
'''

Config = c_structure('EOMConfig')
Snapshot = c_structure('EOMSnapshot')
with tempfile.TemporaryDirectory(prefix='perifit-oracle-') as directory:
    path = Path(directory)
    (path / 'reference.c').write_text(reference)
    subprocess.run(['clang', '-dynamiclib', '-O1', '-I', str(ROOT/'Sources/EOMCore/include'),
                    str(ROOT/'Sources/EOMCore/EOMCore.c'), str(path/'reference.c'), '-o', str(path/'oracle.dylib')], check=True)
    lib = C.CDLL(str(path/'oracle.dylib'))
    lib.eom_default_config.restype = Config
    lib.eom_create.argtypes = [Config, C.c_uint32]; lib.eom_create.restype = C.c_void_p
    lib.eom_set_armed.argtypes = [C.c_void_p, C.c_bool, C.c_uint64]
    lib.eom_step.argtypes = [C.c_void_p, C.c_uint16, C.c_uint64]; lib.eom_step.restype = Snapshot
    lib.eom_destroy.argtypes = [C.c_void_p]
    lib.reference_reset.argtypes = [Config, C.c_uint32]
    lib.reference_step.argtypes = [C.c_uint16, C.c_uint64]; lib.reference_step.restype = Snapshot
    rng = random.Random(12)
    waveforms = {
        'rest': lambda t: 0,
        'noise': lambda t: rng.randrange(0, 20),
        'peaks': lambda t: int(max(0, math.sin(t*2*math.pi/1.6))*1100),
        'sustained': lambda t: 650 if 5 < t % 20 < 16 else 0,
        'rhythmic': lambda t: int(600+350*(1+math.sin(t*2*math.pi/0.8))) if 5 < t % 20 < 16 else 0,
        'irregular': lambda t: int(max(0, math.sin(t*t/7))*800),
    }
    ticks = 0; cutoffs = 0; detections = 0
    for mode in range(3):
        for averaging in (False, True):
            for name, waveform in waveforms.items():
                config = lib.eom_default_config()
                config.od_mode=mode; config.use_average_values=averaging
                config.od_arousal_gate_percent=0
                config.od_clench_arousal_boost=(mode==1)
                lib.reference_reset(config, 7)
                engine = lib.eom_create(config, 7)
                assert engine
                lib.eom_set_armed(engine, True, 0)
                for tick in range(3000):
                    pressure = waveform(tick/50)
                    expected = lib.reference_step(pressure, tick*20)
                    actual = lib.eom_step(engine, pressure, tick*20)
                    for field, _ in Snapshot._fields_:
                        a, b = getattr(actual, field), getattr(expected, field)
                        if field == 'motor_speed':
                            assert abs(a-b) < 1e-5, (name,mode,averaging,tick,field,a,b)
                        else:
                            assert a == b, (name,mode,averaging,tick,field,a,b)
                    cutoffs += bool(actual.events & 1); detections += bool(actual.events & 2)
                    ticks += 1
                lib.eom_destroy(engine)
    assert cutoffs and detections
    print(f'Upstream comparison passed: {ticks:,} ticks, 36 traces, {cutoffs} cutoffs, {detections} events.')
