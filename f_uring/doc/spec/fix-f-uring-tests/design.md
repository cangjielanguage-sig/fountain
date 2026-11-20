# Design

## Context

动机见 `proposal.md`。当前状态与约束：

- `f_uring` 的源码包是 `fountain::f_uring`（`src/IOUringStream.cj`）与 `fountain::f_uring.base`、`fountain::f_uring.lockfree`；测试包是 `fountain::f_uring.tests`（`src/tests/`），三者是**不同的包**，跨包访问必须显式 `import`。
- 最近一次演进把 `IOUringStream` 放进根包并新增 `fountain::f_io` 依赖（提交 `14c11de4f`），但 `src/tests/` 里三个 `iouring_stream_*.cj` 只导入了 `fountain::f_base.*` 与 `fountain::f_io.*`，没有导入根包 ⇒ 23 个 `undeclared identifier 'IOUringStream'`。
- `IoUringFuture<T>` 声明为 `public class`，但构造器写成 `init(promise: IoUringPromise<T>)`（无 `public`）⇒ 包内可见；测试包无法构造，报 `no matching constructor`。
- 全部 24 个错误已用 `--error-count-limit=all` 一次性取全（临时改 `cjpm.toml` 的诊断改动已回退，工作区无残留）。
- 平台约束：io_uring 只在 Linux 生效，测试类与实现均带 `@When[os == "Linux"]`；本机验证在 WSL Ubuntu-24.04 做（`source cangjie.sh` + `cangjie_env 1.3.0 1.3.0`，SDK 1.3.0-alpha）。
- 兼容性红线（用户要求）：不改既有公开签名语义、不破坏调用方。

## Goals / Non-Goals

**Goals:**

- `cjpm test` 在 f_uring 模块零编译错误、全部用例通过。
- 让 `IoUringFuture` 的公开性与 README 声明一致，且不破坏既有调用方。

**Non-Goals:**

- 不重排包结构（不把 `IOUringStream` 迁回子包、不新增 shim 包）。
- 不改 `cjpm.toml` 的依赖集合与编译选项（`-luring` 等保持原样）。
- 不做 `IOUringStream` 的性能优化或架构调整（`doc/优化方案.md` 与 README「已排除的优化方案」已有结论，本次不重开）。
- 不治理既有 warning（`unused variable` 等），除因本次改动直接产生的之外。

## Decisions

### D1：测试侧补根包导入，而非移动源码

两个引用了 `IOUringStream` 的测试文件各加一行 `import fountain::f_uring.*`：`iouring_stream_test.cj`、`iouring_stream_perf_test.cj`。`iouring_stream_read_micro_perf_test.cj` 经核实只用底层 `IoUring`／`IOUringSQE`（不引用根包符号），不加导入，避免制造 unused import 警告。

- 理由：`IOUringStream` 已在根包对外公开（README 也这么写），移动源码会同时改变公开包路径 ⇒ 破坏兼容。
- 备选：把 `IOUringStream` 移到 `fountain::f_uring.base` 并在根包留 re-export —— 仓颉没有 re-export 语法，只能写类型别名或继承包装，成本高且改变语义，放弃。
- 备选：测试里写全限定名 `fountain::f_uring.IOUringStream` —— 仓颉不支持全限定类型引用，必须 import。

### D2：`IoUringFuture.init` 放宽为 `public`，不新增工厂

- 理由：类本身已是 `public`，且 README 已把它列为公开 API；构造器缺 `public` 是遗漏而非有意封装。放宽可见性是纯增量（source/binary 兼容方向安全），既有包内调用不受影响。
- 备选：加 `public static func from(promise: IoUringPromise<T>): IoUringFuture<T>` —— 多一个 API 面、与 README 既有写法不一致，且测试仍需改写法，放弃。
- 备选：测试改用包内可见的辅助入口 —— 需要为测试开生产代码后门，更差，放弃。

### D3：先红后绿，逐个修正

先用失败基线（当前 24 错误）作为 Red 证据，然后按任务顺序改；每步重跑 `cjpm test` 观察错误数下降。编译全绿后若出现运行时失败用例，按 TDD 处理：先用最小改动确认失败原因，再修实现或用例（以 `README` 与 `doc/` 记录的既有设计意图为准，不改设计语义）。

## Risks / Trade-offs

- [修完编译后暴露运行时失败，可能需要改动实现] → 以「不改公开签名语义」为边界；若失败源于用例期望与设计不符，优先修正用例并记录理由；若确属实现缺陷，走 apply 中的 TDD 循环，并在 verify 前向用户说明。
- [io_uring 在受限内核 / 容器里行为不稳定，导致用例抖动] → 只在本机 WSL 内核验证（已知可跑）；抖动用例单独定位，不靠放宽断言掩盖。
- [`IoUringFuture` 构造器公开后，外部可能误用未注册的 Promise] → 文档注明「Promise 需先注册到 ring 的完成槽位」；不在构造器里加强制校验（会改变既有语义）。
