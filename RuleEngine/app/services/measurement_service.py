from __future__ import annotations

from datetime import datetime, timezone
from typing import Any

from app.engine.normalizer import check_plausible_range, convert_to_canonical
from app.kb.loader import RulesetRegistry
from app.kb.schema import MetricsRegistry
from app.repositories import evaluation_repo
from app.repositories.models import MeasurementRecord
from app.services.evaluation_service import run_and_save_evaluation


async def ingest_measurements(
    session,
    user_id: str,
    raw_measurements: list[dict[str, Any]],
    metrics_reg: MetricsRegistry,
) -> dict[str, Any]:
    ingested = []
    quality_issues = []

    for raw in raw_measurements:
        metric = raw.get("metric")
        value = raw.get("value")
        unit = raw.get("unit", "")
        device_id = raw.get("device_id")
        tags = raw.get("tags", {})
        ts_str = raw.get("recorded_at") or raw.get("ts")

        if metric is None or value is None:
            continue

        try:
            value = float(value)
        except (ValueError, TypeError):
            quality_issues.append({
                "metric": metric,
                "value": value,
                "reason": "invalid_value",
            })
            continue

        converted_value = convert_to_canonical(metric, value, unit, metrics_reg)

        if not check_plausible_range(metric, converted_value, metrics_reg):
            quality_issues.append({
                "metric": metric,
                "value": converted_value,
                "reason": "out_of_range",
            })
            continue

        canonical_unit = (
            metrics_reg.metrics[metric].unit_canonical
            if metric in metrics_reg.metrics
            else unit
        )

        recorded_at = datetime.now(timezone.utc)
        if ts_str:
            try:
                recorded_at = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
            except (ValueError, AttributeError):
                pass

        record = MeasurementRecord(
            user_id=user_id,
            metric=metric,
            value=converted_value,
            unit=canonical_unit,
            device_id=device_id,
            recorded_at=recorded_at,
            tags=tags,
        )
        session.add(record)
        ingested.append({
            "metric": metric,
            "value": converted_value,
            "unit": canonical_unit,
            "recorded_at": recorded_at.isoformat(),
        })

    await session.commit()

    return {
        "user_id": user_id,
        "ingested_count": len(ingested),
        "ingested": ingested,
        "quality_issues": quality_issues,
    }


async def get_measurements_for_evaluation(
    session,
    user_id: str,
    metrics_reg: MetricsRegistry,
    limit_per_metric: int = 100,
) -> dict[str, list[dict[str, Any]]]:
    records = await evaluation_repo.get_user_measurements(session, user_id, limit=limit_per_metric * 10)

    grouped: dict[str, list[dict[str, Any]]] = {}
    for r in records:
        if r.metric not in grouped:
            grouped[r.metric] = []
        if len(grouped[r.metric]) < limit_per_metric:
            grouped[r.metric].append({
                "metric": r.metric,
                "value": r.value,
                "unit": r.unit,
                "ts": r.recorded_at.isoformat() if r.recorded_at else None,
                "device_id": r.device_id,
                "tags": r.tags or {},
            })

    return grouped


async def build_latest_measurements(
    session,
    user_id: str,
) -> dict[str, float]:
    records = await evaluation_repo.get_user_measurements(session, user_id, limit=500)

    latest: dict[str, MeasurementRecord] = {}
    for r in records:
        if r.metric not in latest or (r.recorded_at and (
            latest[r.metric].recorded_at is None or r.recorded_at > latest[r.metric].recorded_at
        )):
            latest[r.metric] = r

    return {metric: r.value for metric, r in latest.items()}


async def build_history_list(
    session,
    user_id: str,
) -> list[dict[str, Any]]:
    records = await evaluation_repo.get_user_measurements(session, user_id, limit=1000)

    by_ts: dict[str, dict[str, float]] = {}
    for r in records:
        ts_key = r.recorded_at.strftime("%Y-%m-%d") if r.recorded_at else "unknown"
        if ts_key not in by_ts:
            by_ts[ts_key] = {"ts": r.recorded_at.isoformat() if r.recorded_at else None}
        by_ts[ts_key][r.metric] = r.value

    return sorted(by_ts.values(), key=lambda x: x.get("ts") or "")
