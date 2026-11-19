# Proposal

## Why

R2 的两条问题指向同一件事：**模型在 `kind=tool` 的步骤里拿不到「读」的能力**。

- 现有工具只有 `memoryCall`（search/add/remove）与 `knowledgeIngest`（≡ knowledge.upsert），
  没有读知识、读经验、加载技能的工具——这些能力只有 JIT 片段里的 `loomStore(...)` 才有，
  而 JIT 代码由模型生成、无法在工具循环里调用；
- `LoomRunner.run(skills:)` 只在宿主直调时可用：`LoomService.executeNow` 不传 `skills`，
  `FlowPlan` 也没有 skills 字段，所以「编排时把技能列出来」在生产链路上不成立。

## What Changes

- 新增工具 `loomStoreCall(kind, op, payload)`：与 `loomStore(...)` 同一条网关、同一套 op，
  覆盖 `memory / experience / knowledge / skill / prompt / character`；`kind`/`op` 缺失或 payload
  不是 JSON 对象时返回可读错误，不抛异常。
- 三个工具的存储调用抽成 `StoreInvoker`（注入 > 装配安装 > 自建），消除第三份拷贝。
- `FlowPlan` 增加 `skills`，由 `Planner` 从计划 JSON 读入（`LoomRequest.skills` 作为兜底）；
  `LoomService.executeNow` 把它传给 `LoomRunner.run(skills:)`，并允许调用方显式覆盖。
- `FlowPlan.toJson` 输出 `skills`，便于计划落库后回放。

## Capabilities

### Modified Capabilities
- `loom-flow`：工具层补齐读能力；计划声明的技能在生产链路生效。

## Impact

- 代码：`StoreFunctions.cj`（新工具 + 抽公共调用）、`Plan.cj`、`Planner.cj`、`LoomService.cj`。
- 兼容：`memoryCall` / `knowledgeIngest` 保留，行为不变（内部改走 `StoreInvoker`）。
- 测试：新增 6 条（4 条工具 + 2 条技能传递）。
- 说明：本批为新 API 面（新工具类、新字段），实现先行、用例随行；未做到先红后绿，已在 tasks 中标注。
