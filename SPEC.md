# 慢病健康管理 iOS App — 技术方案 Spec

> 版本：v0.1（黑客松 MVP 阶段）
> 定位：**慢病日常管理、风险提示与医患信息整理工具**。不做疾病诊断，不替代医生决策。
> 平台：原生 iOS（Swift / SwiftUI）

---

## 1. 产品范围（本 Spec 覆盖的边界）

### 1.1 MVP 聚焦病种
1. 高血压
2. 糖尿病 / 代谢综合征
3. 心房颤动等心血管慢病（依赖可穿戴心率/心电图类数据，第一版只做提示级别）

### 1.2 核心产品理念：记录即主页

产品的第一屏不是数据 Dashboard，而是**一台"健康水印相机"**：

- 打开 App 即可拍照，类似水印相机，照片自动叠加拍摄时刻的健康上下文水印（时间、当天静息心率、昨晚睡眠、今日步数等）
- 拍完可用**语音或文字**随手补充（"今天吃了什么""哪里不舒服"），语音自动转文字
- 身体状况（头晕、心悸、乏力等）可以一键打卡，不需要拍照也能记
- 所有记录汇成一条**手帐式时间线**，每天一页，可翻阅、可回顾

设计目标：**让病人以最低成本养成长期健康记录习惯**。用药、复诊、建议等模块作为支撑能力存在，不抢占主页。

### 1.3 四个核心模块
| 模块 | MVP 形态 |
|---|---|
| Daily Track（主轴） | 水印相机 + 语音/文字手帐 + 症状打卡 + 可穿戴自动同步 |
| 用药与复诊信息管理 | 用药 Panel、手动复诊提醒、复诊前健康摘要 |
| 复诊与体检提醒 | 模式 A（医生医嘱，手动/识别日期后确认）；模式 B（智能建议）P1 |
| 个性化饮食与运动建议 | **LLM 生成 + 规则护栏**：内容库提供候选，规则做硬约束过滤与后置校验，LLM 做个性化组合与表达 |

### 1.4 明确不做（MVP）
- 任何形式的疾病诊断结论
- 自动调药、停药、换药建议
- 药物相互作用自动判定（不依赖生成式 AI，P2 才考虑规则库）
- 医生端、医疗机构对接、经临床验证的预测模型

---

## 2. 技术栈选型

### 2.1 核心栈

| 领域 | 选型 | 理由 |
|---|---|---|
| 语言 | Swift 6 | 原生要求；并发模型（async/await、actor）适合数据管线 |
| UI | SwiftUI + Swift Charts | 手帐流、相机页、趋势图；声明式便于 Demo 迭代 |
| 持久化 | SwiftData | iOS 17+ 官方方案，模型即代码，迁移成本低 |
| 健康数据 | HealthKit (`HKHealthStore`) | 唯一合规读取 Apple Health 的通道 |
| 本地提醒 | UserNotifications | 用药 / 复诊 / 记录习惯提醒，无需服务端 |
| 语音记录 | Speech framework + AVFoundation | 端上语音转文字（支持中文），零后端成本 |
| 拍照/相册 | PhotosUI + AVFoundation | 标准选图/拍摄 |
| 水印合成 | CoreGraphics / CoreImage | 拍摄后离线合成健康水印，纯端上处理 |
| 照片存储 | App Sandbox（Documents/photos） | SwiftData 只存引用，二进制不进数据库 |
| LLM 接入 | URLSession + Codable（OpenAI 兼容协议） | 不引第三方 SDK；供应商可配置（DeepSeek / 通义 / 豆包等任一 OpenAI 兼容端点） |
| OCR（处方/病历） | Vision (`VNRecognizeTextRequest`) | 端上文字识别，支持简体中文，数据不出设备 |
| 图表 | Swift Charts | 静息心率/睡眠/步数趋势 |
| 并发 | Swift Concurrency（async/await + actor） | HealthKit 查询、基线计算线程安全 |

### 2.2 部署目标与依赖
- **iOS 17.0+**（SwiftData 底线；若用 iOS 18 专有 API 需做可用性判断）
- **零第三方依赖**（MVP 阶段不引入 CocoaPods/SPM 包，降低集成风险）
- 工程文件：手写 `project.pbxproj`（Xcode 16+ filesystem-synchronized groups）或 XcodeGen 生成

### 2.3 AI 能力的边界与选型

| 能力 | MVP 方案 | 说明 |
|---|---|---|
| 饮食照片识别（如"高糖奶茶"） | **云端多模态 LLM 识别 + 用户确认**；无 Key/无网时降级为手动标签 | 所有识别结果一律走"识别 → 解释 → 用户确认"流程 |
| 处方/病历信息提取 | Vision OCR 提取文本 → LLM 结构化 → **用户确认后写入** | 符合"识别结果必须由用户确认"的安全要求；OCR 端上完成，仅文本送 LLM |
| 个性化建议生成 | **LLM 生成 + 规则护栏**（见 7.3） | LLM 只做候选内的个性化组合与表达；病种禁忌、强度上限等硬约束由规则引擎前置过滤、后置校验 |
| Alert 生成 | **规则 + 个人基线统计模型**，不用 LLM 断言 | 每条 Alert 必须可解释、可回溯依据 |

> LLM 接入约定：支持多 Provider 切换与模型目录管理（见第 8 节）；API Key 存 **iOS Keychain**（不进 git、不入数据库）；请求只发送脱敏画像标签（病种、口味、趋势摘要），**绝不发送姓名、精确出生日期等可识别信息**；照片仅在用户主动发起食物识别时发送至当前激活的多模态模型；P1 起改经自建后端代理转发，Key 不落客户端。

---

## 3. 系统架构

### 3.1 分层结构（MVVM + 服务层）

```
┌─────────────────────────────────────────────────────┐
│ Presentation (SwiftUI Views + ViewModels)            │
│   Journal / Camera / Today / Medication /            │
│   Onboarding / Settings                              │
├─────────────────────────────────────────────────────┤
│ Domain Services (纯 Swift，可单测)                     │
│   BaselineEngine   — 个人基线计算                     │
│   AlertEngine      — 异常分级与五段式解释              │
│   AdviceEngine     — 候选过滤 + LLM 推荐编排 + 后置校验 │
│   MedicationEngine — 服药计划与依从性统计              │
├─────────────────────────────────────────────────────┤
│ Data Providers (protocol 抽象，可替换)                 │
│   HealthDataProviding                                │
│     ├─ HealthKitProvider  (真机)                     │
│     └─ MockHealthProvider (模拟器 / Demo)            │
│   LLMProviding                                       │
│     ├─ OpenAICompatibleProvider (云端大模型)          │
│     └─ MockLLMProvider (单测 / 无 Key 降级)          │
│   SpeechRecognizer / VisionExtractor                 │
├─────────────────────────────────────────────────────┤
│ Persistence (SwiftData)                              │
│   UserProfile / DailyLog / Medication / Intake /     │
│   FollowUp / AlertRecord / BaselineSnapshot          │
├─────────────────────────────────────────────────────┤
│ System                                               │
│   HealthKit · UserNotifications · Speech · Vision    │
└─────────────────────────────────────────────────────┘
```

关键原则：
- **Domain Services 不依赖 UI、不依赖 HealthKit 类型**，输入输出为自有值类型，保证离线可单测。
- **HealthDataProviding 协议**隔离 HealthKit：模拟器和 Demo 用 MockProvider，真机用 HealthKitProvider，由环境开关注入。
- **LLMProviding 协议**隔离大模型：AdviceEngine 只面向协议，无 Key / 无网络时自动降级为 MockLLMProvider（本地模板），功能永远可用。
- 所有 Alert / 建议的产生路径：`数据 → BaselineEngine → AlertEngine/AdviceEngine → 用户可见卡片`，每一跳都可解释。

### 3.2 目录结构

```
CareLoop/                          # 工程根（App 显示名：慢病健康助手）
├── CareLoop.xcodeproj
├── CareLoop/
│   ├── App/
│   │   ├── CareLoopApp.swift
│   │   ├── AppEnvironment.swift        # 依赖注入（providers, modelContainer, demo开关）
│   │   └── RootTabView.swift
│   ├── Models/                         # SwiftData @Model + 值类型
│   │   ├── UserProfile.swift
│   │   ├── HealthMetric.swift          # 归一化的指标值类型
│   │   ├── DailyLogEntry.swift
│   │   ├── Medication.swift
│   │   ├── MedicationIntake.swift
│   │   ├── FollowUp.swift
│   │   ├── AlertRecord.swift
│   │   └── BaselineSnapshot.swift
│   ├── Services/
│   │   ├── HealthKit/
│   │   │   ├── HealthDataProviding.swift
│   │   │   ├── HealthKitProvider.swift
│   │   │   └── MockHealthProvider.swift
│   │   ├── LLM/
│   │   │   ├── LLMProviding.swift          # 协议 + 请求/响应值类型
│   │   │   ├── OpenAICompatibleProvider.swift
│   │   │   ├── MockLLMProvider.swift
│   │   │   ├── ProviderManager.swift       # Switcher：Provider 增删改、激活对切换
│   │   │   ├── ModelCatalog.swift          # 内置模型目录（打包快照）
│   │   │   ├── CatalogSyncService.swift    # 上游同步（models.dev / OpenRouter 格式）
│   │   │   ├── ModelDiscovery.swift        # GET /v1/models 模型发现 + 元数据 join
│   │   │   ├── HealthCheckService.swift    # 两级测活（连通性 / 模型级 ping）
│   │   │   └── KeychainStore.swift         # API Key 存取（kSecClassGenericPassword）
│   │   ├── BaselineEngine.swift
│   │   ├── AlertEngine.swift
│   │   ├── AdviceEngine.swift
│   │   ├── MedicationEngine.swift
│   │   ├── OCRService.swift
│   │   ├── SpeechService.swift
│   │   └── NotificationService.swift
│   ├── Views/
│   │   ├── Journal/                    # 手帐主页：相机入口、时间线、每日一页
│   │   ├── Camera/                     # 水印相机与拍摄后补充流程
│   │   ├── Today/                      # 今日页：状态/异常/用药摘要/复诊/建议
│   │   ├── Medication/
│   │   ├── Onboarding/
│   │   └── Settings/
│   ├── Resources/
│   │   ├── Assets.xcassets
│   │   ├── Rules/                      # 指南规则 JSON（告警阈值、禁忌约束、降级模板）
│   │   └── Content/                    # 内容库 JSON（食谱、运动项目，见 7.4）
│   ├── CareLoop.entitlements           # com.apple.developer.healthkit
│   └── Info.plist                      # NSHealthShareUsageDescription 等
└── CareLoopTests/
    ├── BaselineEngineTests.swift
    ├── AlertEngineTests.swift
    ├── AdviceEngineTests.swift         # 含 MockLLM 的管线测试
    └── MedicationEngineTests.swift
```

---

## 4. HealthKit 集成设计

### 4.1 读取的指标（与病种对应）

| HealthKit 类型 | 标识符 | 用途 |
|---|---|---|
| 步数 | `HKQuantityTypeIdentifierStepCount` | 活动量基线 |
| 静息心率 | `...RestingHeartRate` | 高血压/心血管异常信号 |
| 心率 | `...HeartRate` | 即时与运动强度参考 |
| HRV (SDNN) | `...HeartRateVariabilitySDNN` | 疲劳/压力/自主神经状态 |
| 活动能量 | `...ActiveEnergyBurned` | 运动量 |
| 睡眠 | `HKCategoryTypeIdentifierSleepAnalysis` | 睡眠时长/质量趋势 |
| 体重 | `...BodyMass` | 代谢管理 |
| 血压（收缩/舒张） | `...BloodPressureSystolic/Diastolic` | 高血压核心指标 |
| 血糖 | `...BloodGlucose` | 糖尿病核心指标 |
| 血氧 | `...OxygenSaturation` | 辅助参考 |
| 体能训练 | `HKWorkout` | 运动类型与强度 |

> 注意：Apple Watch **不直接测血压和血糖**。这两项依赖第三方设备/App 写入 Apple Health。Demo 中血压、血糖数据由 Mock 提供，App 如实标注数据来源。

### 4.2 授权与查询
- `CareLoop.entitlements` 开启 `com.apple.developer.healthkit`（含 `healthkit.access` 按需）。
- `Info.plist`：`NSHealthShareUsageDescription`（读取）；MVP 不回写，可不加 Update 描述。
- 授权时机：Onboarding 完成用户资料后一次性请求，逐项失败降级（拿不到血压 ≠ 阻塞流程）。
- 查询方式：`HKStatisticsQuery`（日均/总和）+ `HKSampleQuery`（明细），首次拉取近 30 天建立基线，之后增量同步（`HKAnchoredObjectQuery`，P1）。
- 数据来源标记：每条 `HealthMetric` 记录 `sourceName`（Apple Watch / 第三方 / Mock），UI 如实展示。

### 4.3 演示模式（Demo Mode）
- Settings 中一键切换；MockHealthProvider 生成 30 天带"剧本"的数据（如：近 3 天睡眠下降 + 静息心率上升），保证首页异常、Alert、建议全部可演示。
- 模拟器同样默认走 Mock，真机可切真实数据。

---

## 5. 数据模型（SwiftData）

```
UserProfile            #  Onboarding 收集（见第 6 节）
  - 基础(Apple Health 风格): birthDate, biologicalSex, bloodType, height, weight, wheelchairUse
  - 健康: conditions[高血压/糖尿病/房颤...], drugAllergies[], foodAllergies[],
         injuries[], doctorRestrictions[], currentMedicationNames[]
  - 饮食: region(省/市), cuisineLikes[], cuisineDislikes[],
         spiciness(不辣/微辣/正常/重辣), dislikedIngredients[], cookFrequency, dietGoal
  - 运动: preferredSports[], avoidedSports[], frequency, timePreference,
         facilities(场地/器械), intensityCeiling   # 由病种+医嘱推导的强度上限

HealthMetric (值类型, 非 @Model)   # 归一化指标
  - type, value, unit, date, source

DailyLogEntry (@Model)
  - kind: photo / voice / text / quickTag / symptom
  - photoRef, watermarkSnapshot      # 拍摄时刻的水印数据快照（见 5.1）
  - voiceMemoRef, transcript          # 语音原文件 + 转写文字
  - contentText, tags[饮食/运动/睡眠/情绪/饮酒/咖啡因/症状]
  - symptoms[]                        # 结构化症状：部位、程度(轻/中/重)、持续时间
  - structuredFields: mealType, exerciseType/intensity...
  - confirmationState: pendingAI / confirmed / edited   # AI 识别必须确认

Medication (@Model)
  - name, dosePerTime, frequency, timesOfDay[], period, cautions
  - source(手动/处方识别), prescribedDate, confirmedByUser: Bool

MedicationIntake (@Model)   # 每次服药打卡 → 依从性统计
  - medicationRef, scheduledTime, takenAt?, status: taken/missed/skipped

FollowUp (@Model)
  - mode: doctorOrdered / smartSuggested
  - date, department, preparations[空腹/携带材料], notes
  - confirmedByUser: Bool

AlertRecord (@Model)
  - tier, title, whatChanged, whyItMatters, suggestedAction, evidence
  - relatedMetricTypes[], createdAt, acknowledged

BaselineSnapshot (@Model)
  - metricType, windowDays, mean, stdDev, computedAt

LLMProviderConfig (@Model)            # Provider 管理（见第 8 节）
  - name, baseURL, providerType(openaiCompatible), isPreset, enabled
  - apiKeyRef                          # Keychain key，密钥本体不落库
  - lastHealthAt, healthStatus(unknown/ok/degraded/down)

ModelCatalogEntry (@Model)            # 模型目录（内置 + 上游同步）
  - modelID, providerKey, displayName
  - contextWindow, maxOutputTokens
  - supportsVision, supportsToolCall, supportsReasoning
  - inputPrice, outputPrice            # USD / 1M tokens，来自上游
  - knowledgeCutoff
  - source(bundled/synced/manual), lastSyncedAt

ActiveModelSelection (AppStorage)      # 当前激活的 (providerKey, modelID)
```

### 5.1 水印快照（WatermarkSnapshot）

拍照瞬间从 HealthKit / Mock 拉取当日上下文，作为值类型随照片一起保存（此后不再变化，保证手帐"当时状态"可回溯）：

- 日期、时间、星期
- 昨晚睡眠时长、当日静息心率、当前心率（若可获取）、今日步数
- 最近一次血压 / 血糖（若用户有对应设备数据）
- 天气与地点（可选，默认关闭，需用户授权定位）

水印样式：照片底部半透明条 + 左上角日期戳，简洁不遮挡主体。用户可在设置中选择显示哪些字段（隐私考虑，血压/血糖默认不显示）。

### 5.2 习惯养成机制

- **连续记录天数（Streak）**：每天至少有 1 条记录即点亮当天，首页展示连续天数
- **每日一页手帐**：当天所有照片、语音、症状打卡聚合成一页，可回顾、可导出
- **轻提醒**：用户自选一个固定时间（如晚饭后），当天无记录时发一条本地通知，文案温和不制造焦虑
- **症状一键打卡**：不拍照也能记——首页常驻"今天身体怎么样"入口，三步完成（选症状 → 选程度 → 可选语音补充）
- 不设计任何惩罚性机制（不断签提醒、不红点轰炸），慢病人群以鼓励为主

---

## 6. 初始化流程（Onboarding）

参考 Apple Health 的初始化体验：**分步卡片、每步可跳过、授权后自动预填**。目标是在 3 分钟内建立足够做个性化推荐的画像，且所有信息后续可在"我的"中修改。

### 6.1 分步流程

```
① 欢迎 + 免责声明（不诊断、不替代医生）
② 基础信息：出生日期、生理性别、血型、身高、体重
   —— HealthKit 授权后自动预填（出生日期/性别/血型/身高/体重可直接读取），用户确认即可
③ 健康状况：确诊慢病（多选）→ 药物过敏、食物过敏、当前用药、运动损伤、医生限制事项
④ 饮食偏好：所在省市 → 推荐菜系默认项；喜欢的菜系、不接受的菜系、辣度（如广东人默认"不辣"）、
   忌口食材、做饭/外卖频率、饮食目标（控盐/控糖/减重...）
⑤ 运动偏好：喜欢的运动、不喜欢/无法完成的运动、当前频率、常运动时段、可用场地器械
⑥ 系统授权：HealthKit（必选，逐项降级）、通知、相机、麦克风/语音识别
```

### 6.2 关键设计

- **条件联动**：第③步选了病种后，④⑤步即时反映约束——例如选了心脏病/房颤，运动偏好列表中高强度项目（HIIT、短跑、球类对抗）自动标注"不推荐"，`intensityCeiling` 写入画像；选了高血压，饮食目标默认带出"控盐"。
- **跳过不阻塞**：任何一步可跳过，画像用安全默认值（最低强度、无偏好），后续逐步完善。
- **预填不替答**：HealthKit 读到的数据只作为默认值展示，用户确认后才入库。
- 画像完成度在"我的"中展示，引导补全（非强制）。

---

## 7. 核心引擎设计

### 7.1 BaselineEngine（个人基线）
- 输入：某指标近 14 天日级序列。
- 输出：`BaselineSnapshot(mean, stdDev)` + 当日偏离度 `z = (today - mean) / stdDev`。
- 规则：`|z| ≥ 1.5` 标记"偏离"，`≥ 2.0` 或连续 3 天 `≥ 1.5` 标记"持续异常"。
- 人群阈值（指南参考值，如静息心率、血压分级）与个人基线**双轨**：两者任一触发都进入 AlertEngine，解释中说明是哪一轨触发。

### 7.2 AlertEngine（五级分级 + 五段式解释）

| 级别 | 触发示例 |
|---|---|
| L1 一般健康建议 | 单次行为提示（高糖饮品 + 糖代谢病史） |
| L2 值得观察 | 单指标偏离个人基线（z ≥ 1.5） |
| L3 持续异常 | 连续多天偏离，或多指标同时偏离（睡眠↓ + 静息心率↑ + 运动量异常） |
| L4 建议咨询医生 | 持续异常 + 症状记录，或指标超指南安全线 |
| L5 红旗症状 | 用户记录胸痛/严重头晕等关键词 → 立即提示就医/急救渠道 |

每条 AlertRecord 强制包含五段：
1. **发现了什么**（what）
2. **与个人基线相比的变化**（delta + z 值）
3. **为什么需要关注**（与病种/指南的关联）
4. **建议采取的行动**（复测/观察/咨询医生，绝不含诊断与调药）
5. **证据与依据**（数据区间、来源、规则编号）

### 7.3 AdviceEngine（LLM 生成 + 规则护栏）

LLM 负责"个性化"，规则负责"安全"。推荐严格走五段管线，LLM 永远无法越过硬约束：

```
① 硬约束过滤（规则，确定性）
   病种禁忌（心脏病→剔除高强度运动；糖尿病→剔除高糖食谱）、
   医生限制、过敏食材、忌口、辣度、运动损伤、intensityCeiling
        ↓ 得到"安全候选集"（食谱库/运动库子集）
② 软偏好排序候选（规则打分）
   菜系偏好、口味、场地器械、近期趋势（状态差→低强度加权）
        ↓ Top N 候选 + 脱敏画像标签
③ LLM 个性化生成（LLMProviding）
   输入：候选集 + 画像标签 + 当天状态 + 近 7 天趋势摘要
   输出：一条主建议（含具体食谱/运动安排、时长强度、替换选项、理由）
   —— Prompt 中注入红线：不推荐候选集外内容、不谈药物、不做诊断
        ↓
④ 后置校验（规则，确定性）
   输出引用必须 ⊆ 候选集；关键词黑名单（停药/加量/治愈/诊断类措辞）；
   强度/禁忌二次核对
        ↓ 不通过 → 降级
⑤ 产出"今天一条最重要的建议"（标注"AI 建议，仅供参考"）
```

- **降级路径**：无 API Key / 无网络 / LLM 输出校验失败 → MockLLMProvider 用本地模板从候选集直接组句，功能永远可用，UI 不报错。
- 食谱与运动建议各跑一次管线；用户状态不佳（睡眠差/静息心率偏高/症状记录）时，运动管线输入自动降级为低强度候选（拉伸、散步、恢复性活动）。

### 7.4 食谱与运动内容库

内容库存放在 `Resources/Content/*.json`，随 App 打包，版本化维护，为推荐管线提供候选：

```json
// recipes.json —— 每条食谱
{
  "id": "recipe-001",
  "name": "清蒸鲈鱼",
  "cuisine": "粤菜",
  "spiciness": "none",               // none / mild / medium / hot
  "tags": ["低盐", "高蛋白", "蒸"],
  "ingredients": ["鲈鱼", "姜", "葱"],
  "avoidFor": [],                    // 禁忌病种标签，如 ["痛风"]
  "suitableFor": ["高血压", "糖尿病"],
  "mealType": ["午餐", "晚餐"],
  "cookingNote": "蒸鱼豉油减半或用低钠酱油"
}

// exercises.json —— 每个运动项目
{
  "id": "exercise-001",
  "name": "快走",
  "intensityMET": 3.5,               // 代谢当量，强度分级的客观依据
  "intensityLevel": "低",             // 低(<3) / 中(3-6) / 高(>6)
  "avoidFor": [],                    // 如 ["房颤"] 出现在高强度项目上
  "requiresEquipment": [],
  "venue": ["户外", "健身房"],
  "defaultDurationMin": 30,
  "notes": "心率控制在 (170 - 年龄) 以下"
}
```

- `avoidFor` / `suitableFor` / `intensityCeiling` 是**硬约束字段**，内容上线前需按指南审定（见第 13 节待确认项）。
- MVP 规模：食谱 ≥ 40 条（覆盖粤/川/湘/江浙/北方等菜系、各辣度）、运动 ≥ 20 项，够演示个性化差异即可。
- LLM 只能从这些条目中组合推荐，不凭空生成食谱——这是食品安全与运动安全的关键约束。

### 7.5 MedicationEngine
- 由 Medication 生成当日服药时刻表；打卡写 MedicationIntake。
- 依从性 = 近 N 天 taken / 应服次数，供今日页和复诊摘要使用。
- 漏服处理只提示"按医嘱处理或咨询医生/药师"，不做任何剂量建议。

---

## 8. LLM 服务管理（Provider Switcher）

对标 Cherry Studio / LobeChat 的主流做法：**统一 Switcher + 用户自配 Key + 内置模型目录 + 上游同步 + 测活**。所有 OpenAI 兼容端点走同一套 `LLMProviding` 协议。

### 8.1 Provider 管理（Switcher）

- **预设 Provider**（`isPreset = true`，内置 baseURL，用户只需填 Key）：DeepSeek、通义千问（DashScope 兼容模式）、豆包（火山方舟）、智谱 GLM、OpenRouter、OpenAI。
- **自定义 Provider**：名称 + Base URL + API Key，可连私有部署（vLLM / Ollama 等，Key 可留空）。
- **全局激活对**：当前使用的 `(provider, model)` 存 `ActiveModelSelection`，推荐管线与食物识别统一走激活对；切换即时生效。
- API Key 存 Keychain（`kSecClassGenericPassword`），SwiftData 只存引用；卸载即清除。

### 8.2 模型目录（内置表 + 上游同步）

三个数据源按优先级合并成 `ModelCatalogEntry`：

```
① 内置快照（随 App 打包）        —— 离线可用的保底目录
② 上游同步（后台/手动触发）      —— models.dev api.json（开源模型数据库，
                                     含 context/vision/价格/能力字段，OpenRouter
                                     /api/v1/models 同格式可选）
③ 用户 Provider 模型发现         —— GET {baseURL}/v1/models 返回可用模型 id，
                                     与目录元数据 join；匹配不到的标"元数据未知"，
                                     允许手动补全（context window 等）
```

目录每条记录包含：模型 ID、显示名、**context window**、最大输出 token、**是否支持 vision**、tool call、reasoning、输入/输出价格、知识截止、来源与同步时间。同步策略：App 启动时若距上次同步 > 7 天则后台增量更新；失败静默沿用旧数据，不阻塞使用。

### 8.3 测活（Health Check）

两级测活，对齐 Cherry Studio 的"检查"体验：

| 级别 | 方式 | 用途 |
|---|---|---|
| 连通性检查 | `GET /v1/models`（带 Key） | 验证 Base URL + Key 有效，不消耗生成 token；保存 Provider 时自动执行 |
| 模型级测活 | 最小 `chat/completions`（`max_tokens=1`，固定 ping 文案） | 验证"这个模型真实可用"，记录延迟；模型列表逐条显示状态 |

- 状态：`ok`（绿，< 3s）/ `degraded`（黄，3–10s）/ `down`（红，超时或错误），连同最近测活时间展示。
- 手动触发为主；切换模型前自动测一次；**不做高频定时轮询**（避免消耗用户额度与电量）。

### 8.4 能力路由

- 不同功能按能力过滤可选模型：**食物识别强制 `supportsVision = true`**；推荐管线可用纯文本模型。
- 当前激活模型不支持某能力时，对应功能入口提示"请切换到多模态模型"并引导一键切换，而不是报错失败。
- 降级链：激活模型测活失败 → 提示切换 → 用户不切换则走 MockLLMProvider 本地模板。

---

## 9. 页面结构：相机优先的手帐

首次启动先进入 Onboarding（第 6 节），完成后进入主界面。

Tab 结构（4 个）：`手帐`（默认主页）· `今日` · `用药` · `我的`

### 9.1 手帐页（主页）

上半部是**记录区**，下半部是**手帐时间线**，一屏完成"记"与"看"：

- **大拍照按钮**（视觉中心）：点击即拍，照片自动叠加水印快照
- **症状打卡入口**："今天身体怎么样？"——不拍照也能三步完成记录
- **语音速记入口**：长按说话，松手自动转写成一条手帐
- **手帐时间线**：按天分组的手帐流，每条 = 水印照片 / 语音转写 / 症状标签，当天聚合为"一页"
- 顶部一条**极简状态条**：今日状态（稳定/值得关注/建议咨询医生）+ 连续记录天数，点击跳转"今日"页看详情

### 9.2 拍照后的补充流程（全部可选，随时跳过）

```
拍照（自动叠加水印）
  → 补充页：语音补充（自动转文字）/ 文字 / 快捷标签（饮食·运动·情绪·症状）
  → AI 识别（云端多模态 LLM，见 2.3）给出初步标签与解释
  → 用户确认或修改
  → 写入手帐时间线
```

原则：**拍完即保存，补充永远不阻塞**。病人手抖、嫌麻烦时，一张带水印的照片本身就是有效记录。

### 9.3 今日页（支撑信息，浓缩呈现）

原首页五区浓缩为一页，服务"想了解自己状况"的时刻：
1. 今日状态 + 异常与原因（点击看五段式解释）
2. 今日用药摘要（可打卡，与用药 Tab 同步）
3. 复诊/检查提醒
4. 今日一条行动建议（来自 7.3 推荐管线，标注"AI 建议，仅供参考"）

### 9.4 用药页与我的

- 用药页：完整用药 Panel（药品、剂量、时间、周期、注意事项、打卡）
- 我的：个人资料与画像完善度、可穿戴连接、水印显示设置、提醒时间设置、演示模式开关
- **模型服务**（设置子页，对应第 8 节）：Provider 列表（预设/自定义、增删改、启用开关）、模型目录浏览（context window / vision / 价格等元数据）、逐模型测活状态、当前激活模型切换、上游目录手动同步

---

## 10. 安全与合规红线（写进代码评审清单）

- App 内固定声明："本应用不提供疾病诊断，不构成医疗建议。"所有 LLM 生成内容旁标注"AI 建议，仅供参考"。
- 处方/OCR/食物识别结果必须 `confirmedByUser == true` 才写入档案。
- 不出现"预测疾病发生""建议停药/加量"类文案；所有药物相关问题一律引导咨询医生或药师。
- L5 红旗症状只提示就医渠道，不做判断。
- **LLM 安全约束**：推荐只能从内容库候选集组合（7.3 管线）；Prompt 注入红线 + 输出后置关键词黑名单双重防护；发送给 LLM 的画像必须脱敏（无姓名、无精确出生日期）；照片仅在用户主动发起食物识别时外发。
- **API Key 安全**：Key 存 iOS Keychain，数据库只存引用，不进 git；P1 起改经后端代理转发，客户端不再持 Key。
- 数据全部本地存储（SwiftData + Sandbox）；MVP 无账号体系，除 LLM 请求外不联网络。
- 复诊智能建议统一措辞为"建议复查/建议咨询医生时间"，不表述为"AI 预测的必须体检时间"。

---

## 11. 测试策略

- 单测覆盖四个纯 Swift 引擎（Baseline / Alert / Advice / Medication）：构造边界数据（z 值临界、连续异常、多指标叠加、漏服）。
- **AdviceEngine 管线专项测试**（MockLLMProvider）：硬约束过滤正确性（心脏病用户候选集中无高强度项、广东"不辣"用户无辣菜）、LLM 输出越界时后置校验拦截并降级、无 Key 时模板降级可用。
- **LLM 服务管理测试**：模型目录三源合并与去重、上游同步失败静默沿用快照、`/v1/models` 发现结果与目录 join（含"元数据未知"分支）、测活状态机（ok/degraded/down）、能力路由（非 vision 模型不出现在食物识别可选列表）。
- Mock 数据剧本可复现 Demo 全流程，作为 UI 走查脚本。
- 真机验收：HealthKit 授权 → 读取 → 授权拒绝降级路径。

---

## 12. 里程碑

| 阶段 | 内容 |
|---|---|
| M1 脚手架 | 工程 + Tab 骨架 + SwiftData 模型 + Mock Provider + Onboarding 六步流程（含 HealthKit 预填与条件联动） |
| M2 P0 | 水印相机 + 拍照后语音/文字补充 + 确认流、症状打卡、手帐时间线、用药 Panel + 打卡、今日页、Baseline+Alert 引擎、内容库（食谱/运动 JSON）+ LLM 推荐管线（含降级）、**模型服务管理（Provider Switcher + 模型目录 + 测活）**、手动复诊提醒、复诊摘要 |
| M3 P1 | HealthKit 真机链路、OCR 处方提取 + LLM 结构化 + 确认、智能建议复查时间、行为-指标关联、LLM 后端代理、模型目录上游同步自动化 |
| M4 演示 | Demo 剧本数据、个性化推荐差异演示（广东不辣 vs 四川重辣、心脏病 vs 无限制）、红旗/持续异常场景走查、演示视频 |

---

## 13. 待团队确认的问题（阻塞项优先）

1. **预设 Provider 名单**：默认内置哪几家（建议：DeepSeek、通义 DashScope 兼容端点、豆包/火山方舟、智谱、OpenRouter）？食物识别要求多模态，预设里至少两家需有 vision 模型。
2. **模型目录上游**：采用 models.dev（开源、单 JSON、含 vision/context/价格字段）还是 OpenRouter `/api/v1/models`？是否自建镜像避免直连？
3. MVP 锁定病种：高血压 + 糖尿病 双病种是否确认？（心脏病/房颤约束已在 Onboarding 与内容库预留）
4. Alert 规则依据的具体指南版本（如《中国高血压防治指南》、ADA/CDS 糖尿病指南）需各指定一份。
5. **内容库的医学审定**：食谱 `avoidFor`、运动 `intensityMET` 与禁忌标签由谁按指南审定？
6. Demo 用真实数据还是 Mock 剧本数据？（建议 Mock 为主、真机真实数据为辅）
7. 团队 Apple Developer 账号（HealthKit entitlement 需要付费账号签名真机）。
