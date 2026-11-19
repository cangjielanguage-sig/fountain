# Proposal

## Why

代码审查 R2 指出读路径上有三处**静默给错结果**（不报错、不告警，调用方以为拿到了全部）：

- `loomStore("experience","search",…)` 只查 `kind=experience`，**查不到 `experience_failed`** —— 流程失败时写的教训对检索不可见，等于只复盘成功；
- `memory.list` / `knowledge.docIds` 未给 `limit` 时 `intOf` 返回 0，落到底层就是 `limit=0` → **返回空数组**，调用方以为「没有数据」；
- `kind=jit` 的步骤源码里的 `{start.output}` 之类占位符**不做替换**，原样进代码（多数情况下编译不过，个别情况下变成字面量字符串），排查成本高。

## What Changes

- `experience` 的 `search` / `list` 在**未显式给 kind** 时同时覆盖 `experience` 与 `experience_failed`（显式给 kind 时仍以显式值为准）。
- `memory.list` / `knowledge.docIds` 的 `limit` 缺省改为 50（与文档里的分页示例一致），`offset` 缺省 0；`limit<=0` 视为「用缺省值」，不再静默返回空。
- `jit` 步骤在编译期检查源码里的 `{…}` 占位符：命中就抛 `LoomException`，提示改用 `llm`/`tool` 步骤或 `loomStore`/`loomCallTool`——**fail loud** 好过留一个字面量。

## Capabilities

### Modified Capabilities
- `loom-flow`：经验检索覆盖失败经验；分页参数有确定缺省；jit 步骤对模板占位符显式拒绝。

## Impact

- 代码：`src/loom/LoomStoreGateway.cj`（kind 集合与分页缺省）、`src/loom/LoomCompiler.cj`（jit 校验）。
- 行为：`experience` 检索结果会多出失败经验（预期内的修正）；不带 `limit` 的读操作从空数组变为 50 条上限。
- 测试：新增 5 条（覆盖失败经验、显式 kind 仍优先、list/docIds 缺省、limit<=0、jit 占位符被拒）。
