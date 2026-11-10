# Proposal

## Why

loom 现在只能「按名字」执行流程：调用方必须自己知道该找哪个流程，模型也只能通过 `loomExecute` 现编一条新流程。流程一旦攒到十几条，**「这段活该交给哪个流程」**就变成调用方的负担，也容易出现「本该复用旧流程，却每轮重新规划一遍」的浪费。

Supervisor 把这件事收进框架：一批已编译的流程注册成可路由目标，一段自然语言描述由模型判定落到哪条流程，再由框架把描述作为事件投递给它。

## What Changes

- 新增 `Supervisor`：把已编译流程注册成「流程名 → Supervisor 事件名」路由表，接收一段描述、由模型选流程并执行。
- 新增两个配置项：
  - `llm_supervisor`（布尔，默认 `false`）：开启后流程自动注册进 Supervisor，进程启动时从 Store 载入全部流程完成初始化；
  - `llm_loomOnNoUsable`（布尔，默认 `false`）：Supervisor 判定没有可用流程时，`false` 立即返回「没有可完成此工作的流程」，`true` 自动编排新流程、注册并执行。仅在 `llm_supervisor=true` 时生效。
- 流程生命周期联动：`LoomService.execute` / `confirmFlow` 写入注册表后自动向 Supervisor 登记，`delete` 自动摘除；运行期新增/删除流程即时生效。
- 文档：`f_llm/README.md` / `README_en.md` 补配置项与用法，`doc/loom.md` 补 Supervisor 章节。

不涉及既有公开 API 的破坏性变更：`LoomService` / `LoomWiring` 只增加内部联动与新的可选入口。

## Capabilities

### New Capabilities
- `loom-supervisor`: 流程路由与派发（注册表、唯一事件、模型选路、无可用流程的两种处置、生命周期联动、初始化）。

### Modified Capabilities
<!-- 无：loom-flow 的既有需求（规划、编译、执行、持久化）不变，联动行为由新能力 own。 -->

## Impact

- 代码：`f_llm/src/loom/Supervisor.cj`（新增）、`LoomService.cj`（登记/摘除钩子）、`LoomWiring.cj`（装配与初始化）、`config/LLMConfig.cj`（两个配置项）。
- 配置：新增 `llm_supervisor`、`llm_loomOnNoUsable`；默认行为与现状完全一致（不开启则无任何额外调用）。
- 测试：新增 `f_llm/src/loom/Supervisor_test.cj`；`LoomService` / `LoomWiring` 相关用例补联动断言。
- 依赖：仅用现有 `LoomService` / `LoomRegistry` / `LoomHost` / `Planner.stripFence`，不新增第三方依赖、不改 `f_*` 其它模块。
