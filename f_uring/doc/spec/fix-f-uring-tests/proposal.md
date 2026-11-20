# Proposal

## Why

`f_uring` 模块的 `cjpm test` 当前**无法编译**：整个测试包 24 个编译错误（23 个 `undeclared identifier 'IOUringStream'` + 1 个 `no matching constructor for call 'IoUringFuture'`），测试套件一个用例都跑不起来。原因是最近一次演进把 `IOUringStream` 从 `fountain::f_uring` 根包对外暴露、并新增 `f_io.IOStream` 依赖后，测试文件没有同步补上根包导入；同时 `IoUringFuture` 的构造器仍是包内可见，跨包的测试代码无法构造它。测试不可运行意味着该模块的 io_uring 封装没有任何回归保护。

## What Changes

- 在 `src/tests/` 下引用 `IOUringStream` 的两个测试文件补上 `import fountain::f_uring.*`（`iouring_stream_test.cj`、`iouring_stream_perf_test.cj`）；`iouring_stream_read_micro_perf_test.cj` 只用底层 `IoUring`，不需要该导入。
- 把 `IoUringFuture<T>` 的构造器 `init(promise:)` 从包内可见放宽为 `public`，使 README 已声明的 `public class IoUringFuture` 在包外真正可构造（**可见性放宽，非破坏性变更**）。
- 编译通过后跑通 `cjpm test` 全量用例，修复由此暴露的运行时失败（若有），保证测试套件可重复通过。
- 同步 README（中英成对）中 `IoUringFuture` 的构造方式说明。

不改动任何既有公开签名、不改 `cjpm.toml` 依赖结构、不引入新依赖。

## Capabilities

### New Capabilities

- `uring-async-io`: f_uring 模块对 io_uring 的异步封装契约，包含异步操作结果载体（`IoUringPromise` / `IoUringFuture`）的公开可用性与结果等待语义。

### Modified Capabilities

（无。仓库现有 `openspec/specs/` 下的能力与本模块无关。）

## Impact

- 代码：`f_uring/src/base/uring_future.cj`（构造器可见性）、`f_uring/src/tests/*.cj`（导入与用例修正）。
- API：`IoUringFuture` 新增公开构造器；既有签名与语义不变，调用方无需改动。
- 文档：`f_uring/README.md`、`f_uring/README_en.md`。
- 构建：不新增依赖；测试仍需 Linux + liburing（`-luring`），与现状一致。
