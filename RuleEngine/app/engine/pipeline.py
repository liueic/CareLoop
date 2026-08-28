from __future__ import annotations

import hashlib
import json
import uuid
from datetime import datetime, timezone
from typing import Any

from app.engine.evaluators.composite import run_composite_evaluation
from app.engine.evaluators.single_point import evaluate_single_point_rule
from app.engine.evaluators.trend import evaluate_trend_rule
from app.engine.models import (
    AdviceItem,
    DataQualityIssue,
    DomainResult,
    EvaluationResult,
    EvidenceRef,
    Measurement,
    RiskLevel,
    TriggeredRule,
)
from app.engine.normalizer import normalize_measurements
from app.kb.loader import RulesetRegistry
from app.kb.schema import Rule


def run_single_point_evaluation(
    measurements_dict: dict[str, float],
    ruleset,
    registry: RulesetRegistry,
) -> tuple[dict[str, DomainResult], list[DataQualityIssue]]:
    domains: dict[str, DomainResult] = {}
    quality_issues = []

    metrics_reg = registry.metrics
    for metric_name, value in measurements_dict.items():
        if metric_name in metrics_reg.metrics:
            metric_def = metrics_reg.metrics[metric_name]
            low, high = metric_def.plausible_range
            if value < low or value > high:
                quality_issues.append(DataQualityIssue(
                    metric=metric_name,
                    value=value,
                    reason="out_of_range",
                ))

    disease_rules: dict[str, list[Rule]] = {}
    for rule in ruleset.rules:
        if rule.type.value != "single_point" or not rule.enabled:
            continue
        cat = rule.inputs.required[0] if rule.inputs.required else "unknown"
        if cat not in disease_rules:
            disease_rules[cat] = []
        disease_rules[cat].append(rule)

    for domain, rules in disease_rules.items():
        best_result = None
        best_priority = -1
        for rule in rules:
            result = evaluate_single_point_rule(rule, measurements_dict)
            if result and rule.priority > best_priority:
                best_result = result
                best_priority = rule.priority

        if best_result:
            risk_level = best_result["risk_level"]
            triggered = TriggeredRule(
                rule_id=best_result["rule_id"],
                risk_level=RiskLevel(risk_level.value if hasattr(risk_level, 'value') else risk_level),
                evidence=[
                    EvidenceRef(
                        guideline=next(
                            (s.title for s in ruleset.sources if s.source_id == e.source_id),
                            "Unknown"
                        ),
                        section=e.section,
                        quote=e.quote,
                    )
                    for rule in rules
                    if rule.id == best_result["rule_id"]
                    for e in rule.evidence
                ],
                confidence=next(
                    (r.confidence.value for r in rules if r.id == best_result["rule_id"]),
                    "unknown"
                ),
                data=best_result["data"],
                tags=[best_result["tag"]] if best_result["tag"] else [],
            )

            advice_list = []
            for rule in rules:
                if rule.id == best_result["rule_id"] and rule.advice_ids:
                    for adv_id in rule.advice_ids:
                        adv = next((a for a in registry.advice.advice if a.id == adv_id), None)
                        if adv:
                            advice_list.append(AdviceItem(id=adv.id, text=adv.text_cn))

            domains[domain] = DomainResult(
                domain=domain,
                risk_level=RiskLevel(risk_level.value if hasattr(risk_level, 'value') else risk_level),
                summary=f"评估完成，风险等级: {risk_level.value if hasattr(risk_level, 'value') else risk_level}",
                triggered_rules=[triggered],
                advice=advice_list,
            )

    return domains, quality_issues


def run_trend_evaluation(
    measurements_list: list[dict[str, Any]],
    ruleset,
    registry: RulesetRegistry,
) -> tuple[dict[str, DomainResult], list[DataQualityIssue]]:
    measurements, quality_issues = normalize_measurements(measurements_list, registry.metrics)

    if not measurements:
        return {}, quality_issues

    metric_groups: dict[str, list[Measurement]] = {}
    for m in measurements:
        if m.metric not in metric_groups:
            metric_groups[m.metric] = []
        metric_groups[m.metric].append(m)

    domains: dict[str, DomainResult] = {}
    trend_rules: dict[str, list[Rule]] = {}

    for rule in ruleset.rules:
        if rule.type.value != "trend" or not rule.enabled:
            continue
        for metric in rule.inputs.required:
            if metric not in trend_rules:
                trend_rules[metric] = []
            trend_rules[metric].append(rule)

    for metric, rules in trend_rules.items():
        if metric not in metric_groups:
            continue

        best_result = None
        best_priority = -1

        for rule in rules:
            window_days = 7
            min_samples = 3
            if rule.inputs.window:
                window_days = rule.inputs.window.days
                min_samples = rule.inputs.window.min_samples

            conditions = rule.conditions
            if isinstance(conditions, dict):
                cond_dict = conditions
            else:
                cond_dict = conditions.model_dump() if hasattr(conditions, 'model_dump') else {}

            result = evaluate_trend_rule(
                rule.id,
                metric_groups[metric],
                cond_dict,
                window_days=window_days,
                min_samples=min_samples,
            )

            if result and rule.priority > best_priority:
                best_result = result
                best_priority = rule.priority

        if best_result:
            risk_level = best_result["risk_level"]
            risk_value = risk_level.value if hasattr(risk_level, 'value') else risk_level

            triggered = TriggeredRule(
                rule_id=best_result["rule_id"],
                risk_level=RiskLevel(risk_value),
                evidence=[
                    EvidenceRef(
                        guideline=next(
                            (s.title for s in ruleset.sources if s.source_id == e.source_id),
                            "Unknown"
                        ),
                        section=e.section,
                        quote=e.quote,
                    )
                    for rule in rules
                    if rule.id == best_result["rule_id"]
                    for e in rule.evidence
                ],
                confidence=next(
                    (r.confidence.value for r in rules if r.id == best_result["rule_id"]),
                    "unknown"
                ),
                data=best_result.get("aggregates", {}),
                tags=[best_result["tag"]] if best_result.get("tag") else [],
            )

            advice_list = []
            for rule in rules:
                if rule.id == best_result["rule_id"] and rule.advice_ids:
                    for adv_id in rule.advice_ids:
                        adv = next((a for a in registry.advice.advice if a.id == adv_id), None)
                        if adv:
                            advice_list.append(AdviceItem(id=adv.id, text=adv.text_cn))

            domains[metric] = DomainResult(
                domain=metric,
                risk_level=RiskLevel(risk_value),
                summary=f"趋势评估完成，风险等级: {risk_value}",
                triggered_rules=[triggered],
                advice=advice_list,
            )

    return domains, quality_issues


def evaluate_point(
    measurements_dict: dict[str, float],
    registry: RulesetRegistry,
    version: str | None = None,
) -> EvaluationResult:
    ruleset = registry.get_ruleset(version)
    sha = registry.get_sha256(version)

    domains, quality_issues = run_single_point_evaluation(
        measurements_dict, ruleset, registry
    )

    return EvaluationResult(
        evaluation_id=str(uuid.uuid4()),
        ruleset_version=ruleset.version,
        ruleset_sha256=sha,
        input_digest=hashlib.sha256(
            json.dumps(measurements_dict, sort_keys=True).encode()
        ).hexdigest()[:16],
        evaluated_at=datetime.now(timezone.utc),
        domains=domains,
        data_quality=quality_issues,
        disclaimer=registry.advice.disclaimer.get("text_cn", "本结果不构成医学诊断"),
    )


def evaluate_trend(
    measurements_list: list[dict[str, Any]],
    registry: RulesetRegistry,
    version: str | None = None,
) -> EvaluationResult:
    ruleset = registry.get_ruleset(version)
    sha = registry.get_sha256(version)

    domains, quality_issues = run_trend_evaluation(
        measurements_list, ruleset, registry
    )

    input_digest = hashlib.sha256(
        json.dumps(measurements_list, sort_keys=True, default=str).encode()
    ).hexdigest()[:16]

    return EvaluationResult(
        evaluation_id=str(uuid.uuid4()),
        ruleset_version=ruleset.version,
        ruleset_sha256=sha,
        input_digest=input_digest,
        evaluated_at=datetime.now(timezone.utc),
        domains=domains,
        data_quality=quality_issues,
        disclaimer=registry.advice.disclaimer.get("text_cn", "本结果不构成医学诊断"),
    )


def evaluate_full(
    measurements: dict[str, float],
    registry: RulesetRegistry,
    user_profile: dict[str, Any] | None = None,
    history: list[dict[str, Any]] | None = None,
    version: str | None = None,
) -> EvaluationResult:
    ruleset = registry.get_ruleset(version)
    sha = registry.get_sha256(version)

    all_quality_issues: list[DataQualityIssue] = []

    sp_domains, sp_quality = run_single_point_evaluation(measurements, ruleset, registry)
    all_quality_issues.extend(sp_quality)

    trend_domains: dict[str, DomainResult] = {}
    if history:
        trend_domains, trend_quality = run_trend_evaluation(history, ruleset, registry)
        all_quality_issues.extend(trend_quality)

    merged_domains = {**sp_domains, **trend_domains}

    composite_domains = run_composite_evaluation(
        measurements, merged_domains, user_profile, ruleset, registry
    )
    merged_domains.update(composite_domains)

    input_payload = {"measurements": measurements, "profile": user_profile or {}}
    if history:
        input_payload["history_count"] = len(history)
    input_digest = hashlib.sha256(
        json.dumps(input_payload, sort_keys=True, default=str).encode()
    ).hexdigest()[:16]

    return EvaluationResult(
        evaluation_id=str(uuid.uuid4()),
        ruleset_version=ruleset.version,
        ruleset_sha256=sha,
        input_digest=input_digest,
        evaluated_at=datetime.now(timezone.utc),
        domains=merged_domains,
        data_quality=all_quality_issues,
        disclaimer=registry.advice.disclaimer.get("text_cn", "本结果不构成医学诊断"),
    )
