from __future__ import annotations

from typing import Any

from app.engine.models import (
    AdviceItem,
    DomainResult,
    EvidenceRef,
    RiskLevel,
    TriggeredRule,
)
from app.kb.loader import RulesetRegistry
from app.kb.schema import Ruleset


RISK_ORDER = {
    "normal": 0,
    "low_elevated": 1,
    "medium": 2,
    "high": 3,
    "urgent": 4,
}


def _risk_value(r: RiskLevel | str) -> str:
    return r.value if hasattr(r, "value") else r


def _max_risk(a: str, b: str) -> str:
    return a if RISK_ORDER.get(a, 0) >= RISK_ORDER.get(b, 0) else b


def _get_domain_risk(domains: dict[str, DomainResult], key: str) -> str | None:
    if key in domains:
        return _risk_value(domains[key].risk_level)
    return None


def _get_measurement(measurements: dict[str, float], key: str) -> float | None:
    return measurements.get(key)


def _build_evidence(source_title: str, section: str, quote: str | None = None) -> list[EvidenceRef]:
    return [EvidenceRef(guideline=source_title, section=section, quote=quote)]


def _find_source(ruleset: Ruleset, source_id: str) -> str:
    for s in ruleset.sources:
        if s.source_id == source_id:
            return s.title
    return "Unknown"


def _get_advice(registry: RulesetRegistry, advice_ids: list[str]) -> list[AdviceItem]:
    result = []
    for adv_id in advice_ids:
        adv = next((a for a in registry.advice.advice if a.id == adv_id), None)
        if adv:
            result.append(AdviceItem(id=adv.id, text=adv.text_cn))
    return result


def evaluate_metabolic_syndrome(
    measurements: dict[str, float],
    user_profile: dict[str, Any] | None,
    ruleset: Ruleset,
    registry: RulesetRegistry,
) -> DomainResult | None:
    factors = []
    waist = _get_measurement(measurements, "waist")
    tg = _get_measurement(measurements, "tg")
    hdl_c = _get_measurement(measurements, "hdl_c")
    sbp = _get_measurement(measurements, "sbp")
    dbp = _get_measurement(measurements, "dbp")
    fpg = _get_measurement(measurements, "blood_glucose")

    sex = (user_profile or {}).get("sex", "male")

    if waist is not None:
        threshold = 90 if sex == "male" else 85
        if waist >= threshold:
            factors.append(f"waist>={threshold}cm")

    if tg is not None and tg >= 1.7:
        factors.append("TG>=1.7")

    if hdl_c is not None and hdl_c < 1.04:
        factors.append("HDL-C<1.04")

    if sbp is not None and dbp is not None:
        if sbp >= 130 or dbp >= 85:
            factors.append("BP>=130/85")
    elif sbp is not None and sbp >= 130:
        factors.append("SBP>=130")

    if fpg is not None and fpg >= 6.1:
        factors.append("FPG>=6.1")

    if len(factors) < 3:
        return None

    source_title = _find_source(ruleset, "CDS-2020")
    risk = "high" if len(factors) >= 4 else "medium"

    return DomainResult(
        domain="metabolic_syndrome",
        risk_level=RiskLevel(risk),
        summary=f"代谢综合征筛查：发现{len(factors)}/5项异常指标（{'、'.join(factors)}），≥3项即为代谢综合征",
        triggered_rules=[
            TriggeredRule(
                rule_id="CMP-MS-001",
                risk_level=RiskLevel(risk),
                evidence=_build_evidence(
                    source_title,
                    "代谢综合征诊断标准（CDS 2004）",
                    "具备以下3项或全部者：腰围超标、TG升高、HDL-C降低、血压升高、空腹血糖升高",
                ),
                confidence="high",
                data={"factor_count": len(factors), "factors": factors},
                tags=["metabolic_syndrome"],
            )
        ],
        advice=_get_advice(registry, ["AD-CMP-101"]),
    )


def evaluate_ascvd_risk_factors(
    measurements: dict[str, float],
    user_profile: dict[str, Any] | None,
    domains: dict[str, DomainResult],
    ruleset: Ruleset,
    registry: RulesetRegistry,
) -> DomainResult | None:
    profile = user_profile or {}
    factors = []

    age = profile.get("age")
    sex = profile.get("sex", "male")
    if age is not None:
        if (sex == "male" and age >= 45) or (sex == "female" and age >= 55):
            factors.append("age_risk")

    ldl_c = _get_measurement(measurements, "ldl_c")
    tc = _get_measurement(measurements, "tc")
    if ldl_c is not None and ldl_c >= 4.1:
        factors.append("LDL-C>=4.1")
    if tc is not None and tc >= 6.2:
        factors.append("TC>=6.2")

    hdl_c = _get_measurement(measurements, "hdl_c")
    if hdl_c is not None and hdl_c < 1.0:
        factors.append("HDL-C<1.0")

    sbp_risk = _get_domain_risk(domains, "sbp")
    if sbp_risk and RISK_ORDER.get(sbp_risk, 0) >= RISK_ORDER.get("medium", 0):
        factors.append("hypertension")

    glucose_risk = _get_domain_risk(domains, "blood_glucose")
    if glucose_risk and RISK_ORDER.get(glucose_risk, 0) >= RISK_ORDER.get("medium", 0):
        factors.append("diabetes_risk")

    smoking = profile.get("smoking")
    if smoking:
        factors.append("smoking")

    if not factors:
        return None

    count = len(factors)
    if count >= 4:
        risk = "high"
    elif count >= 2:
        risk = "medium"
    else:
        risk = "low_elevated"

    source_title = _find_source(ruleset, "CVD-PREV-2020")
    return DomainResult(
        domain="ascvd_risk",
        risk_level=RiskLevel(risk),
        summary=f"ASCVD风险因子计数：{count}项（{'、'.join(factors)}）",
        triggered_rules=[
            TriggeredRule(
                rule_id="CMP-ASCVD-001",
                risk_level=RiskLevel(risk),
                evidence=_build_evidence(
                    source_title,
                    "心血管病一级预防指南, China-PAR风险模型",
                    "多项危险因素聚集显著增加ASCVD 10年风险",
                ),
                confidence="medium",
                data={"factor_count": count, "factors": factors},
                tags=["ascvd_risk_factors"],
            )
        ],
        advice=_get_advice(registry, ["AD-CMP-101", "AD-CMP-102"]),
    )


def evaluate_cross_domain_escalation(
    domains: dict[str, DomainResult],
    measurements: dict[str, float],
    ruleset: Ruleset,
    registry: RulesetRegistry,
) -> list[DomainResult]:
    results = []

    bp_risk = _get_domain_risk(domains, "sbp")
    glucose_risk = _get_domain_risk(domains, "blood_glucose")

    if (bp_risk and RISK_ORDER.get(bp_risk, 0) >= RISK_ORDER.get("medium", 0)
            and glucose_risk and RISK_ORDER.get(glucose_risk, 0) >= RISK_ORDER.get("medium", 0)):
        escalated_risk = _max_risk(bp_risk, glucose_risk)
        escalated_risk = _max_risk(escalated_risk, "high")
        source_title = _find_source(ruleset, "CVD-PREV-2020")
        results.append(DomainResult(
            domain="htn_diabetes_escalation",
            risk_level=RiskLevel(escalated_risk),
            summary="高血压合并血糖异常，心血管风险显著升高，需综合管理",
            triggered_rules=[
                TriggeredRule(
                    rule_id="CMP-ESC-001",
                    risk_level=RiskLevel(escalated_risk),
                    evidence=_build_evidence(
                        source_title,
                        "高血压合并糖尿病管理",
                        "高血压合并糖尿病患者ASCVD风险显著升高，血压目标<130/80mmHg，LDL-C目标<1.8mmol/L",
                    ),
                    confidence="high",
                    data={"bp_risk": bp_risk, "glucose_risk": glucose_risk},
                    tags=["cross_domain_escalation", "htn_diabetes"],
                )
            ],
            advice=_get_advice(registry, ["AD-CMP-101", "AD-CMP-103"]),
        ))

    spo2_night = _get_measurement(measurements, "spo2_night_min")
    if spo2_night is not None and spo2_night < 90:
        if bp_risk and RISK_ORDER.get(bp_risk, 0) >= RISK_ORDER.get("low_elevated", 0):
            source_title = _find_source(ruleset, "CVD-PREV-2020")
            results.append(DomainResult(
                domain="osa_screening",
                risk_level=RiskLevel("medium"),
                summary="夜间血氧最低值<90%合并血压升高，提示阻塞性睡眠呼吸暂停（OSA）可能，建议专业评估",
                triggered_rules=[
                    TriggeredRule(
                        rule_id="CMP-OSA-001",
                        risk_level=RiskLevel("medium"),
                        evidence=_build_evidence(
                            source_title,
                            "OSA与心血管风险",
                            "OSA是高血压的独立危险因素，夜间SpO2<90%需筛查OSA",
                        ),
                        confidence="medium",
                        data={"spo2_night_min": spo2_night, "bp_risk": bp_risk},
                        tags=["osa_screening"],
                    )
                ],
                advice=_get_advice(registry, ["AD-SLP-102"]),
            ))

    ldl_c = _get_measurement(measurements, "ldl_c")
    if (ldl_c is not None and ldl_c >= 4.9
            and bp_risk and RISK_ORDER.get(bp_risk, 0) >= RISK_ORDER.get("medium", 0)):
        source_title = _find_source(ruleset, "CLG-2023")
        results.append(DomainResult(
            domain="extreme_ldl_hypertension",
            risk_level=RiskLevel("high"),
            summary="LDL-C≥4.9mmol/L合并高血压，属于极高心血管风险，需紧急就医评估",
            triggered_rules=[
                TriggeredRule(
                    rule_id="CMP-LDL-ESC-001",
                    risk_level=RiskLevel("high"),
                    evidence=_build_evidence(
                        source_title,
                        "血脂异常危险分层",
                        "LDL-C≥4.9mmol/L为高危标志，合并高血压时心血管风险极高",
                    ),
                    confidence="high",
                    data={"ldl_c": ldl_c, "bp_risk": bp_risk},
                    tags=["extreme_risk"],
                )
            ],
            advice=_get_advice(registry, ["AD-LIP-103", "AD-CMP-103"]),
        ))

    return results


def run_composite_evaluation(
    measurements: dict[str, float],
    domains: dict[str, DomainResult],
    user_profile: dict[str, Any] | None,
    ruleset: Ruleset,
    registry: RulesetRegistry,
) -> dict[str, DomainResult]:
    composite_domains: dict[str, DomainResult] = {}

    ms_result = evaluate_metabolic_syndrome(measurements, user_profile, ruleset, registry)
    if ms_result:
        composite_domains[ms_result.domain] = ms_result

    ascvd_result = evaluate_ascvd_risk_factors(
        measurements, user_profile, domains, ruleset, registry
    )
    if ascvd_result:
        composite_domains[ascvd_result.domain] = ascvd_result

    escalation_results = evaluate_cross_domain_escalation(
        domains, measurements, ruleset, registry
    )
    for result in escalation_results:
        composite_domains[result.domain] = result

    return composite_domains
