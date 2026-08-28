from __future__ import annotations

from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.engine.evaluators.composite import RISK_ORDER
from app.kb.loader import RulesetRegistry
from app.repositories import evaluation_repo
from app.repositories.models import Evaluation, User
from app.services.evaluation_service import run_and_save_evaluation
from app.services.measurement_service import build_history_list, build_latest_measurements


async def get_active_user_ids(session: AsyncSession) -> list[str]:
    result = await session.execute(
        select(Evaluation.user_id).where(
            Evaluation.user_id.isnot(None)
        ).distinct()
    )
    return [row[0] for row in result.all() if row[0]]


async def reevaluate_user(
    session: AsyncSession,
    user_id: str,
    registry: RulesetRegistry,
    version: str | None = None,
) -> dict[str, Any] | None:
    measurements = await build_latest_measurements(session, user_id)
    if not measurements:
        return None

    history = await build_history_list(session, user_id)

    user = await session.get(User, user_id)
    user_profile = user.profile if user else None

    prev_evals = await evaluation_repo.list_user_evaluations(session, user_id, limit=1)
    prev_risk = prev_evals[0].overall_risk if prev_evals else None

    output = await run_and_save_evaluation(
        registry=registry,
        session=session,
        measurements=measurements,
        user_id=user_id,
        user_profile=user_profile,
        history=history if len(history) >= 2 else None,
        evaluation_type="full",
        version=version,
    )

    new_risk = None
    for domain_data in output.get("domains", {}).values():
        r = domain_data.get("risk_level")
        if r and (new_risk is None or RISK_ORDER.get(r, 0) > RISK_ORDER.get(new_risk, 0)):
            new_risk = r

    risk_changed = prev_risk != new_risk
    risk_direction = None
    if risk_changed and prev_risk and new_risk:
        prev_order = RISK_ORDER.get(prev_risk, 0)
        new_order = RISK_ORDER.get(new_risk, 0)
        risk_direction = "escalated" if new_order > prev_order else "de_escalated"

    return {
        "user_id": user_id,
        "previous_risk": prev_risk,
        "current_risk": new_risk,
        "risk_changed": risk_changed,
        "risk_direction": risk_direction,
        "domain_count": len(output.get("domains", {})),
        "triggered_count": sum(
            len(d.get("triggered_rules", []))
            for d in output.get("domains", {}).values()
        ),
        "evaluation_id": output.get("evaluation_id"),
    }


async def run_batch_reevaluation(
    session: AsyncSession,
    registry: RulesetRegistry,
    version: str | None = None,
) -> dict[str, Any]:
    user_ids = await get_active_user_ids(session)

    results = []
    escalated = []
    de_escalated = []
    unchanged = []

    for user_id in user_ids:
        result = await reevaluate_user(session, user_id, registry, version)
        if result is None:
            continue
        results.append(result)
        if result["risk_direction"] == "escalated":
            escalated.append(result)
        elif result["risk_direction"] == "de_escalated":
            de_escalated.append(result)
        else:
            unchanged.append(result)

    return {
        "total_users": len(user_ids),
        "evaluated_users": len(results),
        "escalated": [
            {"user_id": r["user_id"], "from": r["previous_risk"], "to": r["current_risk"]}
            for r in escalated
        ],
        "de_escalated": [
            {"user_id": r["user_id"], "from": r["previous_risk"], "to": r["current_risk"]}
            for r in de_escalated
        ],
        "unchanged_count": len(unchanged),
        "ruleset_version": registry.active_version if version is None else version,
    }
