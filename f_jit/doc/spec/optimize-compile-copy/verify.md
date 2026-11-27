# 验证：optimize-compile-copy

## 1. 环境

- aarch64 共享 VM（7 核 A53），`taskset -c 0-4`，`cjpm test --filter … --parallel 1`
- 两臂负载相近：改前 load 5.31–6.84，改后 load 5.62–7.32
- 场景：200 个注册函数 × 50 个调用点；`dir.size = 1`，字节码 1230 B，机器码 9644 B

## 2. 改前分段（插桩，3 次采样取小）

`Assembler.assemble`：

| 段 | 实测 |
| --- | --- |
| `validate` | 0.27–0.69 ms |
| `layout`（函数体逐字节拷） | 0.44–0.74 ms |
| `encode`（常量/站点/名字编码） | 0.04–0.06 ms |
| `build`（CRC + 四段拼接） | **0.82–1.45 ms** |

`FbcReader.load`：`head` 0.14–0.16 / `slices` 0.15 / `dir` 0.20 / `types` 0.01 / `constSite` 0.24 ms。

## 3. A/B（同一探针，`git stash` 切臂）

端到端 = `SourceCompiler.compile` + `FbcReader.load` + `JitExecutor.create`，每次 5 轮取最小：

| 臂 | 各跑结果（ms） | 中位数 |
| --- | --- | --- |
| 改前（旧实现） | 12.20 / 7.27 / 12.31 | **12.20** |
| 改后 | 9.92 / 10.05 / 6.20 / 10.01 / 10.14 | **10.01** |

- **中位数 −18.0%**（12.20 → 10.01，5.0× 离散度内一致方向）
- 最优配对 −14.7%（7.27 → 6.20）
- 两臂的离散度都很大（共享 VM 双峰），故以中位数与最优配对同时判定，均 ≥ MOV。

## 4. 护栏

`src/compiler/CompileCopy_test.cj`：整单元 code 必须等于逐函数产物拼接，
`offsets/lengths/fnIds` 自洽，`entry(fnId)` 反查命中同一偏移。
该用例在 aarch64 走 `A64Compiler`、x86_64 走 `X86Compiler`，两种机器都有效。

| 实现 | 结果 |
| --- | --- |
| 改前（`git stash` 期） | PASSED 1 / FAILED 0 |
| 改后 | PASSED 1 / FAILED 0 |
| 变异：`lens[i] = size - 1` | **FAILED 1**（恢复后绿） |

改前先绿，说明护栏描述的是既有拼接契约，不是为新实现定制。

## 5. 既有强护栏

| 用例 | 断言内容 | 结果 |
| --- | --- | --- |
| `Golden_test` | `.fbc` 产物逐字节 | 4 / 4 |
| `X86Compile_test` | x86_64 编码字节 | 11 / 11 |
| `X86Lower_test` | x86_64 降低指令序列 | 50 / 50 |

`FbcWriter` 的载荷拼接改动由 `Golden_test` 的逐字节比对兜底；
`X86Lower` 的单次解码由 `X86Compile_test` / `X86Lower_test` 兜底。

## 6. 全量

`cjpm test --parallel 1`：**1241 / 1241，0 失败 0 错误**（较改前 1239 多出本次新增的 1 条护栏，
另 1 条为临时探针，已删除）。

## 7. x86_64 说明

本次 5 项改动中，第 1–4 项（整单元拼接、`FbcWriter` 载荷、`Assembler` 块拷贝、
去掉重复 `flushICache`）在 A64 与 x86_64 **共用同一条代码路径**；
第 5 项（`X86Lower` 单次解码）只影响 x86_64。

本机为 aarch64，x86_64 的**执行**未能实跑；x86 的**编码**由 `X86Compile_test`（11 条）
与 `X86Lower_test`（50 条）在本机通过。x86 机器上建议按此顺序复核：

1. `cjpm test --filter X86Exec_test`（真实执行 x86 机器码）
2. `cjpm test --filter CompileCopy_test`（拼接契约；x86 分支走 `X86Compiler`）
3. `cjpm test --parallel 1` 全量
4. 如要数据：用一个计时用例对比本提交前后的编译延迟（本机无 x86，未给基线）

## 8. 未做

- `FbcReader.load` 未动：4 次切片 + 三张表解码合计 0.75–0.82 ms，都是最小形态；
- `Assembler.validate` 未动：逐指令栈校验，属真实工作量；
- x86 的逐指令 `bind('L${off}')` 字符串建键未动：改偏移键要动 `bindLabel` 外部契约。
