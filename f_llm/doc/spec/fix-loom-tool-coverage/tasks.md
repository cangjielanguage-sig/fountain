# Tasks

> 说明：本批为新 API 面（新工具类 + 新字段），实现与用例同批落地，未做到先红后绿，已在交付说明标注。

## 1. 工具补齐

- [x] 1.1 抽出 `StoreInvoker`（注入 > 装配安装 > 自建），`memoryCall` / `knowledgeIngest` 改用它；验证：既有工具用例不退化。
- [x] 1.2 新增 `loomStoreCall` + `StoreCallParam`，校验 kind/op/payload；验证：4 条用例（读知识、加载技能、缺 kind、payload 非对象）。

## 2. 技能在生产链路生效

- [x] 2.1 `FlowPlan.skills` + `toJson` 输出；验证：`toJson` 含 skills 字段。
- [x] 2.2 `LoomRequest.skills` + `PlanDto.skills` + `Planner.planOf` 映射；验证：计划 JSON 的 skills 进入 plan。
- [x] 2.3 `LoomService.executeNow(skills!)` 透传，优先级 调用方 > 计划；验证：2 条用例（计划生效、调用方覆盖）。

## 3. 集成

- [x] 3.1 全量回归 `cd f_llm && cjpm test` 全绿（基线 639）。
- [x] 3.2 `doc/loom.md` 工具表补 `loomStoreCall`；`README` 中英补一行工具与「计划里写 skills 即生效」。

## Workflow follow-up

- `openspec validate --strict` → 归档 → 覆盖 `f_llm/doc/spec/fix-loom-tool-coverage/`。
