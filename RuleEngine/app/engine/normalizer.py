from __future__ import annotations

from datetime import datetime
from typing import Any

from app.engine.models import DataQualityIssue, Measurement
from app.kb.schema import MetricsRegistry


def convert_to_canonical(
    metric: str,
    value: float,
    unit: str,
    metrics_reg: MetricsRegistry,
) -> float:
    if metric not in metrics_reg.metrics:
        return value

    metric_def = metrics_reg.metrics[metric]
    if unit == metric_def.unit_canonical:
        return value

    if metric_def.conversions:
        for conv in metric_def.conversions:
            if conv["from"] == unit:
                if conv["op"] == "div":
                    return value / conv["factor"]
                elif conv["op"] == "mul":
                    return value * conv["factor"]
    return value


def check_plausible_range(
    metric: str,
    value: float,
    metrics_reg: MetricsRegistry,
) -> bool:
    if metric not in metrics_reg.metrics:
        return True
    low, high = metrics_reg.metrics[metric].plausible_range
    return low <= value <= high


def normalize_measurements(
    raw_measurements: list[dict[str, Any]],
    metrics_reg: MetricsRegistry,
) -> tuple[list[Measurement], list[DataQualityIssue]]:
    measurements = []
    quality_issues = []

    for raw in raw_measurements:
        metric = raw.get("metric")
        value = raw.get("value")
        unit = raw.get("unit", "")
        ts_str = raw.get("ts")
        device_id = raw.get("device_id", "unknown")
        tags = raw.get("tags", {})

        if metric is None or value is None:
            continue

        try:
            value = float(value)
        except (ValueError, TypeError):
            continue

        converted_value = convert_to_canonical(metric, value, unit, metrics_reg)

        if not check_plausible_range(metric, converted_value, metrics_reg):
            ts = None
            if ts_str:
                try:
                    ts = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
                except (ValueError, AttributeError):
                    pass
            quality_issues.append(DataQualityIssue(
                metric=metric,
                value=converted_value,
                reason="out_of_range",
                ts=ts,
            ))
            continue

        ts = datetime.now()
        if ts_str:
            try:
                ts = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
            except (ValueError, AttributeError):
                pass

        canonical_unit = metrics_reg.metrics[metric].unit_canonical if metric in metrics_reg.metrics else unit

        measurements.append(Measurement(
            metric=metric,
            value=converted_value,
            unit=canonical_unit,
            ts=ts,
            device_id=device_id,
            tags=tags,
        ))

    return measurements, quality_issues
