#ifndef CFTOPSYS_H
#define CFTOPSYS_H

#include <stdint.h>

// The only place ftop touches Apple's private IOReport and IOHID event APIs and the
// undocumented controller (SMC) interface.
// Every function reports failure instead of guessing; callers show "unavailable".

typedef struct {
    char channel[32];   // IOReport channel name, e.g. "PCPU000" or "PACC0_PCPU0"
    char kind;          // cluster type letter in the channel name: 'P', 'E', 'M', ...
    int index;          // the number in the channel name; not a position, it need not start at 0
    double active;      // 0...1 share of the interval spent out of idle, or -1
    double mhz;         // active-time weighted frequency, or -1 when unknown
    double max_mhz;     // top of the frequency table that fits this core, or -1
    int steps;          // active states the channel reports
    int tables;         // frequency tables found on this Mac
    int fitting;        // how many of them have `steps` steps
} ftop_core_freq;

// Whether an IOReport channel name is a core's: a cluster type letter, "CPU", and
// digits, at the start of the name or after its last underscore. Writes the letter
// and the number when it is; either pointer may be NULL.
int ftop_core_channel_parse(const char *name, char *kind, int *index);
// Orders core channels by cluster prefix, type letter, then number as a number.
int ftop_core_channel_compare(const char *a, const char *b);

typedef struct ftop_cpu_sampler ftop_cpu_sampler;

ftop_cpu_sampler *ftop_cpu_sampler_create(void);
void ftop_cpu_sampler_destroy(ftop_cpu_sampler *sampler);
// Fills `out` with the delta since the previous call, in `ftop_core_channel_compare` order.
// Returns the number of cores written, or -1 when no sample is available.
int ftop_cpu_sampler_update(ftop_cpu_sampler *sampler, ftop_core_freq *out, int capacity);
// Writes what decides a core's frequency: the tables found, the registry properties
// that could be tables, how the device tree numbers the CPUs, and every channel of
// the last delta with its states. Diagnostics only. Returns the length written, or
// -1; text that does not fit is cut at a line and says so.
int ftop_cpu_sampler_describe(ftop_cpu_sampler *sampler, char *buffer, int capacity);

// Writes the IODeviceTree cluster type letter of each logical CPU id ('P', 'E',
// 'M', ...) and 0 where a CPU has none. Returns the highest id found plus one, or -1.
int ftop_cpu_cluster_types(char *out, int capacity);

typedef struct {
    double average;     // degrees Celsius across the matched sensors
    double maximum;
    int sensor_count;
    int source;         // 1 = CPU cluster sensors, 2 = PMU die sensors
} ftop_temperature;

// Returns 0 on success, -1 when no CPU-related thermal sensor answered.
int ftop_read_temperature(ftop_temperature *out);

// ---- GPU ----

typedef struct {
    double active;      // 0...1 share of the interval the GPU was powered, or -1
    double mhz;         // active-time weighted frequency, or -1 when unknown or idle all interval
    double max_mhz;     // top of the GPU's frequency table, or -1
    int steps;          // active states the channel reports
    int table_steps;    // values in the GPU's frequency table, 0 when none was found
    int uncovered_state;      // index of the first state past the table's end that had residency, or -1
    char uncovered_name[32];  // its name as IOReport gives it, e.g. "P14"; set by the sampler only
} ftop_gpu_freq;

// Whether a state's name means the device was not running: "IDLE", "DOWN", "OFF".
int ftop_state_is_idle(const char *name);
// The frequency over an interval from the residency of each state and the frequency
// table; no system calls. `idle[i]` is non-zero for a state that is not a performance
// state; the n-th of the others runs at the n-th table value. The channel may list
// more of them than the table has values: the frequency is known as long as none of
// those had residency, and unknown (`mhz` and `max_mhz` -1, `uncovered_state` set)
// when one did. Nothing is assumed about the frequency of a state the table lacks.
void ftop_gpu_frequency(const int64_t *residencies, const uint8_t *idle, int states, const double *table, int table_count, ftop_gpu_freq *out);

typedef struct ftop_gpu_sampler ftop_gpu_sampler;

ftop_gpu_sampler *ftop_gpu_sampler_create(void);
void ftop_gpu_sampler_destroy(ftop_gpu_sampler *sampler);
// Fills `out` with the delta since the previous call. Returns 0, or -1 when no sample is available.
int ftop_gpu_sampler_update(ftop_gpu_sampler *sampler, ftop_gpu_freq *out);
// The same as `ftop_cpu_sampler_describe`, for the GPU.
int ftop_gpu_sampler_describe(ftop_gpu_sampler *sampler, char *buffer, int capacity);
// Joules the GPU used since the previous call, or -1.
double ftop_gpu_sampler_energy(ftop_gpu_sampler *sampler);

typedef struct {
    double utilization;   // 0...1 as the graphics driver reports it, or -1
    double memory_bytes;  // unified memory in use by the GPU, or -1
} ftop_gpu_stats;

// Returns 0 when the graphics driver answered, -1 otherwise.
int ftop_gpu_read_stats(ftop_gpu_stats *out);

// ---- Controller (SMC) ----

// Average of the controller's GPU temperature sensors (keys starting "Tg"). `source` is not set.
// Returns 0 on success, -1 when none answered.
int ftop_smc_gpu_temperature(ftop_temperature *out);
// Reads one floating-point key such as "PSTR". Returns 0 on success, -1 otherwise.
int ftop_smc_read_float(const char *key, double *out);

#endif
