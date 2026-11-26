## MODIFIED Requirements

### Requirement: 统一调用包装

调用 SHALL 严格按六步执行：参数个数校验 → 封送 → 三态收尾 → 解包 → 返回类型一致性校验 → 返回与清理；纯字节码与机器码形态 SHALL 同接口、同行为。闭包包装实例的 `call<T>` SHALL 发起新桥调用（新 ctx、`locals[0]` = 闭包句柄），结果/错误码/site 与直接 `CALL_CLOSURE` 逐位一致；卸载后调用 → 19（site=−1）。`close(timeoutMs)` SHALL 统一释放入口与包装：包装实例释放本闭包提升组并先排空本闭包在飞调用；入口实例卸载单元（排空全部在飞调用、终态、逐出缓存）；超时 SHALL 回退可用并返回 `false`。`close()` SHALL 等价 `close(0)`；`isClosed()` SHALL 为方法。

#### Scenario: 契约错误统一码

- **WHEN** 参数个数不符、元素类型不符、或请求类型与返回类型不符
- **THEN** 一律抛契约类错误，站点为 -1，源位置为空

#### Scenario: 两形态同接口同行为

- **WHEN** 同源同参分别调用机器码形态与纯字节码形态产物
- **THEN** 结果、错误码、站点与报告文本逐位一致

#### Scenario: 闭包包装调用

- **WHEN** 在 `callForFn` 返回的 `JitFunction` 上调用 `call<T>`（重入 ≥3）
- **THEN** 新 ctx、闭包帧、结果/错误码/site 与直接 `CALL_CLOSURE` 逐位一致

#### Scenario: close 协议

- **WHEN** 对闭包包装实例重复 `close()`，或对入口实例调用 `close(timeoutMs)`
- **THEN** 前者幂等且归零释放、`isClosed()` 转真；后者卸载单元并在排空后进入终态（超时返回 `false` 并回退可用）

#### Scenario: 卸载弱语义

- **WHEN** 闭包逃逸后卸载其单元，再调用包装实例
- **THEN** 以 19 失败（site=-1）；闭包不阻止卸载

#### Scenario: deadline 到期可中断

- **WHEN** 以 `deadline` 为过去时刻调用一个含 `LOOP_BACK` 的函数
- **THEN** 在安全点返回 −2 并抛 `InterruptedException`

#### Scenario: 重入不串 deadline

- **WHEN** 外层带 deadline 调用，内层闭包再以无期限调用 JIT
- **THEN** 内层不受外层 deadline 影响；内层返回后外层 deadline 恢复生效

#### Scenario: callForFn 并发

- **WHEN** 两线程各自 `callForFn` 取闭包包装并各自 `close()`
- **THEN** 两侧提升组互不干扰，另一侧包装仍可调用
