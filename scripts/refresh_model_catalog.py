#!/usr/bin/env python3
"""从 models.dev 的 api.json 生成 CareLoop 内置模型目录快照。

用法:
    python3 scripts/refresh_model_catalog.py /path/to/api.json
    # 输出写入 CareLoop/Resources/Content/model_catalog.json

输入文件来自 https://models.dev/api.json（浏览器下载后传入路径）。
只保留 App 内置 Provider（映射规则与 CatalogSyncService.mappedProvider 一致），
并把 models.dev 的 tool_call / reasoning / knowledge 字段映射进快照。

打包体积考量：全量 api.json 约 2.5MB / 207 个 provider；
过滤到 6 个内置 Provider 后约 500 个模型、100KB 量级，适合随包分发。
"""

import json
import sys
from pathlib import Path

# models.dev provider id → App 的 providerKey（与 CatalogSyncService.mappedProvider 保持一致）
PROVIDER_MAP = {
    "deepseek": "deepseek",
    "alibaba": "qwen",
    "dashscope": "qwen",
    "qwen": "qwen",
    "volcengine": "doubao",
    "byteplus": "doubao",
    "doubao": "doubao",
    "zhipuai": "zhipu",
    "zai": "zhipu",
    "zhipu": "zhipu",
    "openrouter": "openrouter",
    "openai": "openai",
}

REPO_ROOT = Path(__file__).resolve().parent.parent
OUTPUT = REPO_ROOT / "CareLoop" / "Resources" / "Content" / "model_catalog.json"


def metadata_richness(entry: dict) -> int:
    """去重时优先保留元数据更全的条目。"""
    score = 0
    if entry.get("name"):
        score += 1
    if entry.get("limit", {}).get("context"):
        score += 2
    if entry.get("cost", {}).get("input") is not None:
        score += 2
    if "tool_call" in entry:
        score += 1
    if "reasoning" in entry:
        score += 1
    return score


def map_model(model_id: str, model: dict, provider_key: str) -> dict:
    modalities = model.get("modalities") or {}
    inputs = modalities.get("input") or []
    limit = model.get("limit") or {}
    cost = model.get("cost") or {}
    return {
        "modelID": model_id,
        "providerKey": provider_key,
        "displayName": model.get("name") or model_id,
        "contextWindow": int(limit.get("context") or 0),
        "maxOutputTokens": int(limit.get("output") or 0),
        "supportsVision": "image" in inputs or model.get("attachment") is True,
        # models.dev 未标注 tool_call 时按 OpenAI 兼容端点主流能力默认 true
        "supportsToolCall": model.get("tool_call", True),
        "supportsReasoning": model.get("reasoning", False),
        "inputPrice": float(cost.get("input") or 0),
        "outputPrice": float(cost.get("output") or 0),
        "knowledgeCutoff": model.get("knowledge") or "",
        "source": "bundled",
    }


def main() -> None:
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(1)
    source = Path(sys.argv[1])
    data = json.loads(source.read_text(encoding="utf-8"))

    # (providerKey, modelID) 去重：alibaba/dashscope/qwen 会映射到同一个 key
    best: dict[tuple[str, str], tuple[int, dict]] = {}
    for provider_id, provider in data.items():
        app_key = PROVIDER_MAP.get(str(provider_id).lower())
        if not app_key:
            continue
        for model_id, model in (provider.get("models") or {}).items():
            key = (app_key, model_id)
            entry = map_model(model_id, model, app_key)
            rank = metadata_richness(model)
            if key not in best or rank > best[key][0]:
                best[key] = (rank, entry)

    entries = sorted(
        (entry for _, entry in best.values()),
        key=lambda e: (e["providerKey"], e["modelID"]),
    )
    OUTPUT.write_text(
        json.dumps(entries, ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )
    by_provider: dict[str, int] = {}
    for entry in entries:
        by_provider[entry["providerKey"]] = by_provider.get(entry["providerKey"], 0) + 1
    size_kb = OUTPUT.stat().st_size / 1024
    print(f"已生成 {OUTPUT}")
    print(f"共 {len(entries)} 个模型，{size_kb:.0f} KB：{by_provider}")


if __name__ == "__main__":
    main()
