from __future__ import annotations

from typing import Any

from app.kb.schema import Rule, ThresholdCondition


def check_threshold(value: float, condition: ThresholdCondition) -> bool:
    if condition.gte is not None and value < condition.gte:
        return False
    if condition.gt is not None and value <= condition.gt:
        return False
    if condition.lt is not None and value >= condition.lt:
        return False
    if condition.lte is not None and value > condition.lte:
        return False
    if condition.eq is not None and value != condition.eq:
        return False
    return True


def evaluate_single_point_rule(
    rule: Rule,
    measurements: dict[str, float],
) -> dict[str, Any] | None:
    for metric in rule.inputs.required:
        if metric not in measurements:
            return None

    conditions = rule.conditions
    
    if isinstance(conditions, dict):
        any_branches = conditions.get("any", [])
        default_risk = conditions.get("default_risk", "normal")
    else:
        if not hasattr(conditions, "any"):
            return None
        any_branches = conditions.any
        default_risk = getattr(conditions, "default_risk", "normal")

    for branch in any_branches:
        if isinstance(branch, dict):
            all_conditions = branch.get("all")
            output_risk = branch.get("output_risk")
            tag = branch.get("tag")
        else:
            all_conditions = branch.all
            output_risk = branch.output_risk
            tag = branch.tag
            
        if all_conditions is None:
            continue
            
        all_match = True
        for metric, threshold in all_conditions.items():
            if metric not in measurements:
                all_match = False
                break
            if isinstance(threshold, dict):
                threshold_obj = ThresholdCondition(**threshold)
            else:
                threshold_obj = threshold
            if not check_threshold(measurements[metric], threshold_obj):
                all_match = False
                break
                
        if all_match:
            risk_value = output_risk.value if hasattr(output_risk, "value") else output_risk
            return {
                "rule_id": rule.id,
                "risk_level": risk_value,
                "tag": tag,
                "data": measurements,
            }

    default_value = default_risk.value if hasattr(default_risk, "value") else default_risk
    return {
        "rule_id": rule.id,
        "risk_level": default_value,
        "tag": None,
        "data": measurements,
    }
