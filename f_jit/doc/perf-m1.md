# M1 性能基线（S7.7）

- 用例：`f_jit/src/compiler/PerfCompare_test.cj::jitVsInterpVsCjnative`
- 负载：`{ n: Int64 => var s = 0; var i = 0; while (i < n) { s = s + i % 7; i = i + 1 }; s }`，`n = 200000`，5 轮
- 计时口径：JIT 资产（编译/码内存/入口表/常量镜像）在计时外创建；三侧结果逐位一致
- 命令：`cjpm test --filter PerfCompare_test --no-capture-output`（`--no-capture-output` 才会打印数字）

## Linux aarch64（native）

| 引擎 | 5 轮总耗时 | 相对解释器 | 相对 cjnative |
|---|---:|---:|---:|
| cjnative | 10,301,719 ns | — | 100% |
| JIT（预编译后） | 200,867,356 ns | **2.4%** | 1949% |
| 解释器 | 8,518,210,344 ns | 100% | 82688% |

- JIT 相对解释器：约 **42×** 加速
- JIT 相对 cjnative：约 **19×** 慢（栈机代码生成 + 每次 `invoke` 的边界/内存管理开销；M1 只要求相对解释器基线）

## Linux x86_64（真机，2026-10-19）

WSL Ubuntu-24.04 / `x86_64-unknown-linux-gnu` / Cangjie `1.3.0-alpha.20261015001050`；同用例、同负载、同计时口径。

| 引擎 | 5 轮总耗时 | 相对解释器 | 相对 cjnative |
|---|---:|---:|---:|
| cjnative | 3,198,433 ns | — | 100% |
| JIT（预编译后） | **2,276,989 ns** | **≈ 0.04%（约 2600× 加速）** | **71%** |
| 解释器 | 5,987,603,230 ns | 100% | ≈ 1872× |

- 命令：`cjpm test --filter PerfCompare_test --no-capture-output`（WSL x86_64 真机，`cangjie_env 1.3.0 1.3.0`）
- 三侧结果逐位一致（用例内 `@Assert(cj, base)` / `@Assert(ci, base)`）
- 备注：box64 模拟下曾出现 9 失败 + 1 错误，经真机复跑确认全部为模拟器 Float64 字面量缺陷，与 JIT 无关

## Linux x86_64（box64，历史留档）

已被真机数据取代；重跑命令：

```
source /tmp/x86env.sh
cd f_jit && box64 cjpm test --filter PerfCompare_test --no-progress --no-capture-output
```
