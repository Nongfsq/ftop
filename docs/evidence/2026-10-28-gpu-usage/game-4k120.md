# A graphics load: a game at 4K and 120 fps in an emulator (2026-10-31)

An English summary of the contributor's note. The per-second samples, markers, probe
output, and scripts are in pull request 30's history, not in the repository.

Purpose: check the clock-weighted figure against a real graphics load. During play the
contributor saw 45 %, 12.7 W, and a frequency line at about 79 % (about 1.28 GHz) on
the panel built from this branch.

## Method

- M5 Max, one 5K display. A game in the MuMuPlayer Android emulator, rendered at
  3840×2160 and 120 fps.
- One sample a second for 180 s (178 rows): `GPUPH` residencies weighted step by step
  (not by the average clock), GPU watts from "GPU Energy", and the driver's
  `Device Utilization %`. Power share is GPU watts ÷ 84 W (`stress.swift` full load).
  V²·f uses one of the chip's four voltage tables (645 … 1075 mV).
- Segments set by eye from the clock and power curves: baseline 0–14 s, loading
  25–104 s, play 105–167 s.

## Result

Means (medians in brackets).

| Segment | Rows | Busy % | MHz while busy | Driver % | Clock-weighted % | V²·f % | Power share % | GPU W | Clock-weighted ÷ power | V²·f ÷ power |
|---|---|---|---|---|---|---|---|---|---|---|
| Baseline | 13 | 38.7 | 341 | 43.2 | 8.1 | 2.9 | 1.0 | 0.8 | 8.1× | 2.9× |
| Loading | 79 | 52.0 | 920 | 47.1 | 29.6 | 18.7 | 6.5 | 5.4 | 4.6× | 2.9× |
| Play | 61 | 58.6 | 1171 (1201) | 49.9 | 42.1 (42.5) | 33.9 | 12.0 | 10.1 | 3.5× | 2.8× |

During play the clock-weighted figure ranged 27.3–53.6 % and power share 3.1–32.4 %.
Single-second watts swing widely (2.6 W then 27.2 W), so only segment means are
compared.

The clock did not settle: 36.4 % of busy time was at the top step (1620 MHz) and about
26 % at the lowest three (338–636 MHz), apparently rising each frame and dropping
between frames.

## Against the panel and `probe`

- `ftop probe --json` at 115 s: usage 45.9 %, busy 55.7 %, 1335 MHz, source
  `clockWeighted`, 12.6 W. The panel's 45 % falls inside the play segment's range.
- The driver's `Device Utilization %` read 0 six times while `GPUPH` showed 32–62 %
  busy; `GPUPH` never did.

## Observations

Clock-weighted ÷ power share falls as the clock rises (8.1× at 338 MHz, 3.5× near
1.2 GHz); V²·f ÷ power share stays at 2.7–2.9× in every segment. The constant that
remains is consistent with not every core working fully, which no counter reports
(`ut-aggd.md`).

## Limits

One game, one setting, one recording, one display; segment edges set by eye; one of
four voltage tables; the 84 W full load comes from a compute load; the baseline
includes the emulator's compositing.
