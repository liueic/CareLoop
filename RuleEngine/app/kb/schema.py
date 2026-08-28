from __future__ import annotations

from datetime import date
from enum import Enum
from typing import Any

from pydantic import BaseModel, Field, field_validator


class RuleType(str, Enum):
    SINGLE_POINT = "single_point"
    TREND = "trend"
    COMPOSITE = "composite"


class RiskLevel(str, Enum):
    NORMAL = "normal"
    LOW_ELEVATED = "low_elevated"
    MEDIUM = "medium"
    HIGH = "high"
    URGENT = "urgent"


class Confidence(str, Enum):
    HIGH = "high"
    MEDIUM = "medium"
    LOW = "low"


class RulesetStatus(str, Enum):
    ACTIVE = "active"
    DEPRECATED = "deprecated"
    DRAFT = "draft"


class StandardProfile(str, Enum):
    CN_2023 = "CN-2023"
    ACC_AHA_2017 = "ACC-AHA-2017"
    ESC_ESH_2018 = "ESC-ESH-2018"


class Evidence(BaseModel):
    source_id: str
    section: str
    quote: str | None = None


class Source(BaseModel):
    source_id: str
    org_cn: str
    org_en: str | None = None
    title: str
    year: int
    publisher: str | None = None


class ThresholdCondition(BaseModel):
    gte: float | None = None
    gt: float | None = None
    lt: float | None = None
    lte: float | None = None
    eq: float | None = None

    @field_validator("gte", "gt", "lt", "lte", "eq")
    @classmethod
    def at_least_one_defined(cls, v: float | None, info: Any) -> float | None:
        return v


class ConditionBranch(BaseModel):
    all: dict[str, ThresholdCondition] | None = None
    output_risk: RiskLevel
    tag: str | None = None


class AnyConditions(BaseModel):
    any: list[ConditionBranch]
    default_risk: RiskLevel = RiskLevel.NORMAL


class TrendAggregate(BaseModel):
    metric: str
    fn: str
    gte: float | None = None
    gt: float | None = None
    lt: float | None = None
    lte: float | None = None


class TrendCondition(BaseModel):
    aggregate: TrendAggregate | None = None


class TrendConditions(BaseModel):
    all: list[TrendCondition] | None = None
    any: list[TrendCondition] | None = None


class TrendModifier(BaseModel):
    if_: TrendAggregate = Field(alias="if")
    raise_to: RiskLevel | None = None
    tag: str | None = None


class WindowSpec(BaseModel):
    days: int
    min_samples: int = 1
    min_samples_per_day: int = 1


class RuleInputs(BaseModel):
    required: list[str]
    context: list[str] | None = None
    unit_requirements: dict[str, str] | None = None
    window: WindowSpec | None = None


class Rule(BaseModel):
    id: str
    name: dict[str, str]
    type: RuleType
    priority: int = 100
    enabled: bool = True
    inputs: RuleInputs
    conditions: AnyConditions | TrendConditions | dict[str, Any] | None = None
    output_risk: RiskLevel | None = None
    modifiers: list[TrendModifier] | None = None
    note: str | None = None
    evidence: list[Evidence]
    confidence: Confidence
    advice_ids: list[str] | None = None

    @field_validator("evidence")
    @classmethod
    def evidence_required(cls, v: list[Evidence]) -> list[Evidence]:
        if not v:
            raise ValueError("每条规则必须至少有一条证据引用")
        return v


class Ruleset(BaseModel):
    id: str
    version: str
    disease_category: str
    standard_profile: StandardProfile | None = None
    status: RulesetStatus = RulesetStatus.ACTIVE
    effective_date: date
    author: str | None = None
    reviewer: str | None = None
    sources: list[Source]
    rules: list[Rule]

    @field_validator("rules")
    @classmethod
    def rules_not_empty(cls, v: list[Rule]) -> list[Rule]:
        if not v:
            raise ValueError("规则集不能为空")
        return sorted(v, key=lambda r: (-r.priority, r.id))


class RulesetFile(BaseModel):
    ruleset: Ruleset


class MetricDefinition(BaseModel):
    name_cn: str
    name_en: str
    unit_canonical: str
    plausible_range: list[float]
    source_types: list[str]
    tags: list[str] = []
    context_tags: list[str] | None = None
    conversions: list[dict[str, Any]] | None = None


class MetricsRegistry(BaseModel):
    metrics: dict[str, MetricDefinition]


class RiskLevelDefinition(BaseModel):
    name_cn: str
    name_en: str
    color: str
    description_cn: str
    description_en: str
    action: str


class RiskLevelsRegistry(BaseModel):
    risk_levels: dict[str, RiskLevelDefinition]


class AdviceItem(BaseModel):
    id: str
    disease_category: str
    risk_levels: list[RiskLevel]
    title_cn: str
    title_en: str
    text_cn: str
    text_en: str
    priority: int = 10


class AdviceRegistry(BaseModel):
    disclaimer: dict[str, str]
    advice: list[AdviceItem]
