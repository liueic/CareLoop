from __future__ import annotations

import math
from datetime import datetime, timedelta, timezone
from typing import Any

from app.engine.models import Measurement


def compute_mean(values: list[float]) -> float:
    if not values:
        return 0.0
    return sum(values) / len(values)


def compute_std(values: list[float], mean: float) -> float:
    if len(values) < 2:
        return 0.0
    variance = sum((x - mean) ** 2 for x in values) / (len(values) - 1)
    return math.sqrt(variance)


def compute_ols_slope(times: list[datetime], values: list[float]) -> float:
    if len(times) < 2:
        return 0.0
    n = len(times)
    t0 = times[0]
    x = [(t - t0).total_seconds() / 86400.0 for t in times]
    y = values
    x_mean = sum(x) / n
    y_mean = sum(y) / n
    numerator = sum((x[i] - x_mean) * (y[i] - y_mean) for i in range(n))
    denominator = sum((x[i] - x_mean) ** 2 for i in range(n))
    if denominator == 0:
        return 0.0
    slope_per_day = numerator / denominator
    return slope_per_day * 7.0


def detect_morning_surge(
    measurements: list[Measurement],
    surge_threshold: float = 20.0,
) -> dict[str, Any] | None:
    morning_values = []
    for m in measurements:
        if 5 <= m.ts.hour <= 10:
            morning_values.append(m.value)
    if len(morning_values) < 2:
        return None
    morning_mean = compute_mean(morning_values)
    all_values = [m.value for m in measurements]
    overall_mean = compute_mean(all_values)
    surge = morning_mean - overall_mean
    if surge >= surge_threshold:
        return {
            "morning_mean": round(morning_mean, 2),
            "overall_mean": round(overall_mean, 2),
            "surge": round(surge, 2),
        }
    return None


def compute_tir(
    measurements: list[Measurement],
    target_range: tuple[float, float] = (3.9, 10.0),
) -> dict[str, float]:
    if not measurements:
        return {"tir": 0.0, "tar": 0.0, "tbr": 0.0}
    in_range = 0
    above = 0
    below = 0
    for m in measurements:
        if target_range[0] <= m.value <= target_range[1]:
            in_range += 1
        elif m.value > target_range[1]:
            above += 1
        else:
            below += 1
    total = len(measurements)
    return {
        "tir": round(in_range / total * 100, 2),
        "tar": round(above / total * 100, 2),
        "tbr": round(below / total * 100, 2),
    }


def apply_window(
    measurements: list[Measurement],
    days: int,
    now: datetime | None = None,
) -> list[Measurement]:
    if now is None:
        now = datetime.now(timezone.utc)
    cutoff = now - timedelta(days=days)
    result = []
    for m in measurements:
        ts = m.ts
        if ts.tzinfo is None:
            ts = ts.replace(tzinfo=timezone.utc)
        if cutoff.tzinfo is None:
            cutoff_cmp = cutoff.replace(tzinfo=timezone.utc)
        else:
            cutoff_cmp = cutoff
        if ts >= cutoff_cmp:
            result.append(m)
    return result


def aggregate_trend(
    measurements: list[Measurement],
) -> dict[str, Any]:
    if not measurements:
        return {}
    values = [m.value for m in measurements]
    times = [m.ts for m in measurements]
    mean_val = compute_mean(values)
    std_val = compute_std(values, mean_val)
    slope = compute_ols_slope(times, values)
    return {
        "mean": round(mean_val, 2),
        "std": round(std_val, 2),
        "slope_per_week": round(slope, 3),
        "min": round(min(values), 2),
        "max": round(max(values), 2),
        "count": len(values),
    }


def evaluate_trend_rule(
    rule_id: str,
    measurements: list[Measurement],
    conditions: dict[str, Any],
    window_days: int = 7,
    min_samples: int = 3,
) -> dict[str, Any] | None:
    windowed = apply_window(measurements, window_days)
    if len(windowed) < min_samples:
        return None

    agg = aggregate_trend(windowed)
    if not agg:
        return None

    metric = measurements[0].metric if measurements else "unknown"

    if metric == "blood_glucose":
        tir_data = compute_tir(windowed)
        agg.update(tir_data)

    if metric in ("sbp", "dbp"):
        surge = detect_morning_surge(windowed)
        if surge:
            agg["morning_surge"] = surge

    any_conditions = conditions.get("any", [])
    for branch in any_conditions:
        agg_conds = branch.get("aggregate", {})
        if not agg_conds:
            continue
        match = True
        for agg_key, threshold in agg_conds.items():
            if agg_key not in agg:
                match = False
                break
            value = agg[agg_key]
            if isinstance(threshold, dict):
                if "gte" in threshold and value < threshold["gte"]:
                    match = False
                if "gt" in threshold and value <= threshold["gt"]:
                    match = False
                if "lt" in threshold and value >= threshold["lt"]:
                    match = False
                if "lte" in threshold and value > threshold["lte"]:
                    match = False
            if not match:
                break
        if match:
            return {
                "rule_id": rule_id,
                "risk_level": branch.get("output_risk", "normal"),
                "tag": branch.get("tag"),
                "aggregates": agg,
                "window_days": window_days,
                "sample_count": len(windowed),
            }

    default_risk = conditions.get("default_risk", "normal")
    return {
        "rule_id": rule_id,
        "risk_level": default_risk,
        "tag": None,
        "aggregates": agg,
        "window_days": window_days,
        "sample_count": len(windowed),
    }
