from __future__ import annotations

from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.repositories.models import Evaluation, MeasurementRecord, User


async def create_user(session: AsyncSession, external_id: str | None = None, profile: dict | None = None) -> User:
    user = User(external_id=external_id, profile=profile or {})
    session.add(user)
    await session.commit()
    await session.refresh(user)
    return user


async def get_user_by_external_id(session: AsyncSession, external_id: str) -> User | None:
    result = await session.execute(select(User).where(User.external_id == external_id))
    return result.scalar_one_or_none()


async def save_evaluation(
    session: AsyncSession,
    evaluation_id: str,
    user_id: str | None,
    evaluation_type: str,
    ruleset_version: str,
    ruleset_sha256: str,
    input_digest: str,
    input_snapshot: dict[str, Any],
    output_snapshot: dict[str, Any],
    overall_risk: str | None = None,
    domain_count: int = 0,
    triggered_count: int = 0,
) -> Evaluation:
    evaluation = Evaluation(
        id=evaluation_id,
        user_id=user_id,
        evaluation_type=evaluation_type,
        ruleset_version=ruleset_version,
        ruleset_sha256=ruleset_sha256,
        input_digest=input_digest,
        input_snapshot=input_snapshot,
        output_snapshot=output_snapshot,
        overall_risk=overall_risk,
        domain_count=domain_count,
        triggered_count=triggered_count,
    )
    session.add(evaluation)
    await session.commit()
    await session.refresh(evaluation)
    return evaluation


async def get_evaluation(session: AsyncSession, evaluation_id: str) -> Evaluation | None:
    result = await session.execute(select(Evaluation).where(Evaluation.id == evaluation_id))
    return result.scalar_one_or_none()


async def list_user_evaluations(
    session: AsyncSession,
    user_id: str,
    limit: int = 50,
    offset: int = 0,
) -> list[Evaluation]:
    result = await session.execute(
        select(Evaluation)
        .where(Evaluation.user_id == user_id)
        .order_by(Evaluation.created_at.desc())
        .limit(limit)
        .offset(offset)
    )
    return list(result.scalars().all())


async def save_measurements(
    session: AsyncSession,
    user_id: str,
    measurements: list[dict[str, Any]],
) -> list[MeasurementRecord]:
    records = []
    for m in measurements:
        record = MeasurementRecord(
            user_id=user_id,
            metric=m["metric"],
            value=m["value"],
            unit=m.get("unit", ""),
            device_id=m.get("device_id"),
            recorded_at=m.get("recorded_at"),
            tags=m.get("tags", {}),
        )
        session.add(record)
        records.append(record)
    await session.commit()
    return records


async def get_user_measurements(
    session: AsyncSession,
    user_id: str,
    metric: str | None = None,
    limit: int = 500,
) -> list[MeasurementRecord]:
    query = select(MeasurementRecord).where(MeasurementRecord.user_id == user_id)
    if metric:
        query = query.where(MeasurementRecord.metric == metric)
    query = query.order_by(MeasurementRecord.recorded_at.desc()).limit(limit)
    result = await session.execute(query)
    return list(result.scalars().all())
