# Tasks

## H1 改名 `close` → `unloadFn`

- [x] H1.1 先改调用面：把仓内 20 处 `w.close()` / `f.close()` 改为 `unloadFn()`，构建应因「方法不存在」失败（红态）。**（实际 20 处，含新用例 1 处；残留仅 `IterTable.Entry.close`，与 JitFunction 无关）**
- [x] H1.2 再改 `JitFunction`：`close` → `unloadFn`，注释与错误消息同步（「非闭包包装实例不可 unloadFn」）；`isClosed` 保留原名
- [x] H1.3 用例改名：`closeIsIdempotentAndReleasesGroup` → `unloadFnIsIdempotentAndReleasesGroup`、`closeOnEntryInstanceIsRejected` → `unloadFnOnEntryInstanceIsRejected`

## H2 卸载逐出编译缓存

- [x] H2.1 先写失败用例（`refineUnload_test`）：编译 → `runs()==1` → `unload()` → 同源再编译，`runs()` 必须变 2 且新单元可调用；当前实现（不逐出）会停在 1。**（红态实测 left=1 / right=2；负向对照 `unloadFnKeepsUnitInCache` 当时即通过）**
- [x] H2.2 `JitFunction` 增加 `cacheKey: ?String` + `internal bindCacheKey`；`CompileCache.finish` 发布时写入
- [x] H2.3 `unload` 成功进入终态时取走 `cacheKey` 并 `CompileCache.remove(key)`；超时回退不逐出；二次 `unload` 幂等

## H3 文档与规格

- [x] H3.1 `doc/design-m2.md` 的 API 表 / 释放协议 / 状态扩展三处改名，并注明 `isClosed` 与 `unloadFn` 的对应。**（实际 6 处）**
- [x] H3.2 `doc/jit-bytecode-m2.md` 当前行为表与测试要点处改名（历史留档段落保留原名并标注）
- [x] H3.3 规格 delta 通过 `validate --strict`

## H4 验收与归档

- [x] H4.1 全量 `cjpm test --parallel 1` 零失败零 error；新增用例计数对照。**（1140/1140，+3）**
- [x] H4.2 `verify.md`：改名落点清单、逐出时机、已知边界（state=1 窗口）
- [x] H4.3 归档 `openspec archive refine-f-jit-unload-api --yes`，同步 `f_jit/doc/spec/` 镜像
