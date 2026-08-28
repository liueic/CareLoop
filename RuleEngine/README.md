# Health Rule Engine

确定性健康管理规则引擎，用于慢性病风险评估。

## 核心理念

- **金标准规则**：所有评估规则基于权威临床指南，非 LLM 生成
- **确定性输出**：同样输入永远得到同样输出
- **可追溯证据**：每条规则附带指南出处和章节引用
- **版本化管理**：规则集 Git 版本控制，支持审计回放

## 支持的疾病领域

| 领域 | 数据来源 | 主要指南 |
|---|---|---|
| 高血压 | 血压（SBP/DBP）| 《中国高血压防治指南（2023）》|
| 糖尿病 | 血糖、HbA1c | 《中国2型糖尿病防治指南（2020）》|
| 血脂异常 | TC、LDL-C、HDL-C、TG | 《中国血脂管理指南（2023）》|

## 快速开始

### 安装依赖

```bash
cd health-rule-engine
pip install -e ".[dev]"
```

### 验证规则集

```bash
python tools/validate_rules.py rules/
```

### 启动 API 服务

```bash
# 使用 Docker Compose
docker-compose up -d

# 或直接启动（需要 PostgreSQL 和 Redis）
uvicorn app.main:app --reload
```

### 测试评估

```bash
curl -X POST http://localhost:8000/api/v1/evaluate/point \
  -H "Content-Type: application/json" \
  -d '{
    "measurements": {
      "sbp": 145,
      "dbp": 92
    }
  }'
```

## 项目结构

```
health-rule-engine/
├── app/                    # FastAPI 应用
│   ├── engine/             # 规则引擎核心
│   │   ├── evaluators/     # 评估器（单点/趋势/综合）
│   │   ├── models.py       # 数据模型
│   │   └── pipeline.py     # 评估流水线
│   ├── kb/                 # 知识库
│   │   ├── schema.py       # Pydantic Schema
│   │   └── loader.py       # 规则加载器
│   └── main.py             # FastAPI 入口
├── rules/                  # 知识库（YAML 规则文件）
│   ├── 2024.1/             # 版本化规则集
│   │   ├── hypertension.yaml
│   │   ├── diabetes.yaml
│   │   └── dyslipidemia.yaml
│   ├── _shared/            # 共享词表
│   │   ├── metrics.yaml    # 指标定义
│   │   ├── risk_levels.yaml # 风险等级
│   │   └── advice.yaml     # 建议库
│   └── manifest.yaml       # 版本清单
├── tests/                  # 测试
│   └── golden/             # 黄金测试用例
└── tools/                  # 工具脚本
    └── validate_rules.py   # 规则校验
```

## 规则 Schema

每条规则必须包含：

```yaml
- id: HTN-SP-001
  name: {cn: 家庭血压高血压分级}
  type: single_point
  inputs:
    required: [sbp, dbp]
  conditions:
    any:
      - all: {sbp: {gte: 135}, dbp: {gte: 85}}
        output_risk: medium
  evidence:
    - source_id: CHTG-2023
      section: "第3章"
      quote: "家庭血压≥135/85 mmHg可确诊高血压"
  confidence: high
```

## API 端点

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/api/v1/evaluate/point` | 单点即时评估 |
| GET | `/api/v1/rules/versions` | 规则集版本列表 |
| GET | `/api/v1/rules/trace/{rule_id}` | 规则证据追溯 |
| GET | `/healthz` | 健康检查 |

## 开发阶段

- [x] Phase 0: 知识库基础（指标词表、Schema、校验工具）
- [x] Phase 1: MVP 引擎 + API（单点评估、高血压/糖尿病/血脂规则）
- [ ] Phase 2: 趋势评估（7/14/30天窗口、斜率分析）
- [ ] Phase 3: 综合评估（代谢综合征、ASCVD 风险分层）
- [ ] Phase 4: 运营加固（审计、性能、合规审查）

## 免责声明

本系统输出为健康管理提示，不构成医学诊断。如有不适请及时就医。

## 许可证

MIT
