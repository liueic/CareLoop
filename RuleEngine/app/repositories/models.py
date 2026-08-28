from __future__ import annotations

import uuid
from datetime import datetime, timezone

from sqlalchemy import JSON, DateTime, Float, Index, String, Text
from sqlalchemy.orm import Mapped, mapped_column

from app.core.database import Base


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


def _new_id() -> str:
    return str(uuid.uuid4())


class User(Base):
    __tablename__ = "users"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_new_id)
    external_id: Mapped[str | None] = mapped_column(String(128), unique=True, nullable=True, index=True)
    profile: Mapped[dict] = mapped_column(JSON, default=dict)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow, onupdate=_utcnow)


class Evaluation(Base):
    __tablename__ = "evaluations"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_new_id)
    user_id: Mapped[str | None] = mapped_column(String(36), nullable=True, index=True)
    evaluation_type: Mapped[str] = mapped_column(String(32), default="full")
    ruleset_version: Mapped[str] = mapped_column(String(32), index=True)
    ruleset_sha256: Mapped[str] = mapped_column(String(64))
    input_digest: Mapped[str] = mapped_column(String(16))
    input_snapshot: Mapped[dict] = mapped_column(JSON)
    output_snapshot: Mapped[dict] = mapped_column(JSON)
    overall_risk: Mapped[str | None] = mapped_column(String(16), nullable=True, index=True)
    domain_count: Mapped[int] = mapped_column(default=0)
    triggered_count: Mapped[int] = mapped_column(default=0)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow)

    __table_args__ = (
        Index("ix_evaluations_user_created", "user_id", "created_at"),
        Index("ix_evaluations_ruleset_digest", "ruleset_version", "input_digest"),
    )


class MeasurementRecord(Base):
    __tablename__ = "measurements"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_new_id)
    user_id: Mapped[str] = mapped_column(String(36), index=True)
    metric: Mapped[str] = mapped_column(String(64), index=True)
    value: Mapped[float] = mapped_column(Float)
    unit: Mapped[str] = mapped_column(String(32))
    device_id: Mapped[str | None] = mapped_column(String(64), nullable=True)
    recorded_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow)
    tags: Mapped[dict] = mapped_column(JSON, default=dict)

    __table_args__ = (
        Index("ix_measurements_user_metric", "user_id", "metric", "recorded_at"),
    )
