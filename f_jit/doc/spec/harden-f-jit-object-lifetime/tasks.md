# Tasks

## 1. G1 返回值句柄异常安全

- [x] 1.1 `JitFunction.call` 的解包包 `try/catch`，异常路径先 `releaseReturnHandle` 再重抛
      验证：`cjpm test --filter Lifetime_test` 的 `contractFailDoesNotLeakHandle` 通过
- [x] 1.2 先写失败用例：连续 20 次契约失败后 `liveCount()` 必须等于基线
      验证：**RED 不可得**（unbox 前的静态契约检查先拦下 ⇒ 泄漏路径不可达，已记入 verify.md）；该用例保留为回归护栏

## 2. G4 句柄返回码单点派生

- [x] 2.1 `isReturnedHandle` 改为 `LocalType.isHandle(code) && code != CLOSURE`
      验证：既有全量用例无回归
- [x] 2.2 新增码表完备性用例：遍历 0–19，真集恰为 `4–11,13–19`，`12` 为假
      验证：`cjpm test --filter Lifetime_test` 通过

## 3. G5 发射审计（x86_64 + aarch64）

- [x] 3.1 x86：`BackendX86_64` 增审计表 + `noteMemBase`，在 8 个内存发射器打点；
      `X86Lower.lower` 结束时自检（允许 `{4,5,15}`，越界 ⇒ `ok=false`）
      验证：`EmitAudit_test.x86MemBasesAreControlled`
- [x] 3.2 aarch64：`A64Emitter` 增审计表 + `ldrOff/strOff` 打点；`A64Lower.lower` 结束时自检
      （允许 `{19,20,29,31}`，越界 ⇒ `ok=false`）
      验证：`EmitAudit_test.a64MemBasesAreControlled`（用 `SourceCompiler` + `FbcReader.load` +
      `A64Compiler.compileFunction` 交叉编译）
- [x] 3.3 审计非空断言（避免"没采集也算过"）：两侧快照长度 > 0
      验证：同 3.1/3.2 用例内的长度断言

## 4. G6 调用级资源归零

- [x] 4.1 新增用例：成功 / 运行期错误 / 契约失败各 20 次，每轮后
      `liveCount()==基线`、`windowUsed()==0`、`NativeMem.outstanding()` 不增长
      验证：`cjpm test --filter Lifetime_test` 通过

## 5. G3 结论固化

- [x] 5.1 新增用例：逃逸闭包捕获 `List`，跨调用读元素仍正确（证明元素是宿主引用、无需级联提升）
      验证：`cjpm test --filter Lifetime_test` 通过

## 6. 回归与文档

- [x] 6.1 全量 `cjpm test`：**1100+/1100+（0 ERROR / 0 FAILED）**（在 1099 基础上新增用例）
      验证：Summary 数字
- [x] 6.2 `verify.md` 追加 2026-10-22 第四轮记录（G1/G4/G5/G6 落点 + G2/G3 结论）；
      `jit-bytecode-m1` 若涉及口径则同步（G5 允许集）
      验证：文档可 grep

## Workflow follow-up

- 用户要求（2026-10-22）：G1/G3/G4/G5/G6 走 OpenSpec 全流程，G5 必须同时覆盖 x86_64 与 aarch64；
  G2（close 后释放）确认不是缺陷，仅入档。
- 完成后 `opsx:verify` + `opsx:archive`。
