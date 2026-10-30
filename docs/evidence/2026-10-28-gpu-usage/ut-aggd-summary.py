"""Per-state averages of a ut-aggd-sample CSV: busy, clock, power, driver %, and the UT Engagement counters."""
import csv, sys, collections

rows = list(csv.DictReader(open(sys.argv[1])))
by = collections.OrderedDict()
for r in rows:
    by.setdefault(r["label"], []).append(r)

def f(r, k):
    v = r.get(k, "")
    return float(v) if v not in ("", None) else None

def tot(r, prefix):
    return sum(float(v) for k, v in r.items() if k.startswith(prefix) and v not in ("", None))

hb = [k for k in rows[0] if k.startswith("UT_Engagement_centi-%_Histogram") and ":b" in k]
throttle = [k for k in rows[0] if k.startswith("GPU_Throttler_Counters")]
print("label,n,busy_pct,mhz,gpu_w,driver_pct,count_per_s,not_engaged_per_s,engaged_per_s,sum_per_s,mean_engaged_centi,mean_all_centi,engaged_frac,engaged_per_busy_s,top_state,buckets,throttle_deltas")
for label, rs in by.items():
    rs = rs[2:] if len(rs) > 4 else rs  # let the load settle
    n = len(rs)
    dt = sum(f(r, "interval_s") for r in rs)
    avg = lambda k: (lambda xs: sum(xs) / len(xs) if xs else None)([f(r, k) for r in rs if f(r, k) is not None])
    count = sum(tot(r, "aggd:Count_") for r in rs)
    ne = sum(tot(r, "aggd:UT_Not_Engaged") for r in rs)
    s = sum(tot(r, "aggd:Sum_") for r in rs)
    eng = count - ne
    busy = avg("gpuph_busy_pct")
    states = collections.Counter()
    for r in rs:
        for k, v in r.items():
            if k.startswith("aggd:Count_") and v and float(v): states[k.split("_")[-1]] += float(v)
    buckets = [sum(f(r, k) or 0 for r in rs) for k in hb]
    bstr = " ".join("b%d:%d" % (i, b) for i, b in enumerate(buckets) if b)
    th = {k.split(":")[1].strip(): sum(f(r, k) or 0 for r in rs) for k in throttle}
    tstr = " ".join("%s=%d" % (k.replace(" ", ""), v) for k, v in th.items() if v)
    fmt = lambda x, d=1: "" if x is None else ("%.*f" % (d, x))
    print(",".join([label, str(n), fmt(busy), fmt(avg("gpuph_mhz"), 0), fmt(avg("gpu_w"), 2), fmt(avg("driver_device_pct")),
                    fmt(count / dt, 0), fmt(ne / dt, 0), fmt(eng / dt, 0), fmt(s / dt, 0),
                    fmt(s / eng if eng else None, 2), fmt(s / count if count else None, 2), fmt(eng / count if count else None, 3),
                    fmt(eng / dt / (busy / 100) if busy else None, 0),
                    "P%s" % states.most_common(1)[0][0] if states else "", bstr, tstr]))
