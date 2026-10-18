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

## Linux x86_64（box64）

待 x86_64 全量测试跑通后回填。命令：

```
source /tmp/x86env.sh
cd f_jit && box64 cjpm test --filter PerfCompare_test --no-progress --no-capture-output
```
