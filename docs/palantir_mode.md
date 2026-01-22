# Palantir 模式（本项目实现说明）

> 目标：让“AI 问答”不是预设查询，而是**基于可核验事实（facts）**做总结、解释、归因与建议，并支持下钻扩展。

## 1. 核心理念

本项目采用「Palantir 模式」的最小可用闭环：

1) **先产出事实 facts（结构化、可核验）**：由后端基于落库数据做聚合统计与样本列表。
2) **再由大模型生成自然语言答案**：大模型只允许基于 facts 进行总结/解释/归因/建议，不允许编数字。
3) **答案与 facts 一起返回**：便于前端追溯与后续“证据引用/下钻”。

## 2. 现状能力（MVP）

### 2.1 数据来源
- 工序验收：`acceptance_records`
- 日常巡检：`issue_reports`

关键维度：
- 位置：`region_text`（并解析出 `building_no` / `floor_no` / `zone`）
- WBS：`division/subdivision/item/item_code/indicator/indicator_code`
- 状态：验收 `result`（qualified/unqualified/pending），巡检 `status`（open/closed）

### 2.2 Facts（后端聚合输出）
后端汇总接口：
- `GET /v1/dashboard/summary`

当前主要 facts 字段（示例）：
- `acceptance_total / acceptance_qualified / acceptance_unqualified / acceptance_pending`
  - 口径：**验收分项数（item 维度）**，按“最差结果”归类：不合格 > 甩项 > 合格
- `issues_total / issues_open / issues_closed`
- `top_responsible_units`（未闭环问题 TopN 责任单位）
- `recent_unqualified_acceptance`（最近不合格验收样本）
- `recent_open_issues`（最近未闭环巡检样本）
- `by_building`（按楼栋汇总：验收/巡检）

### 2.3 AI 问答
接口：
- `POST /v1/ai/chat`

后端处理流程：
1) 取项目维度（project_name）
2) **意图解析（Plan）**：把自然语言问题解析为结构化计划（范围/维度/输出风格）
3) **按 Plan 生成 scoped facts**：只聚合用户问的范围（例如 1栋/1栋6层/某责任单位）
4) **优先调用豆包（ARK）**生成回答；失败回退规则回答
5) 返回：`{ answer, facts, meta }`

`meta.llm.used` 用于确认是否真的走了大模型（以及使用的 model/endpoint id）。

补充：为什么要加 Plan

- 仅靠提示词“按范围回答”不够稳，模型仍可能把所有楼栋都讲一遍。
- 仅靠规则匹配会陷入“穷举各种问法”。Plan 把“用户意图”抽象成结构化参数，让后端用统一方式生成数据，再由模型表达。

## 3. “更自由对话”的实现策略

为了让“解释一下 / 为什么 / 归因 / 建议 / 只看1栋”等自然提问更好用，本项目做了两层：

### 3.1 前端：多轮上下文
- 前端在 `AI问答` 页会把最近 N 轮对话作为 `messages` 一起提交到 `/v1/ai/chat`
- 后端会将对话历史拼进模型输入（同时附带同一份 facts），让模型能理解跟进问题

### 3.2 后端：强约束提示词
系统提示词要求：
- **必须基于 facts**，不允许编造
- 输出结构：结论 → 证据 → 原因分析/归因 → 建议
- 如果用户问“某栋/某层/某责任单位”，只回答对应范围

同时保留规则回退：
- 在模型不可用时仍可回答“项目进展/按楼栋/指定1栋”等基础问题

### 3.3 后端：scoped facts（让回答更“精准”）

为避免“问 1栋 但回答全项目/全楼栋”，后端会把 Plan 写进 facts，并在有范围时输出 scoped facts：

- `plan`：意图解析结果（范围/维度/输出风格）
- `scope`：当前实际采用的范围（building/floor/responsible_unit）
- `scope_acceptance`：范围内的验收分项口径统计
- `scope_issues`：范围内的巡检闭环统计
- `by_floor`：当 scope 指定 building 时，提供楼栋内按楼层汇总（用于回答“1栋进展”时的内部差异）

## 4. 语音问答（与 Palantir 的关系）

AI问答支持语音输入：
- 长按麦克风：语音识别 → 自动发送 →（仅语音触发时）TTS 播报答案

语音只是“输入/输出通道”，核心仍是：**facts + 受约束的大模型总结**。

## 5. 如何扩展（下一步建议）

1) Facts 维度扩展
- 按楼层：`by_floor`（楼栋 + 楼层）
- 按分部/分项：`by_division/by_item`
- 按时间趋势：近7天/30天不合格、未闭环变化

2) 证据引用与下钻
- AI 答案中引用 `recent_*` 的具体条目（可点击跳转到记录详情）
- 驾驶舱 KPI → 点击进入列表（过滤条件：楼栋/责任单位/状态…）

3) 数据质量
- 强化 `region_text` 规范化（避免“未解析”）
- 统一 item/item_code 的来源，减少同名分项重复

## 6. 相关代码位置

- 后端：聚合与问答逻辑：
  - `backend/main.py`
- Flutter：AI问答 UI 与多轮历史：
  - `lib/screens/ai_chat_screen.dart`
  - `lib/services/backend_api_service.dart`
- 驾驶舱 UI：
  - `lib/screens/project_dashboard_screen.dart`
