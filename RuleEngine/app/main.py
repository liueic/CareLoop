from __future__ import annotations

from pathlib import Path
from typing import Any

from fastapi import Depends, FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.core.database import async_session, get_session, init_db
from app.engine.pipeline import evaluate_full, evaluate_point, evaluate_trend
from app.kb.loader import RulesetRegistry
from app.repositories import evaluation_repo
from app.services.evaluation_service import replay_evaluation, run_and_save_evaluation
from app.services import measurement_service
from app.workers.batch_reevaluation import run_batch_reevaluation

app = FastAPI(
    title=settings.app_name,
    version=settings.app_version,
    description="Deterministic health management rule engine",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

registry: RulesetRegistry | None = None


@app.on_event("startup")
async def startup():
    global registry
    rules_dir = Path(settings.rules_dir)
    if not rules_dir.is_absolute():
        rules_dir = Path.cwd() / rules_dir
    registry = RulesetRegistry(rules_dir)
    await init_db()


@app.get("/healthz")
async def healthz():
    return {"status": "ok"}


@app.get("/api/v1/rules/versions")
async def list_versions():
    if registry is None:
        raise HTTPException(500, "Registry not initialized")
    return {"versions": registry.list_versions(), "active": registry.active_version}


@app.get("/api/v1/rules/trace/{rule_id}")
async def trace_rule(rule_id: str):
    if registry is None:
        raise HTTPException(500, "Registry not initialized")
    ruleset = registry.get_ruleset()
    for rule in ruleset.rules:
        if rule.id == rule_id:
            return {
                "rule_id": rule.id,
                "name": rule.name,
                "type": rule.type.value,
                "confidence": rule.confidence.value,
                "evidence": [e.model_dump() for e in rule.evidence],
                "advice_ids": rule.advice_ids or [],
            }
    raise HTTPException(404, f"Rule {rule_id} not found")


@app.post("/api/v1/evaluate/point")
async def evaluate_point_endpoint(payload: dict[str, Any]):
    if registry is None:
        raise HTTPException(500, "Registry not initialized")

    measurements = payload.get("measurements", {})
    if not measurements:
        raise HTTPException(400, "No measurements provided")

    version = payload.get("version")
    result = evaluate_point(measurements, registry, version)
    return result.to_dict()


@app.post("/api/v1/evaluate/trend")
async def evaluate_trend_endpoint(payload: dict[str, Any]):
    if registry is None:
        raise HTTPException(500, "Registry not initialized")

    measurements = payload.get("measurements", [])
    if not measurements:
        raise HTTPException(400, "No measurements provided")

    version = payload.get("version")
    result = evaluate_trend(measurements, registry, version)
    return result.to_dict()


@app.post("/api/v1/evaluate")
async def evaluate_full_pipeline(payload: dict[str, Any]):
    if registry is None:
        raise HTTPException(500, "Registry not initialized")

    measurements = payload.get("measurements", {})
    if not measurements:
        raise HTTPException(400, "No measurements provided")

    user_profile = payload.get("user_profile")
    history = payload.get("history")
    version = payload.get("version")

    result = evaluate_full(measurements, registry, user_profile, history, version)
    return result.to_dict()


@app.post("/api/v1/users")
async def create_user(payload: dict[str, Any], session: AsyncSession = Depends(get_session)):
    external_id = payload.get("external_id")
    profile = payload.get("profile", {})
    user = await evaluation_repo.create_user(session, external_id, profile)
    return {"id": user.id, "external_id": user.external_id, "profile": user.profile}


@app.post("/api/v1/users/{user_id}/evaluate")
async def evaluate_user(
    user_id: str,
    payload: dict[str, Any],
    session: AsyncSession = Depends(get_session),
):
    if registry is None:
        raise HTTPException(500, "Registry not initialized")

    measurements = payload.get("measurements", {})
    if not measurements:
        raise HTTPException(400, "No measurements provided")

    user_profile = payload.get("user_profile")
    history = payload.get("history")
    version = payload.get("version")
    eval_type = payload.get("type", "full")

    output = await run_and_save_evaluation(
        registry=registry,
        session=session,
        measurements=measurements,
        user_id=user_id,
        user_profile=user_profile,
        history=history,
        evaluation_type=eval_type,
        version=version,
    )
    return output


@app.get("/api/v1/users/{user_id}/evaluations")
async def list_user_evaluations(
    user_id: str,
    limit: int = 50,
    offset: int = 0,
    session: AsyncSession = Depends(get_session),
):
    evaluations = await evaluation_repo.list_user_evaluations(session, user_id, limit, offset)
    return {
        "evaluations": [
            {
                "id": e.id,
                "evaluation_type": e.evaluation_type,
                "ruleset_version": e.ruleset_version,
                "overall_risk": e.overall_risk,
                "domain_count": e.domain_count,
                "triggered_count": e.triggered_count,
                "created_at": e.created_at.isoformat() if e.created_at else None,
            }
            for e in evaluations
        ]
    }


@app.get("/api/v1/evaluations/{evaluation_id}")
async def get_evaluation(evaluation_id: str, session: AsyncSession = Depends(get_session)):
    evaluation = await evaluation_repo.get_evaluation(session, evaluation_id)
    if not evaluation:
        raise HTTPException(404, f"Evaluation {evaluation_id} not found")
    return {
        "id": evaluation.id,
        "user_id": evaluation.user_id,
        "evaluation_type": evaluation.evaluation_type,
        "ruleset_version": evaluation.ruleset_version,
        "ruleset_sha256": evaluation.ruleset_sha256,
        "input_digest": evaluation.input_digest,
        "input_snapshot": evaluation.input_snapshot,
        "output_snapshot": evaluation.output_snapshot,
        "overall_risk": evaluation.overall_risk,
        "domain_count": evaluation.domain_count,
        "triggered_count": evaluation.triggered_count,
        "created_at": evaluation.created_at.isoformat() if evaluation.created_at else None,
    }


@app.post("/api/v1/evaluations/{evaluation_id}/replay")
async def replay_eval(evaluation_id: str, session: AsyncSession = Depends(get_session)):
    if registry is None:
        raise HTTPException(500, "Registry not initialized")

    try:
        result = await replay_evaluation(registry, session, evaluation_id)
    except ValueError as e:
        raise HTTPException(404, str(e))
    return result


@app.post("/api/v1/users/{user_id}/measurements")
async def ingest_measurements(
    user_id: str,
    payload: dict[str, Any],
    session: AsyncSession = Depends(get_session),
):
    if registry is None:
        raise HTTPException(500, "Registry not initialized")

    raw = payload.get("measurements", [])
    if not raw:
        raise HTTPException(400, "No measurements provided")

    result = await measurement_service.ingest_measurements(
        session, user_id, raw, registry.metrics
    )
    return result


@app.get("/api/v1/users/{user_id}/measurements")
async def query_measurements(
    user_id: str,
    metric: str | None = None,
    limit: int = 200,
    session: AsyncSession = Depends(get_session),
):
    records = await evaluation_repo.get_user_measurements(session, user_id, metric, limit)
    return {
        "user_id": user_id,
        "count": len(records),
        "measurements": [
            {
                "metric": r.metric,
                "value": r.value,
                "unit": r.unit,
                "device_id": r.device_id,
                "recorded_at": r.recorded_at.isoformat() if r.recorded_at else None,
                "tags": r.tags,
            }
            for r in records
        ],
    }


@app.post("/api/v1/users/{user_id}/evaluate-from-data")
async def evaluate_from_stored_data(
    user_id: str,
    payload: dict[str, Any] | None = None,
    session: AsyncSession = Depends(get_session),
):
    if registry is None:
        raise HTTPException(500, "Registry not initialized")

    payload = payload or {}
    measurements = await measurement_service.build_latest_measurements(session, user_id)
    if not measurements:
        raise HTTPException(404, f"No measurements found for user {user_id}")

    history = await measurement_service.build_history_list(session, user_id)

    from app.repositories.models import User
    user = await session.get(User, user_id)
    user_profile = payload.get("user_profile") or (user.profile if user else None)

    output = await run_and_save_evaluation(
        registry=registry,
        session=session,
        measurements=measurements,
        user_id=user_id,
        user_profile=user_profile,
        history=history if len(history) >= 2 else None,
        evaluation_type="full",
        version=payload.get("version"),
    )
    return output


@app.post("/api/v1/batch/reevaluate")
async def batch_reevaluate(
    payload: dict[str, Any] | None = None,
    session: AsyncSession = Depends(get_session),
):
    if registry is None:
        raise HTTPException(500, "Registry not initialized")

    payload = payload or {}
    version = payload.get("version")

    result = await run_batch_reevaluation(session, registry, version)
    return result
