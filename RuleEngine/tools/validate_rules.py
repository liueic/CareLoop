#!/usr/bin/env python3
"""Validate all rulesets in the rules directory."""
from __future__ import annotations

import sys
from pathlib import Path

from app.kb.loader import RulesetRegistry


def validate_rules(rules_dir: Path) -> bool:
    print(f"Validating rules in: {rules_dir}")
    errors = []

    try:
        registry = RulesetRegistry(rules_dir)
    except Exception as e:
        print(f"[FAIL] Failed to load registry: {e}")
        return False

    print(f"[OK] Shared registries loaded (metrics, risk_levels, advice)")

    versions = registry.list_versions()
    if not versions:
        print("[FAIL] No versions found in manifest")
        return False

    for v_info in versions:
        version = v_info["version"]
        print(f"\nValidating version: {version}")
        try:
            ruleset = registry.get_ruleset(version)
            sha = registry.get_sha256(version)
            print(f"  [OK] Loaded {len(ruleset.rules)} rules")
            print(f"  [OK] SHA-256: {sha[:16]}...")

            for rule in ruleset.rules:
                if not rule.evidence:
                    errors.append(f"Rule {rule.id} missing evidence")
                if not rule.confidence:
                    errors.append(f"Rule {rule.id} missing confidence")
                print(f"    - {rule.id}: {rule.name.get('cn', 'N/A')} [{rule.confidence.value}]")

        except Exception as e:
            errors.append(f"Version {version}: {e}")
            print(f"  [FAIL] Error: {e}")

    if errors:
        print(f"\n[FAIL] Validation failed with {len(errors)} errors:")
        for err in errors:
            print(f"  - {err}")
        return False

    print(f"\n[OK] All validations passed")
    return True


if __name__ == "__main__":
    rules_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("rules")
    success = validate_rules(rules_dir)
    sys.exit(0 if success else 1)
