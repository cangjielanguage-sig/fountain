# loom：文本 → 流程编排

设计见 `f_llm-memory-design.md` §9；本文只记**当前实现状态**与使用方式。

## 链路

```
自然语言描述
  → Planner（LLM 产出 JSON 计划，或返回澄清问题）
  → CodeGen（计划 → 步骤源码 + 流程源码，不编译）
  → LoomRegistry / LoomStore（存源码与状态，llm_loom_flow）
  → LoomCompiler（编译步骤闭包）
  → LoomRunner（拓扑序执行，结果事件）
```

## 状态机

`clarifying → pending → compiled`，编译失败标 `failed`（单条失败不影响其它流程）。

| 状态 | 含义 |
|---|---|
| `clarifying` | Planner 判定描述有歧义，已存问题，未生成源码 |
| `pending` | 已生成源码，未编译（`loomExecute(confirm=false)` 的结果） |
| `compiled` | 步骤闭包编译成功，可执行 |
| `failed` | 启动重编译失败，需人工修 |

## 两个工具

| 工具 | 关键参数 | 行为 |
|---|---|---|
| `loomExecute` | `name, description, tools?, mcps?, persona?, confirm?` | `confirm=false` 返回计划与闭包原文；`confirm=true` 按 name 编译并标 compiled |
| `loomDelete` | `name` | 从注册表与库中移除 |

## 装配

宿主在 `StoreWiring.wire()` 之后调用一次：

```cangjie
LoomWiring.wire({ model, system, user => /* 调 LLM；model 为空串时用默认模型 */ },
                plannerModel: 'chat-pro')
```

- 存储按 `llm_memoryStore` 选：`postgres` / `mysql` 走 SQL，其余（如默认的 `f_hydra`）走内存；
- `LoomWiring.wire` 内部会 `restore()` 并重编译 `compiled` 流程；
- 工具调用通过 `LoomServices.current()` 取服务实例。

## 执行语义

- 步骤按**拓扑序串行**执行，依赖顺序严格正确；
- 流程级没有走 JIT：`CodeGen.flowSource` 只作预览/落库原文；
- `jit` 步骤由 f_jit 编译；`tool` / `mcp` / `llm` 步骤走宿主原生闭包（f_jit 当前不支持命名实参与静态类）；
- 模板 `{stepId.output}` 由 `LoomHostApi` 的跨步骤输出表替换，未命中的占位符原样保留。

## 已知边界

| 项 | 说明 |
|---|---|
| 并行执行 | 未接 `f_egraph` 的 `ImmediateFlow`/`AsyncFlow`：`Dispatcher` 私有，`QueuedClosureTask` 拿不到所属实例；多后继还需拆 `MultiEvent` |
| `confirm` 后自动执行 | 需要显式调用 `LoomService.executeNow`，`loomExecute` 不自动执行 |
| 真实宿主 | `DefaultLoomHost` 的工具通道接 `FunctionMediator`，模型通道由装配方注入；没有内置 LLM 客户端 |
| `step_sources` 编码 | 存 `id\u0001source`、`\u0002` 分隔（不是 JSON）：避免源码引号/换行的转义问题 |
