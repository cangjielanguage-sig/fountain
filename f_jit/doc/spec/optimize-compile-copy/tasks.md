# 任务：optimize-compile-copy

## F1 基线（已完成）

- [x] F1.1 `Assembler` 内部分段：`validate` 0.27–0.69 / `layout` 0.44–0.74 / `encode` 0.04–0.06 / `build` 0.82–1.45 ms。
- [x] F1.2 `FbcReader.load` 分段：`head` 0.14–0.16 / `slices` 0.15 / `dir` 0.20 / `types` 0.01 / `constSite` 0.24 ms。
- [x] F1.3 定位 `compileUnitWith` 逐字节 `add` + `toArray` 两趟搬运；`create` 重复 `flushICache`。

## F2 护栏

- [x] F2.1 新增 `src/compiler/CompileCopy_test.cj`（整单元 == 逐函数拼接 + offsets/lengths/entry）。
- [x] F2.2 在**未改动**实现上跑一遍：必须全绿。

## F3 实现

- [x] F3.1 `JitCompiler.compileUnitWith` 两遍 + 预分配数组。
- [x] F3.2 `FbcWriter.payload()` 一次拼接；`build()` 单次 CRC + 头体拼接。
- [x] F3.3 `Assembler` 函数体 `clone()`。
- [x] F3.4 `JitExecutor.create` 删除重复 `flushICache()`。
- [x] F3.5 `X86Lower.lower` 探针遍缓存 `DecodedInsn`，发射遍复用。

## F4 验证

- [x] F4.1 护栏 + `Golden_test` + `X86Compile_test` + `X86Lower_test` 全绿。
- [x] F4.2 A/B：端到端同探针两臂（`git stash` 切换），记录最优与分布。
- [x] F4.3 全量 `cjpm test --parallel 1` 零失败。
- [x] F4.4 变异：`compileUnitWith` 的 `lens[i]` 少加一 ⇒ `CompileCopy_test` 必须红；恢复。

## F5 收口

- [x] F5.1 `verify.md` 记录数据。
- [x] F5.2 镜像到 `f_jit/doc/spec/optimize-compile-copy/` 并 `openspec validate --strict`。
- [x] F5.3 归档；`doc/optimize-compile-path.md` 补 §10。
- [x] F5.4 删除临时探针。
