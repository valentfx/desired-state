"""Transparent, provisional time-domain HRV from recorded RR intervals."""
import math
from statistics import mean, stdev

VERSION = "rr-time-domain-v1"


def summarize_rr(rows):
    intervals = list(rows)
    first_stamp = intervals[0].get("received_monotonic_ns") if intervals else None
    last_stamp = intervals[-1].get("received_monotonic_ns") if intervals else None
    span_seconds = round((last_stamp - first_stamp) / 1e9, 1) if isinstance(first_stamp, int) and isinstance(last_stamp, int) and last_stamp >= first_stamp else None
    values = [row.get("rr_ms") for row in intervals]
    valid_range = [isinstance(v, (int, float)) and math.isfinite(v) and 300 <= v <= 2000
                   for v in values]
    accepted = valid_range[:]
    suspect_jumps = 0
    for index in range(1, len(values)):
        previous, current = values[index - 1], values[index]
        if valid_range[index - 1] and valid_range[index] and abs(current - previous) > 0.20 * previous:
            accepted[index] = False
            suspect_jumps += 1

    clean = [value for value, keep in zip(values, accepted) if keep]
    pairs = []
    for index in range(1, len(values)):
        if not (accepted[index - 1] and accepted[index]):
            continue
        # Never bridge a missing packet or Bluetooth reconnect with a false adjacent pair.
        before = intervals[index - 1].get("received_monotonic_ns")
        after = intervals[index].get("received_monotonic_ns")
        if isinstance(before, int) and isinstance(after, int) and (after - before) > 5_000_000_000:
            continue
        pairs.append(values[index] - values[index - 1])

    return {
        "method": VERSION,
        "intervals_total": len(values),
        "intervals_accepted": len(clean),
        "intervals_excluded": len(values) - len(clean),
        "suspect_jumps": suspect_jumps,
        "adjacent_pairs": len(pairs),
        "span_seconds": span_seconds,
        "mean_rr_ms": round(mean(clean), 2) if clean else None,
        "mean_hr_from_rr_bpm": round(60000 / mean(clean), 2) if clean else None,
        "rmssd_ms": round(math.sqrt(mean(delta * delta for delta in pairs)), 2) if pairs else None,
        "sdnn_ms": round(stdev(clean), 2) if len(clean) >= 2 else None,
        "pnn50_percent": round(100 * sum(abs(delta) > 50 for delta in pairs) / len(pairs), 2) if pairs else None,
        "quality_note": "Exploratory RR-based estimates, not verified normal-to-normal beats. "
                        "A 300–2000 ms range and >20% adjacent-jump screen flag intervals; "
                        "no interpolation or manual ectopic-beat review. Five-minute resting sessions "
                        "are preferable for comparison; shorter sessions are exploratory.",
    }
