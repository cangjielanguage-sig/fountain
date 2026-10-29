# Tasks

- [x] R1 `JitFunction <: Resource`；`unload(timeoutMs)` → `close(timeoutMs)`；新增 `close(): Unit`。
- [x] R2 `prop isClosed` → `func isClosed()`（入口 = 单元 `state==2`；包装 = 条目 `state==2`）；删除 `isUnloaded()`。
- [x] R3 `unloadFn` → private `closeClosure`（`close` 分派调用）。
- [x] R4 仓内调用点：13 个文件、47 处 `unload(` → `close(`，`isUnloaded()` / `.isClosed` → `isClosed()`；回滚 4 个 runtime 文件里 `Range.isClosed` 的误替换。
- [x] R5 新用例 `resourceContractOnUnitAndWrapper`、`entryCloseIsUnitLevel`。
- [x] R6 全量 `cjpm test`：**1153 / 1153 PASSED，0 FAILED，0 ERROR**。
- [x] R7 文档同步（README 中英 API 表与关闭说明、design-m2 §6.1.4、jit-bytecode-m2 §14.2）。
- [x] R8 `openspec validate --strict` + 归档 + `doc/spec/` 落盘。
