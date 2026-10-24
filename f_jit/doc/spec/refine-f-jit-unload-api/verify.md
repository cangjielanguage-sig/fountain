# Verify

## 全量回归

| 项 | 数值 |
| --- | --- |
| 基线（`e439a303`） | 1137 用例 / 1137 通过 / 0 失败 |
| 终态 | **1140 用例 / 1140 通过 / 0 失败 / 0 error / 0 skipped** |
| 新增用例 | 3 条（`refineUnload_test`） |
| 改名用例 | 2 条（`closeIsIdempotentAndReleasesGroup` / `closeOnEntryInstanceIsRejected`） |
| 回归 | 0 |

## H1 改名落点（20 处调用 + 1 处定义）

| 文件 | 处数 | 说明 |
| --- | --- | --- |
| `JitFunction.cj` | 1 | 定义 `close` → `unloadFn`；错误消息同步 |
| `JitFunctionClosure_test.cj` | 11 | 含 2 条用例改名 |
| `Q6Acceptance_test.cj` | 6 | 仅调用面 |
| `CallForFnConcurrency_test.cj` | 2 | 仅调用面 |
| `Slot14_test.cj` | 1 | 仅调用面 |
| `refineUnload_test.cj` | 1 | 新用例的负向对照 |

`isClosed` 保留原名（D1）：它描述包装状态，不是操作名；文档已注明对应关系。

## H2 逐出时机

| 路径 | 是否逐出 | 依据 |
| --- | --- | --- |
| `unload()` 进入终态（`state=2`） | **是** | `cacheKey` 取走并置 None，`CompileCache.remove(key)` |
| `unload(timeoutMs)` 超时回退（`state=1 → 0`） | 否 | 单元仍可用；逐出会造出同键两份产物 |
| 重复 `unload()` | 否（已无键） | `state==2` 提前返回 true |
| `unloadFn()`（闭包包装） | 否 | 只释放提升组；单元与缓存不动 |

红→绿证据：

| 用例 | 红态（实现前） | 绿态（实现后） |
| --- | --- | --- |
| `unloadEvictsUnitFromCache` | `runs()` left=1, right=2 | PASSED |
| `repeatedUnloadEvictsOnce` | `runs()` left=1, right=2 | PASSED |
| `unloadFnKeepsUnitInCache` | PASSED（负向对照，证明 `close` 本就不逐出） | PASSED |

## 已知边界（design D3）

`state == 1`（卸载中）窗口内到达的同键编译，仍可能从缓存拿到正在卸载的单元并立即被 19 拒绝。
本次只保证**终态之后**的编译一定未命中重编。彻底解决需要给缓存项引入「代次/状态」维度
（否则「逐出 → 别人编译 → 我方超时回退写回」会让缓存持有较旧的一份），属独立的缓存并发改造。

`unloadTimeoutKeepsCacheEntry` 未自动化：需要可控的在飞调用，而现有 API 没有「阻塞在指定点」
的钩子；该分支由代码结构保证（逐出只写在 `state=2` 分支内），并在本文件表格中登记。

## 文档

- `doc/design-m2.md`：API 表（`unloadFn` / `isClosed`）、释放协议、状态扩展清单、§14 验收行。
- `doc/jit-bytecode-m2.md`：当前行为表、测试要点、两步交付注记。
- 历史归档（`doc/spec/f-jit-m2*`、`plan-m2.md`）保留旧名 `close`，不回改——它们是当时的过程记录。

## 归档

| 项 | 结果 |
| --- | --- |
| 命令 | `openspec archive refine-f-jit-unload-api --yes` |
| 增量应用 | **+0 added / ~2 modified**（`统一调用包装`、`卸载状态机与资产清点`） |
| 归档路径 | `openspec/changes/archive/2026-10-24-refine-f-jit-unload-api/` |
| 活动变更 | `openspec list` → 无 |
