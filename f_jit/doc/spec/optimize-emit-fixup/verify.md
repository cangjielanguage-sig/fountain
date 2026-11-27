# 验证：optimize-emit-fixup

## 1. 环境

- 构建机：aarch64 共享 VM（7 核 A53），`taskset -c 0-4`，`cjpm test --filter … --parallel 1`
- 负载：改前 load 5.0–7.8，改后 load 6.3–8.8（**改后更忙**，对结论保守有利）
- 场景：200 个注册函数 × 50 个调用点；`unit.dir.size = 1`，字节码 1230 B，机器码 9644 B

## 2. 分段（改前，5 轮取最小）

| 阶段 | 实测 | 占单次编译 |
| --- | --- | --- |
| `JitExecutor.create` | **37.72 ms** | 87% |
| `JitCompiler.compileUnitWith` | 37.72 ms | 87% |
| `A64Emitter.finishOrNull`（临时插桩，16 次采样） | **33.42–52.95 ms** | 78–92% |
| `A64Lower.lower` | 1.33–1.79 ms | 3–4% |
| `A64Emitter` prologue / audit / tail | 0.011–0.054 / 0.118–0.204 / 0.021–0.029 ms | <1% |
| 前端 `SourceCompiler.compile` | 5.43–5.55 ms | 13% |

结论：不是「发码本身慢」，是 `finishOrNull` 的 O(R×L) 标签线性扫描 + 双遍回填。

## 3. A/B（同一探针，交替两臂）

端到端 = `SourceCompiler.compile` + `FbcReader.load` + `JitExecutor.create`（与生产同序列），
每个 arm 5 轮取最小，单测三跑：

| 指标 | 改前 | 改后 | 最优配对 |
| --- | --- | --- | --- |
| **端到端** | 44.32 / 24.06 / 45.07 ms | **11.06 / 11.10 / 6.42 ms** | **44.32 → 6.42（−85.5%，6.9×）** |
| `compileUnit`（5 轮最小） | 37.72 ms | **2.62 / 5.11 / 2.77 ms** | 37.72 → 2.62（**−93.1%，14.4×**） |
| `perFnSum`（5 轮最小） | 35.34 ms | **1.39 / 2.56 / 1.45 ms** | 35.34 → 1.39（**−96.1%，25.4×**） |
| `fnTableAlloc` | 2.03–3.13 µs | 0.63–2.19 µs | 噪声内 |
| `constPin` / `mirrorBuild` | 6.6–8.6 / 0.8–1.1 µs | 同量级 | 不受影响 |

保守取两臂最差配对（改前 24.06 → 改后 11.10）也有 **−53.9%**。按 MOV 规则 `max(3%, 2×离散度)`
判定 **keep**。

## 4. 护栏

`src/backend/A64EmitterFixup_test.cj` 4 条：

| 用例 | 改前（旧发射器） | 改后 |
| --- | --- | --- |
| `branchesResolveToExactOffsets`（300 条 `b`，imm26 = 1+k%4） | 绿 | 绿 |
| `firstBindWins`（同名二次 bind 仍指首次偏移；未知名 -1） | 绿 | 绿 |
| `conditionalKindsUseImm19`（b.cond imm19=3、cbz imm19=2、rt=9） | 绿 | 绿 |
| `finishIsIdempotent`（`finishOrNull` 后再 `finish` 字节相同） | 绿 | 绿 |

**改前先跑一遍全绿**，说明护栏描述的是既有语义（等价性），不是为新实现量身定制。

## 5. 变异

| 变异 | 期望 | 实测 |
| --- | --- | --- |
| A：`bind` 改为「总是覆盖」 | `firstBindWins` 红 | **FAILED: 1（firstBindWins）**，其余 3 绿 |
| B：回填恒按 `kind == 0`（imm26） | `conditionalKindsUseImm19` 红 | **FAILED: 1（conditionalKindsUseImm19）**，其余 3 绿 |

两次变异后均从 `/tmp/A64Emitter.fixed.cj` 完整恢复，并确认源码中无 `MUTATION` 残留。

## 6. 全量

`cjpm test --parallel 1`：**1239 / 1239，0 失败，0 错误**（较改前 1235 多出本次新增的 4 条护栏）。

## 7. 与 x86 侧的一致性

`X86Lower` 本来就用 `HashMap<String, Int64>` 存标签、`finish()` 单遍查表回填。
本次是把 A64 侧对齐到 x86 侧已有实现，不是新发明；x86 无同类退化。

## 8. 未做

- 前端 5.4→2.7 ms 内的 `assemble` / `parse` / `lower` / `load`：真实工作量，未 profile 到具体热点，不动；
- `normalizeNewlines` 在管线中被调 4 次（合计 38 µs，占改后总延迟 <1%），不动；
- `compileUnitWith` 的逐字节 `for (x in b) out.add(x)` 拷贝（改后约 1.2 ms，占 19%），
  可改 `add(all)`/预分配，属下一个独立变更。
