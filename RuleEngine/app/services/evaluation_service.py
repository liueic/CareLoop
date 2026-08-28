from __future__ import annotations

from typing import Any

from app.engine.pipeline import evaluate_full, evaluate_point, evaluate_trend
from app.kb.loader import RulesetRegistry


def _compute_overall_risk(output: dict[str, Any]) -> str | None:
    from app.engine.evaluators.composite import RISK_ORDER
    risk_levels = [
        d.get("risk_level") for d in output.get("domains", {}).values()
        if d.get("risk_level")
    ]
    if not risk_levels:
        return None
    return max(risk_levels, key=lambda r: RISK_ORDER.get(r, 0))


def _count_triggered(output: dict[str, Any]) -> int:
    return sum(
        len(d.get("triggered_rules", []))
        for d in output.get("domains", {}).values()
    )


async def run_and_save_evaluation(
    registry: RulesetRegistry,
    session,
    measurements: dict[str, float],
    user_id: str | None = None,
    user_profile: dict[str, Any] | None = None,
    history: list[dict[str, Any]] | None = None,
    evaluation_type: str = "full",
    version: str | None = None,
) -> dict[str, Any]:
    from app.repositories.evaluation_repo import save_evaluation

    if evaluation_type == "point":
        result = evaluate_point(measurements, registry, version)
    elif evaluation_type == "trend":
        result = evaluate_trend(history or [], registry, version)
    else:
        result = evaluate_full(measurements, registry, user_profile, history, version)

    output_dict = result.to_dict()
    input_snapshot = {
        "measurements": measurements,
        "user_profile": user_profile or {},
    }
    if history:
        input_snapshot["history"] = history

    overall_risk = _compute_overall_risk(output_dict)
    triggered_count = _count_triggered(output_dict)

    await save_evaluation(
        session=session,
        evaluation_id=result.evaluation_id,
        user_id=user_id,
        evaluation_type=evaluation_type,
        ruleset_version=result.ruleset_version,
        ruleset_sha256=result.ruleset_sha256,
        input_digest=result.input_digest,
        input_snapshot=input_snapshot,
        output_snapshot=output_dict,
        overall_risk=overall_risk,
        domain_count=len(output_dict.get("domains", {})),
        triggered_count=triggered_count,
    )

    return output_dict


async def replay_evaluation(
    registry: RulesetRegistry,
    session,
    evaluation_id: str,
) -> dict[str, Any]:
    from app.repositories.evaluation_repo import get_evaluation

    stored = await get_evaluation(session, evaluation_id)
    if not stored:
        raise ValueError(f"Evaluation {evaluation_id} not found")

    input_snap = stored.input_snapshot
    measurements = input_snap.get("measurements", {})
    user_profile = input_snap.get("user_profile")
    history = input_snap.get("history")

    if stored.evaluation_type == "point":
        new_result = evaluate_point(measurements, registry, stored.ruleset_version)
    elif stored.evaluation_type == "trend":
        new_result = evaluate_trend(history or [], registry, stored.ruleset_version)
    else:
        new_result = evaluate_full(measurements, registry, user_profile, history, stored.ruleset_version)

    new_output = new_result.to_dict()

    old_domains = stored.output_snapshot.get("domains", {})
    new_domains = new_output.get("domains", {})

    diffs = []
    all_keys = set(old_domains.keys()) | set(new_domains.keys())
    for key in sorted(all_keys):
        old_d = old_domains.get(key, {})
        new_d = new_domains.get(key, {})
        if old_d.get("risk_level") != new_d.get("risk_level"):
            diffs.append({
                "domain": key,
                "field": "risk_level",
                "old": old_d.get("risk_level"),
                "new": new_d.get("risk_level"),
            })
        old_rules = [r["rule_id"] for r in old_d.get("triggered_rules", [])]
        new_rules = [r["rule_id"] for r in new_d.get("triggered_rules", [])]
        if old_rules != new_rules:
            diffs.append({
                "domain": key,
                "field": "triggered_rules",
                "old": old_rules,
                "new": new_rules,
            })

    return {
        "original_evaluation_id": evaluation_id,
        "replayed_evaluation_id": new_result.evaluation_id,
        "ruleset_version": stored.ruleset_version,
        "deterministic": len(diffs) == 0,
        "diffs": diffs,
        "replayed_output": new_output,
    }
