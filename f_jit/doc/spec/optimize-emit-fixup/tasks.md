# 任务：optimize-emit-fixup

## E1 基线（已完成，数据见 proposal）

- [x] E1.1 分段探针：前端 / `create` / `compileUnitWith` / `compileOnce` 各阶段（aarch64，5 轮取最小）。
- [x] E1.2 定位：`A64Emitter.finishOrNull` = 33–53 ms，`A64Lower.lower` = 1.3–1.8 ms。
- [x] E1.3 根因：`labelOffset` 线性扫 + `finishOrNull`/`finish` 双遍扫描。

## E2 护栏（先红后绿）

- [x] E2.1 新增 `src/backend/A64EmitterFixup_test.cj` 五条用例（见 design §4）。
- [x] E2.2 在**未改动**的发射器上跑一遍：4 条全绿（`PASSED: 4, FAILED: 0`）。

## E3 实现

- [x] E3.1 `labels` 改 `HashMap<String, Int64>`，`bind` 首次绑定优先，`labelOffset` O(1)。
- [x] E3.2 新增 `resolve(checkRange:)`，`finish()`/`finishOrNull()` 复用它（单遍回填）。
- [x] E3.3 删除 `A64Label` 结构与 `ArrayList` 标签表（无其它引用）。

## E4 验证

- [x] E4.1 护栏四条全绿。
- [x] E4.2 变异 A（`bind` 总是覆盖）⇒ `firstBindWins` 红（3 绿 1 红）；恢复。
- [x] E4.3 变异 B（回填恒用 kind 0）⇒ `conditionalKindsUseImm19` 红（3 绿 1 红）；恢复。
- [x] E4.4 A/B：端到端 44.32 ms → **6.42 ms（−85.5%）**；`compileUnit` 37.72 → **2.62 ms（−93.1%）**；
      `perFnSum` 35.34 → **1.39 ms（−96.1%）**。
- [x] E4.5 全量 `cjpm test --parallel 1`：**1239 / 1239 / 0 失败**。

## E5 收口

- [x] E5.1 `verify.md` 记录数据与变异结果。
- [x] E5.2 镜像到 `f_jit/doc/spec/optimize-emit-fixup/` 并 `openspec validate --strict`。
- [x] E5.3 归档；`doc/optimize-compile-path.md` 补 §9。
- [x] E5.4 删除临时探针 `src/compiler/CompileStageProbe_test.cj`。
