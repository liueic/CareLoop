from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any

import yaml

from app.kb.schema import (
    AdviceRegistry,
    MetricsRegistry,
    RiskLevelsRegistry,
    Ruleset,
    RulesetFile,
)


def _sort_keys_recursive(obj: Any) -> Any:
    if isinstance(obj, dict):
        return {k: _sort_keys_recursive(v) for k, v in sorted(obj.items())}
    if isinstance(obj, list):
        return [_sort_keys_recursive(item) for item in obj]
    return obj


def compute_sha256(data: dict[str, Any]) -> str:
    sorted_data = _sort_keys_recursive(data)
    canonical = json.dumps(sorted_data, ensure_ascii=False, sort_keys=True, default=str)
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def load_yaml(path: Path) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return yaml.safe_load(f)


def load_metrics(rules_dir: Path) -> MetricsRegistry:
    data = load_yaml(rules_dir / "_shared" / "metrics.yaml")
    return MetricsRegistry(**data)


def load_risk_levels(rules_dir: Path) -> RiskLevelsRegistry:
    data = load_yaml(rules_dir / "_shared" / "risk_levels.yaml")
    return RiskLevelsRegistry(**data)


def load_advice(rules_dir: Path) -> AdviceRegistry:
    data = load_yaml(rules_dir / "_shared" / "advice.yaml")
    return AdviceRegistry(**data)


def load_ruleset(rules_dir: Path, version: str) -> Ruleset:
    version_dir = rules_dir / version
    rulesets = []
    for yaml_file in version_dir.glob("*.yaml"):
        if yaml_file.name.startswith("_"):
            continue
        data = load_yaml(yaml_file)
        if data and "ruleset" in data:
            ruleset_file = RulesetFile(**data)
            rulesets.append(ruleset_file.ruleset)

    if not rulesets:
        raise ValueError(f"版本 {version} 中未找到任何规则集")

    all_rules = []
    for rs in rulesets:
        all_rules.extend(rs.rules)

    merged = Ruleset(
        id="merged",
        version=version,
        disease_category="all",
        status=rulesets[0].status,
        effective_date=rulesets[0].effective_date,
        sources=[s for rs in rulesets for s in rs.sources],
        rules=all_rules,
    )
    return merged


def load_manifest(rules_dir: Path) -> dict[str, Any]:
    return load_yaml(rules_dir / "manifest.yaml")


class RulesetRegistry:
    def __init__(self, rules_dir: Path):
        self.rules_dir = rules_dir
        self._rulesets: dict[str, Ruleset] = {}
        self._sha256: dict[str, str] = {}
        self._metrics = load_metrics(rules_dir)
        self._risk_levels = load_risk_levels(rules_dir)
        self._advice = load_advice(rules_dir)
        self._manifest = load_manifest(rules_dir)

    def get_ruleset(self, version: str | None = None) -> Ruleset:
        if version is None:
            version = self._manifest.get("active_version", "2024.1")
        if version not in self._rulesets:
            ruleset = load_ruleset(self.rules_dir, version)
            self._rulesets[version] = ruleset
            self._sha256[version] = compute_sha256(ruleset.model_dump())
        return self._rulesets[version]

    def get_sha256(self, version: str | None = None) -> str:
        if version is None:
            version = self._manifest.get("active_version", "2024.1")
        if version not in self._sha256:
            self.get_ruleset(version)
        return self._sha256[version]

    @property
    def metrics(self) -> MetricsRegistry:
        return self._metrics

    @property
    def risk_levels(self) -> RiskLevelsRegistry:
        return self._risk_levels

    @property
    def advice(self) -> AdviceRegistry:
        return self._advice

    @property
    def active_version(self) -> str:
        return self._manifest.get("active_version", "2024.1")

    def list_versions(self) -> list[dict[str, Any]]:
        versions = self._manifest.get("versions", {})
        return [
            {"version": v, **info}
            for v, info in versions.items()
        ]
