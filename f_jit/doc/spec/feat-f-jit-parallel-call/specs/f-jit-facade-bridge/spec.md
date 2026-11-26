## ADDED Requirements

### Requirement: 并发调用与执行状态隔离

同一个 `JitFunction` SHALL 支持多线程并发 `call`，各次调用 SHALL 并行执行（SHALL NOT 存在进程级调用锁），结果、错误码与 site SHALL 与非并发调用逐位一致。每次调用 SHALL 独占一段窗口切片与独立的 `JitContext`。

`deadline`、函数表基址、user-helper 表栈 SHALL 为线程私有；`callForFn` 返回的闭包包装 SHALL 可跨线程调用与释放。`unload` SHALL 等待所有线程的在飞调用排空；已进入的调用 SHALL 正常完成，卸载期间的新调用 SHALL 以契约类错误失败。

#### Scenario: 同单元并发调用

- **WHEN** 4 个线程各 500 次并发调用同一单元
- **THEN** 每次结果与串行一致，句柄统计回到基线，无类型混淆

#### Scenario: 跨线程包装

- **WHEN** A 线程 `callForFn` 创建包装，B/C 线程调用，D 线程 `unloadFn`
- **THEN** 调用结果正确、释放后计数归零且旧包装以契约错误失败

#### Scenario: 并发卸载

- **WHEN** 并行调用进行中发起 `unload(timeoutMs)`
- **THEN** 在飞调用全部完成；新调用 19；未排空则返回 false 并恢复可用
