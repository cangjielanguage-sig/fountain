# Tasks

> 每个任务都按 Red-Green-Refactor 推进：先写用例并确认它因「功能未实现」而失败，再写最小实现，`cjpm test` 跑绿后才勾选。

## 1. 配置项与开关

- [x] 1.1 `LLMConfig` 增加 `llm_supervisor` / `llm_loomOnNoUsable` 两个键与 `supervisorEnabled()` / `loomOnNoUsable()`；验证：新增用例断言默认 false、单独设 `llm_loomOnNoUsable=true` 时 `loomOnNoUsable()` 仍为 false、两者都设时为 true（用例先失败）。

## 2. Supervisor 路由表

- [x] 2.1 实现 `Supervisor.eventName(name)` → `sv/<name>`，并保证不同流程名不碰撞；验证：用例断言两个名字的事件互不相等、前缀为 `sv/`。
- [x] 2.2 实现 `register` / `routes` / `eventOf` / `unregister`，同名重复登记幂等、删除后不可见；验证：用例覆盖「登记两条 → 2 条」「重复登记同名 → 仍 1 条」「删除 → 0 条且 `eventOf` 为空」。
- [x] 2.3 路由条目携带流程状态，选路候选只取 `compiled`；验证：用例断言 pending 流程出现在 `routes()` 但不在选路候选里。

## 3. 选路与派发

- [x] 3.1 实现选路提示词拼装与解析：提示词包含每个可执行流程的名称/描述/事件名与需求原文；验证：用例用假 chat 记录 system/user，断言三项信息齐全、需求原文出现。
- [x] 3.2 实现模型输出解析的四种容错（非 JSON、缺 `flow` 字段、空串、名字不在表内）——一律返回「无可用流程」且不抛错；验证：四个用例各自断言 `noUsableFlow`。
- [x] 3.3 实现命中后的派发：以 `sv/<name>` 为事件名、原描述为 `data` 构造起始事件并执行，返回流程名/事件名/产出；验证：用例用假 host 记录收到的 `StartEvent`，断言 `name`、`data` 与返回值。
- [x] 3.4 派发前二次校验流程状态：命中但已非 `compiled` → 按无可用流程处理；验证：用例在解析后把流程状态改回 pending，断言不执行。

## 4. 无可用流程的两种处置

- [x] 4.1 实现 `llm_loomOnNoUsable=false` 分支：返回 `noUsableFlow` 且消息为 `没有可完成此工作的流程`，不新建、不执行；验证：用例断言消息文案与流程存储条数不变。
- [x] 4.2 实现 `llm_loomOnNoUsable=true` 分支：生成不冲突的 `auto-*` 名字 → 编排 → 编译 → 登记 → 派发；验证：用例断言新流程出现在路由表、被派发执行一次、返回标注为新建。
- [x] 4.3 覆盖自动新建的两个边界：名字冲突时顺延（不与既有重名）与编排返回澄清时不登记不执行；验证：两个用例分别断言名字不重复、澄清状态下路由表未新增。

## 5. 生命周期联动

- [x] 5.1 `Supervisor.tap(flow)` / `untap(name)` 空实现判开关：未安装或未开启时直接返回；验证：用例断言关闭态下调用 `tap` 不产生路由、`current()` 为空。
- [x] 5.2 `LoomService.execute` / `confirmFlow` 在 `registry.put` 后调用 `tap`，`delete` 调用 `untap`；验证：用例走「execute → confirm → 路由表含该流程」与「delete → 路由表不含该流程」两条真实路径。
- [x] 5.3 关闭态回归：`llm_supervisor=false` 时上述三条路径行为与现状一致；验证：同一组用例在关闭态下断言路由表始终为空、无额外模型调用。

## 6. 装配与启动初始化

- [x] 6.1 `LoomWiring.wire` 在安装 host 之后按开关构造并安装 Supervisor，并以 `LoomRegistry` 现有流程播种；验证：用例用内存 store 预置两条 compiled 流程后 `wire`，断言 `Supervisor.current()` 的 `routes()` 含这两条。
- [x] 6.2 关闭态不安装 Supervisor；验证：用例断言 `wire` 后 `Supervisor.current()` 为空，且原有 `LoomService` 行为不变。

## 7. 文档

- [x] 7.1 `f_llm/doc/loom.md` 增加 Supervisor 章节（路由表、事件命名、选路提示词、两种无可用流程处置、开关与初始化）；验证：文档可读且与实现一致（逐项对照 `Supervisor.cj` 与 `LoomWiring.cj`）。
- [x] 7.2 `f_llm/README.md` 与 `README_en.md` 同步配置项与最小用法示例（中英成对）；验证：两份文档配置表均含两个新键，示例可编译（与 `Supervisor` 公开签名一致）。

## 8. 集成验证

- [x] 8.1 全量回归：`cd f_llm && cjpm test` 全绿，无新增告警；验证：命令输出贴入交付说明。
- [x] 8.2 端到端冒烟：内存 store + 假 chat 走「登记两条流程 → 描述命中 daily → 执行并返回产出」，再走「描述无命中 → 按配置新建并执行」；验证：两个用例通过，`openspec verify` 的 CRITICAL 清零。

## Workflow follow-up

- `openspec verify` → `openspec archive add-loom-supervisor`，归档后用最终版覆盖更新 `f_llm/doc/spec/add-loom-supervisor/`。
- 提交（不含 tag）：提交信息按仓库既有风格写清「新增 Supervisor 路由 / 两个配置项 / 文档」。
