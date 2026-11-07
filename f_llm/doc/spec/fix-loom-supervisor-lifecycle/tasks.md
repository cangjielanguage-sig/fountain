# Tasks

## 1. 陈旧路由

- [x] 1.1 漂移时先 `unregister` 再返回；验证：compiled 登记后把流程改回 pending，dispatch 返回 `noUsableFlow` 且 `routes()` 不含它（先失败）。
- [x] 1.2 选路段异常不外抛；验证：用会抛异常的流程库查询（或 FailingLoomStore）驱动 dispatch，断言返回对象而非异常。

## 2. 装配可观测

- [x] 2.1 `wire` 保留 `ReloadResult` 并可经 `LoomWiring.lastReload()` 读取；验证：FailingLoomStore 装配后 `lastReload().getOrThrow().restoreFailed == true`（先失败）。
- [x] 2.2 `restoreFailed` 为真时打 warn；`ReloadResult.toString()` 含该字段；验证：`toString().contains("restoreFailed")`。

## 3. 宿主不被覆盖

- [x] 3.1 `wire` 新增 `host!`，优先级 传入 > 已装 > Default；验证：先 installHost(自定义) 再 wire，`currentHost()` 仍是同一个实例（先失败）。
- [x] 3.2 传 `host:` 时以传入为准；验证：传入自定义 host，wire 后 `currentHost()` 是它。

## 4. 集成验证

- [x] 4.1 全量回归 `cd f_llm && cjpm test` 全绿（基线 621）。
- [x] 4.2 `doc/loom.md` 路由小节补「陈旧路由摘除」与「装配结果可观测」两行；README 中英补 `host` 参数说明。

## Workflow follow-up

- `openspec validate --strict` → 归档 → 覆盖 `f_llm/doc/spec/fix-loom-supervisor-lifecycle/`。
