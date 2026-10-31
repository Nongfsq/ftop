# GPU usage: observations behind the change (2026-10-28 to 10-31)

An English summary of the contributor's handoff note. The raw samples and the scripts
that took them are in pull request 30's history, not in the repository.

## Setup

- Mac17,14, Apple M5 Max, 40-core GPU, 13 clock steps 338–1620 MHz. Two 5K displays
  (240 Hz and 144 Hz, at 2560×1440 points), so compositing alone keeps the GPU busy.
- Readings from the released 0.2.7 (`ftop probe --json`, a fresh process each time,
  not the running panel) and from IOReport `GPUPH` residencies read directly.

## What ftop 0.2.7 shows

- Usage is the graphics driver's `PerformanceStatistics` → `Device Utilization %`,
  divided by 100 and capped at 100. It is a share of time: it ignores the clock, how
  many cores run, and power, so 0.2 W can read 20 %.
- Frequency is `GPUPH` weighted by the `sgx` node's `perf-states`; power is IOReport
  "GPU Energy".

## 34 hours of samples

2,674 samples every 30 s from 2026-10-28 13:32 to 10-29 23:37 (about 12 h asleep).
Full load is 82.5 W in this run (`stress.swift`, a pure FMA Metal kernel, 2^20
threads: 99.9 % busy, 1619 MHz). Grouped by the clock while busy:

| While busy | Samples | Driver % | Busy × clock ÷ top clock | V²·f (approx.) | Share of full-load watts |
|---|---|---|---|---|---|
| under 500 MHz | 1205 | 20 | 2.3 | 0.8 | 0.2 |
| 500–1100 MHz | 176 | 45 | 27.1 | 13.5 | 6.0 |
| 1100 MHz and up | 376 | 35 | 30.8 | 20.3 | 11.3 |
| full load | — | ~100 | ~100 | 100 | 100 |

Correlation with GPU watts (1,757 samples with the GPU busy): driver % 0.57, `GPUPH`
busy share 0.75, clock-weighted 0.95, V²·f 0.97. V²·f here uses the average clock, not
each step.

`full-load.csv` holds the full-load run (and the seconds around it).

## The driver's false zeros

- `ftop probe` read 0 % 117 times while the driver's other fields and `GPUPH` showed at
  least 10 % busy; 51 were single zeros between normal readings. Reading the driver
  directly with `ioreg` over the same period gave 9.
- Around the full-load run, 7 of 25 direct driver reads at rest were 0 (all three
  fields at once) while `GPUPH` showed 43–46 % busy.
- `GPUPH` residencies never read a false 0 in either period. Whether the running panel
  flickers to 0 the same way was not checked.

## What else is readable as a normal user

- `perf-states` pairs each step with a voltage (645 mV at 338 MHz … 1075 mV at
  1620 MHz); the node lists four tables with the same clocks and slightly different
  voltages, and which one the chip uses is unknown.
- Per-app GPU time (`AGXDeviceUserClient` → `AppUsage`), not used.
- About 263 GPU-related IOReport channels; none reports how many GPU cores are busy
  (see `ut-aggd.md`).

## Options weighed

- Per-model tables or calibration (full-load watts per chip): rejected, upkeep for
  every new chip.
- V²·f: the better power proxy, rejected for the reasons in the decision doc's
  amendment.
- Busy × clock ÷ top clock: chosen. It keeps the column under its frequency line.
