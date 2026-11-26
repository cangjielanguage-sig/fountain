# Spec Delta

## Purpose

约定 f_uring 模块对 io_uring 的异步封装对外可观察的行为：异步操作结果载体可被包外构造与等待，且模块自带可在 Linux 上执行的回归用例集。

## ADDED Requirements

### Requirement: 异步 Future 可由包外代码构造

`IoUringFuture<T>` 是公开的异步结果载体。系统 SHALL 允许模块外的调用方用 `IoUringPromise<T>` 实例构造 `IoUringFuture<T>`，并沿用既有 `get()` / `get(timeout:)` / `tryGet()` 语义读取结果。

#### Scenario: 包外构造并等待成功结果

- **WHEN** 调用方在 `fountain::f_uring` 之外的包中创建一个已注册到完成队列的 `IoUringPromise<Int32>`，并用它构造 `IoUringFuture<Int32>`
- **THEN** 该 `IoUringFuture` 构造成功
- **AND** 对应 I/O 完成后 `get()` 返回提取到的结果值
- **AND** `isCompleted()` 在完成前为 `false`、完成后为 `true`

#### Scenario: 包外代码观察到取消

- **WHEN** 包外代码对由 `IoUringPromise` 构造出的 `IoUringFuture` 所对应的 Promise 执行 `cancel()`
- **THEN** `IoUringFuture.isCancelled()` 返回 `true`
- **AND** `get()` 抛出 `IoUringException`

### Requirement: 模块测试套件可在 Linux 上通过

f_uring 模块 SHALL 提供可在 Linux（x86_64、已安装 liburing）上通过 `cjpm test` 编译并执行的回归用例集，覆盖 ring 生命周期、SQE/CQE、锁无锁组件与 `IOUringStream` 读写。

#### Scenario: 全量测试编译并执行

- **WHEN** 在 Linux 环境对 `f_uring` 模块执行 `cjpm test`
- **THEN** 测试包编译成功，无编译错误
- **AND** 全部用例执行完成且无失败用例
