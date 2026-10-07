#ifndef CFTOPSYS_H
#define CFTOPSYS_H

#include <stdint.h>

// The only place ftop touches Apple's private IOReport and IOHID event APIs.
// Every function reports failure instead of guessing; callers show "unavailable".

typedef struct {
    char channel[32];   // IOReport channel name, e.g. "PCPU000"
    char kind;          // cluster type letter the channel name starts with: 'P', 'E', 'M', ...
    double active;      // 0...1 share of the interval spent out of idle, or -1
    double mhz;         // active-time weighted frequency, or -1 when unknown
    double max_mhz;     // top of the frequency table that fits this core, or -1
} ftop_core_freq;

typedef struct ftop_cpu_sampler ftop_cpu_sampler;

ftop_cpu_sampler *ftop_cpu_sampler_create(void);
void ftop_cpu_sampler_destroy(ftop_cpu_sampler *sampler);
// Fills `out` with the delta since the previous call, sorted by channel name.
// Returns the number of cores written, or -1 when no sample is available.
int ftop_cpu_sampler_update(ftop_cpu_sampler *sampler, ftop_core_freq *out, int capacity);
// Writes one line per residency state seen in the last delta. Diagnostics only.
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

#endif
