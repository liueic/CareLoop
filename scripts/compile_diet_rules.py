#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Compile ClinicalRules advice into CareLoop/Resources/DietRules/diet_rules.json."""

from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ADVICE = ROOT / "CareLoop" / "Resources" / "ClinicalRules" / "advice.json"
DIET_RULES = ROOT / "CareLoop" / "Resources" / "DietRules" / "diet_rules.json"

DIET_KEYWORDS = ("饮食", "钠", "盐", "碳水", "糖", "脂肪", "胆固醇", "进餐", "低盐", "低脂", "纤维", "升糖", "热量", "烹调", "钾")


def is_diet_related(title: str, body: str) -> bool:
    haystack = f"{title} {body}"
    return any(word in haystack for word in DIET_KEYWORDS)


def tags_for(category: str, title: str, body: str) -> list[str]:
    tags: set[str] = set()
    mapping = {
        "hypertension": ["高血压", "控盐"],
        "diabetes": ["糖尿病", "控糖"],
        "dyslipidemia": ["低脂"],
        "composite": ["心脏病", "控盐", "低脂"],
    }
    tags.update(mapping.get(category, []))
    if "盐" in body or "钠" in body:
        tags.add("控盐")
    if "糖" in body or "碳水" in body or "饮食控制" in title:
        tags.add("控糖")
    if not tags:
        tags.add("通用")
    return sorted(tags)


def main() -> None:
    bundled = json.loads(DIET_RULES.read_text(encoding="utf-8"))
    advice_root = json.loads(ADVICE.read_text(encoding="utf-8"))
    clauses = list(bundled.get("clauses", []))
    seen_ids = {c["id"] for c in clauses}
    seen_bodies = {c["body"] for c in clauses}

    added = 0
    for item in advice_root.get("advice", []):
        title = item.get("title_cn") or ""
        body = item.get("text_cn") or ""
        advice_id = item.get("id") or ""
        if not (title and body and advice_id) or not is_diet_related(title, body):
            continue
        clause_id = advice_id if advice_id.startswith("CL-") else f"CL-{advice_id}"
        if clause_id in seen_ids or body in seen_bodies:
            continue
        clauses.append(
            {
                "id": clause_id,
                "title": title,
                "body": body,
                "tags": tags_for(item.get("disease_category") or "", title, body),
                "source": f"ClinicalRules {advice_id}",
            }
        )
        seen_ids.add(clause_id)
        seen_bodies.add(body)
        added += 1

    bundled["clauses"] = clauses
    if not str(bundled.get("version", "")).endswith("+clinical"):
        bundled["version"] = f"{bundled.get('version', '1.0')}+clinical"
    DIET_RULES.write_text(json.dumps(bundled, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote {DIET_RULES} with {len(clauses)} clauses ({added} added)")


if __name__ == "__main__":
    main()
