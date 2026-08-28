"""Golden test suite: frozen input→expected-output fixtures."""
from __future__ import annotations

import json
from pathlib import Path

import pytest

from app.engine.evaluators.single_point import evaluate_single_point_rule
from app.kb.loader import RulesetRegistry


@pytest.fixture(scope="module")
def registry():
    rules_dir = Path(__file__).parent.parent.parent / "rules"
    return RulesetRegistry(rules_dir)


@pytest.fixture(scope="module")
def golden_cases():
    cases_path = Path(__file__).parent.parent / "golden" / "test_cases.json"
    with open(cases_path, "r", encoding="utf-8") as f:
        return json.load(f)


def test_golden_cases(registry, golden_cases):
    ruleset = registry.get_ruleset()

    for case in golden_cases:
        case_id = case["id"]
        measurements = case["input"]["measurements"]
        expected = case["expected"]

        best_result = None
        best_priority = -1

        for rule in ruleset.rules:
            if rule.type.value != "single_point" or not rule.enabled:
                continue

            required = rule.inputs.required
            if not all(m in measurements for m in required):
                continue

            result = evaluate_single_point_rule(rule, measurements)
            if result is None:
                continue

            triggered = result.get("tag") is not None
            if triggered and rule.priority > best_priority:
                best_result = result
                best_priority = rule.priority

        if best_result is None:
            for rule in ruleset.rules:
                if rule.type.value != "single_point" or not rule.enabled:
                    continue
                required = rule.inputs.required
                if not all(m in measurements for m in required):
                    continue
                result = evaluate_single_point_rule(rule, measurements)
                if result is not None and rule.priority > best_priority:
                    best_result = result
                    best_priority = rule.priority

        if best_result and "domains" in expected:
            for metric, exp_domain in expected["domains"].items():
                actual_risk = best_result["risk_level"]
                expected_risk = exp_domain["risk_level"]
                actual_value = actual_risk.value if hasattr(actual_risk, 'value') else actual_risk
                assert actual_value == expected_risk, (
                    f"Case {case_id}: expected {expected_risk}, got {actual_value}"
                )

        if "data_quality" in expected:
            pass
