# Proposal

## Why

`f_jit` 目前只有 P0 骨架占位（六个包各一个仅含 `package` 声明的 `.cj` 文件，未登记进根 `cjpm.toml`），没有任何可执行能力。M1 规格（`f_jit/doc/jit-bytecode-m1.md` v0.18.36）、详细设计（`design-m1.md`）与 TDD 计划（`plan-m1.md`，P0–P7 / S0.1–S7.8）已经冻结，但实现尚未开始。

本次变更把 M1 一次性落地：以**一份跨平台字节码为唯一分发产物**，给出语义基准解释器、Linux 上 x86_64 / AArch64 两个 JIT 后端，以及封闭的宿主桥（Marshal / 缓存 / 卸载），并用**差分 harness**把「同一字节码、三引擎逐位一致」（不变式 I7）变成可回归的硬判据。没有这一层，M2（宿主闭包/宿主对象）、M3（Any/JSON）没有可依赖的语义基准。

## What Changes

- **前置依赖**：在 `f_util` 新增 `Fnv` 常量命名空间族（`Fnv32`/`Fnv64`/`Fnv128`/`Fnv256`/`Fnv1024` × `fnv1`/`fnv1a`，标准 FNV 常量，不自造算法）与**统一 API**（`Fnv.hash(width, variant, data)` 返回统一的大端字数组、`FnvHasher` 支持增量喂入；类型化入口委托同一引擎），供 f_jit 的常量指纹（FNV-1a-64）与去重键（FNV-1a-128）调用；这是 S2.16 的前置任务。
- **P0 骨架与测试基建**：完善 `f_jit/cjpm.toml`（依赖 `f_base`/`f_regex`/`f_util`）、六个包与差分测试层目录；**不登记根 `cjpm.toml`**（用户裁定，模块以独立 cjpm 工程构建与回归）；建三引擎差分 harness（`src/test/diff`）与 T 编号映射表。
- **P1 `base`**：`LocalType`（0–12）、`TypeToken`（0–9）、`ErrCode`（含 `describe`/`isHostSide`）、`Version`（1/14/36/`"FBC1"`）、`SourcePos`/`JitMode`/`Engine`/`JitValue`/`CallContext`/`SourceUnit`、`JitException`/`SourceCompileException`（统一继承 `f_base.BaseException`）、`DiagnosticsSink`/`DiagnosticLevel`/`DiagCode`/`DummyDiagnosticsSink`。
- **P2 `bytecode`**：`OpInfo` 256 项 opcode 表、显式 LE 编解码原语、指令解码、函数目录与局部类型表、常量表模型与注册 API、站点表/名字表、`.fbc` 容器头与读写、加载期全拒绝面校验，以及接入 `f_util.Fnv` 的指纹原语。
- **P3 `compiler`**：词法（三形态字符串、行首锚定标记、嵌套注释、正则字面量）→ 语法 → 名字解析 → 明确赋值 → 降低（含控制流、闭包、多重赋值、正则操作符、尾递归）→ `BytecodeBuilder` → 汇编期校验 1–11 → `.fbc` 组装，失败一律 `SourceCompileException`。
- **P4 `runtime`**：64 B 非托管 ctx、句柄表/窗口/逃逸区、调用级迭代器表、H01–H72 helper 集（`@C` 薄入口 + 仓颉实现、失败只写码不抛异常）、`DbgDump` 单次转储与报告组装、**解释器（语义基准）**。
- **P5 `backend`**：`CodeBuffer`（W^X + I-cache）、`FnTable`、`ConstMirror`、`BackendSelector`（Off/Auto/Force × OS × Arch 矩阵）、`BackendX86_64` / `BackendAArch64` 全量 lowering、`JitCompiler` 两遍布局与跳板、降级一致性、IBT/BTI。
- **P6 门面/桥**：`Compiler`（两入口 + 注册表快照）、`PredefinedFunction`、`CallMarshal`、`JitFunction.call<T>` 六步、三态收尾与 `Report.throwJit`、`AdapterRegistry`、`CompileCache`（进程级、只编译一次）、`CompilePipeline`、`unload` 状态机、用户面再导出。
- **P7 差分与验收**：T1–T29 / T42–T48 / T50–T53 全部接入差分 harness；容量与性能基线实测留档；设计与计划文档回写同步。
- **无破坏性改动**：`f_jit` 为新增模块，不修改既有模块公开 API；`f_util` 仅新增 `Fnv`（纯增量）。

## Capabilities

### New Capabilities

- `f-util-fnv`: `f_util` 的 FNV 哈希族（32/64/128/256/1024 × fnv1/fnv1a）、统一 API（`Fnv.hash` / `FnvHasher`）与黄金值校验，供 f_jit 指纹与去重键复用；`Fnv1024` 以 16 字大端序表示，落实 1024 位乘法与进位正确性。
- `f-jit-module-skeleton`: `f_jit` 模块的包结构、构建配置与 `cjpm build`/`cjpm test` 基线（模块独立构建，不登记根 `cjpm.toml`）。
- `f-jit-base-contracts`: `base` 包的共享契约——类型编码、错误码、公共值类型、异常与诊断接口。
- `f-jit-bytecode-format`: 字节码静态模型与 `.fbc` 容器编解码、加载期校验与版本兼容。
- `f-jit-compiler-frontend`: 源入口前端——词法/语法/名字解析/明确赋值/降低/汇编校验与 `.fbc` 产出。
- `f-jit-runtime`: 执行期设施——ctx、句柄表与窗口/逃逸区、迭代器表、helper 集、诊断转储与解释器。
- `f-jit-backend`: JIT 后端——代码内存、两架构 lowering、引擎选择与降级、生命周期与 IBT/BTI。
- `f-jit-facade-bridge`: 门面/桥——Compiler、JitFunction、Marshal、编译缓存、适配器注册表与卸载编排。
- `f-jit-differential-acceptance`: 三引擎差分 harness、T 系列验收映射、容量与性能基线、文档同步。

### Modified Capabilities

（无。仓库 `openspec/specs/` 当前为空，本次全部为新增能力。）

## Impact

- **代码**：新增/填充 `f_jit/src/{Root,base,bytecode,compiler,runtime,backend}` 与 `f_jit/src/test/diff`；修订 `f_jit/cjpm.toml`；`f_util/src` 新增 `Fnv`（含 `Fnv1024` 与统一 API）及 `Fnv_test`。**不改根 `cjpm.toml`**（用户裁定不登记 `f_jit`）。
- **API**：新增用户面 `fountain::f_jit.*`（`Compiler`/`JitFunction`/`CallMarshal`/`HandleTable`/`LocalType`/`ErrCode`/`JitException`/`SourceCompileException`/`JitMode`/`CompileOptions`/`PredefinedFunction`/`SourceUnit`/`CallContext`/`SourcePos`/`DiagnosticsSink` 等）；`JitContext`/`Engine`/`JitValue`/`CompileCache`/`AdapterRegistry`/`CallMarshal`/`CompilePipeline`/`Report`/`SourceCompiler`/`CompiledSourceUnit` 为 `protected`，不进用户面。
- **依赖**：`f_jit` 依赖 `f_base`（`BaseException`、OS/Arch）、`f_regex`（Regex 常量与 `String.regex()` 扩展）、`f_util`（`Crc32.isoHdlc`、新增 `Fnv`）；M3 才追加 `f_data`。
- **平台**：解释器全平台；JIT 仅 Linux 且指令集在仓颉 SDK for Linux 支持范围内（当前 x86_64 / aarch64）；其余平台恒为解释器并静默降级。本机为 aarch64 Linux ⇒ 机器码断言以 AArch64 为原生证据，x86_64 机器码用例转为条件跳过（跨架构由 CI 矩阵补），差分最小集为 `Interp × AArch64`。
- **进程**：差分 harness 为独立入口（同进程内跑三引擎逐位对拍）；本机构建与测试经融合开发环境（仓颉 1.3.0，Linux aarch64）执行。
- **文档**：`f_jit/doc/design-m1.md`、`plan-m1.md` 需按实现偏差回写（S7.8）；产物镜像一份到 `f_jit/doc/spec/f-jit-m1/` 随模块走查。
