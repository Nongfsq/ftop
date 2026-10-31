# Is "GPU UT AggD Stats" core occupancy? (2026-10-31)

An English summary of the contributor's note. Raw samples, channel dumps, and the C and
Swift probes are in pull request 30's history, not in the repository.

**No.** These channels count a driver control loop's "UT engagement", sampled about
every 0.27 ms while the GPU is powered and kept per clock step. It behaves like a
throttle loop. It does not say how many cores are busy or how full they are. A normal
user and root see the same IOReport channels, and `powermetrics` has no per-core GPU
field. On this machine core occupancy cannot be read.

Machine: Mac17,14, M5 Max, 40-core GPU, 13 steps 338–1620 MHz, two 5K displays,
macOS 26B123; measured 2026-10-31 03:20–03:50.

## Channels

- "GPU UT AggD Stats": `Count`, `Not_Engaged`, `Sum` (centi-%), `Min` and `Max`
  (since boot) per perf state 0–15. "GPU UT Engagement": the same quantity as a
  histogram per state. `Count − Not_Engaged` equals the histogram's hits and `Sum` its
  total, so AggD summarizes the histogram.
- `Count` runs at about 3.4–3.8 kHz of powered time and stops while `GPUPH` is OFF: it
  is a timer of powered time, with no load in it.

## Method

One-second samples of these channels with `GPUPH`, the throttler counters, `GPU_PPM`,
and "GPU Energy", plus the driver's `Device Utilization %`. Loads: `stress.swift` with
2^10 … 2^20 threads (same kernel), and a compositing-only window of 60 moving
translucent layers. 33 samples per state after 3 s to settle. Averages are in
`ut-aggd-summary.csv`.

## Result

| State | `GPUPH` busy % | MHz while busy | GPU W | Driver % | Engaged share | Mean engaged (centi-%) |
|---|---|---|---|---|---|---|
| Desktop at rest | 33.6 | 341 | 0.65 | 37 | 0.44 | 8.5 |
| Compositing | 58.8 | 1455 | 12.2 | 50 | 0.44 | 19.3 |
| 2^10 threads | 98.0 | 1600 | 8.7 | 87 | 0.32 | 7.7 |
| 2^14 threads | 98.6 | 1604 | 31.7 | 91 | 0.32 | 7.5 |
| 2^20 threads | 99.8 | 1617 | 86.1 | 98 | 0.29 | 4.7 |

The deciding pair is 2^10 against 2^20: the same busy share and clock, ten times the
watts. Engagement stays flat or falls (correlation with watts across the six compute
loads: mean engaged −0.59, `Sum`/s −0.63, engaged share −0.75), and compositing scores
highest at 12 W. It follows the kind of work, not how much of the GPU is used.

## Other channels looked at

Of 11,146 IOReport channels, every one whose name mentions core, cluster, shader, ALU,
occupancy, active, engagement, or aggregate was read. Active and idle time histograms,
Fender state, CS and GPU throttler counters, PWRCTRL, AFRSTATE, BSTGPUPH, GPU_CLTM, the
voltage-temperature grid, and the SoC's per-MGPU throttle events are time shares,
control modes, or events, the same for 2^10 and 2^20, or always zero. The GPU is split
into four MGPU blocks on two rails, but no block reports its own activity. "GPU
Energy" is the only quantity that grows with cores in use, and it is the watts.

## As root

Listing IOReport as root gives the same 11,147 lines. `powermetrics --samplers
gpu_power` reports active frequency, step residency, requested state, idle residency,
and power: 98 % busy, 1600 MHz, 7.4–8.5 W at 2^10; 99.9 %, 1618 MHz, 84 W at 2^20. No
core field.

## For ftop

Do not use UT engagement. The remaining gap between the clock-weighted figure and the
power share (about 2.8×) is the share of cores busy, which no counter reports without a
per-chip full-load reference. Limits: one compute kernel and one compositing load, M5
Max (G17X driver) only; what UT engagement measures is a guess.
