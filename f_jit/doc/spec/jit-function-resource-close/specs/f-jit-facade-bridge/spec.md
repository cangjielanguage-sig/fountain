## ADDED Requirements

### Requirement: 资源生命周期（Resource）

`JitFunction` SHALL 实现 `std.core.Resource`：`close(): Unit` 与 `isClosed(): Bool`。入口实例的 `close` SHALL 卸载单元（终态、逐出缓存、级联释放逃逸闭包）；闭包包装实例的 `close` SHALL 只释放本闭包（提升组归零、单元继续可用）。另 SHALL 提供 `close(timeoutMs: Int64): Bool`：先排空在飞调用，超时回退为可用并返回 `false`；`close()` SHALL 不等待（等价 `close(0)` 丢弃结果）。`isClosed()` SHALL 对入口实例返回「单元已卸载」、对包装实例返回「本闭包已释放」（含级联）；重复 `close` SHALL 幂等。

#### Scenario: 入口实例关闭

- **WHEN** 对入口实例调用 `close()` 或 `close(timeoutMs)`
- **THEN** 单元进入终态、逐出编译缓存、级联释放全部逃逸闭包；`isClosed()` 为真；此后调用以 19 失败

#### Scenario: 包装实例关闭

- **WHEN** 对闭包包装实例调用 `close()`
- **THEN** 该闭包提升组归零释放、`isClosed()` 为真、返回 Unit；单元仍可调用、缓存不逐出

#### Scenario: 关闭先排空本闭包的在飞调用

- **WHEN** 该闭包的一次调用尚未返回时调用 `close(0)`
- **THEN** 返回 `false`，闭包保持可用；该调用返回后再 `close()` 成功

#### Scenario: 以 Resource 接口使用

- **WHEN** 把入口实例或包装实例赋给 `Resource` 并按接口调用 `close()` / `isClosed()`
- **THEN** 行为与直接调用一致；重复 `close()` 幂等

## MODIFIED Requirements

### Requirement: 统一调用包装

调用 SHALL 严格按六步执行：参数个数校验 → 封送 → 三态收尾 → 解包 → 返回类型一致性校验 → 返回与清理；纯字节码形态与机器码形态 SHALL 使用同一接口、同一行为。闭包包装实例（桥内部构造，绑定「单元 + `JitClosureId`」）的 `call<T>` SHALL 发起新桥调用（新 ctx，`locals[0]` = 闭包句柄），结果/错误码/site 与直接 `CALL_CLOSURE` 逐位一致；单元已关闭后调用 → 19（site=−1）。

#### Scenario: 契约错误统一码

- **WHEN** 参数个数不符、元素类型不符、或请求类型与返回类型不符
- **THEN** 一律抛契约类错误，站点为 -1，源位置为空

#### Scenario: 两形态同接口同行为

- **WHEN** 同源同参分别调用机器码形态与纯字节码形态产物
- **THEN** 结果、错误码、站点与报告文本逐位一致

#### Scenario: 闭包包装调用

- **WHEN** 在 `callForFn` 返回的 `JitFunction` 上调用 `call<T>`（重入 ≥3）
- **THEN** 新 ctx、闭包帧、结果/错误码/site 与直接 `CALL_CLOSURE` 逐位一致

#### Scenario: 卸载弱语义

- **WHEN** 闭包逃逸后关闭其单元，再调用包装实例
- **THEN** 以 19 失败（site=-1）；闭包不阻止关闭

#### Scenario: deadline 到期可中断

- **WHEN** 以 `deadline` 为过去时刻调用一个含 `LOOP_BACK` 的函数
- **THEN** 在安全点返回 −2 并抛 `InterruptedException`

#### Scenario: 重入不串 deadline

- **WHEN** 外层带 deadline 调用，内层闭包再以无期限调用 JIT
- **THEN** 内层不受外层 deadline 影响；内层返回后外层 deadline 恢复生效
