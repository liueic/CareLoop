from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum
from typing import Any


class RiskLevel(str, Enum):
    NORMAL = "normal"
    LOW_ELEVATED = "low_elevated"
    MEDIUM = "medium"
    HIGH = "high"
    URGENT = "urgent"


@dataclass(frozen=True)
class Measurement:
    metric: str
    value: float
    unit: str
    ts: datetime
    device_id: str
    tags: dict[str, str] = field(default_factory=dict)


@dataclass(frozen=True)
class DataQualityIssue:
    metric: str
    value: float
    reason: str
    ts: datetime | None = None


@dataclass(frozen=True)
class EvidenceRef:
    guideline: str
    section: str
    quote: str | None = None


@dataclass(frozen=True)
class TriggeredRule:
    rule_id: str
    risk_level: RiskLevel
    evidence: list[EvidenceRef]
    confidence: str
    data: dict[str, Any] = field(default_factory=dict)
    tags: list[str] = field(default_factory=list)


@dataclass(frozen=True)
class AdviceItem:
    id: str
    text: str


@dataclass(frozen=True)
class DomainResult:
    domain: str
    risk_level: RiskLevel
    summary: str
    triggered_rules: list[TriggeredRule]
    advice: list[AdviceItem]


@dataclass(frozen=True)
class EvaluationResult:
    evaluation_id: str
    ruleset_version: str
    ruleset_sha256: str
    input_digest: str
    evaluated_at: datetime
    domains: dict[str, DomainResult]
    data_quality: list[DataQualityIssue]
    disclaimer: str

    def to_dict(self) -> dict[str, Any]:
        return {
            "evaluation_id": self.evaluation_id,
            "ruleset_version": self.ruleset_version,
            "ruleset_sha256": self.ruleset_sha256,
            "input_digest": self.input_digest,
            "evaluated_at": self.evaluated_at.isoformat(),
            "domains": {
                k: {
                    "domain": v.domain,
                    "risk_level": v.risk_level.value,
                    "summary": v.summary,
                    "triggered_rules": [
                        {
                            "rule_id": tr.rule_id,
                            "risk_level": tr.risk_level.value,
                            "evidence": [
                                {"guideline": e.guideline, "section": e.section, "quote": e.quote}
                                for e in tr.evidence
                            ],
                            "confidence": tr.confidence,
                            "data": tr.data,
                            "tags": tr.tags,
                        }
                        for tr in v.triggered_rules
                    ],
                    "advice": [{"id": a.id, "text": a.text} for a in v.advice],
                }
                for k, v in self.domains.items()
            },
            "data_quality": [
                {"metric": dq.metric, "value": dq.value, "reason": dq.reason,
                 "ts": dq.ts.isoformat() if dq.ts else None}
                for dq in self.data_quality
            ],
            "disclaimer": self.disclaimer,
        }
