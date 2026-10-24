## MODIFIED Requirements

### Requirement: 统一调用包装

调用 SHALL 严格按六步执行：参数个数校验 → 封送 → 三态收尾 → 解包 → 返回类型一致性校验 → 返回与清理；纯字节码形态与机器码形态 SHALL 使用同一接口、同一行为。闭包包装实例（桥内部构造，绑定「单元 + `JitClosureId`」）的 `call<T>` SHALL 发起新桥调用（新 ctx，`locals[0]` = 闭包句柄），结果/错误码/site 与直接 `CALL_CLOSURE` 逐位一致；卸载后调用 → 19（site=−1）。`unloadFn()` SHALL 为闭包包装的唯一释放路径（提升组计数 −1、归零释放、幂等）；对入口实例 `unloadFn` → 19（site=−1）、`isClosed` 恒 false。

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

- **WHEN** 对闭包包装实例重复 `unloadFn`，或对入口实例调用 `unloadFn`
- **THEN** 前者幂等且归零释放、`isClosed` 转真；后者 19（site=-1）且 `isClosed=false`

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

- **WHEN** 两线程各自 `callForFn` 取闭包包装并各自 `unloadFn`
- **THEN** 两侧提升组互不干扰，另一侧包装仍可调用

### Requirement: 卸载状态机与资产清点

卸载 SHALL 经历「可用 → 卸载中（拒绝新调用、活跃调用照常完成）→ 已卸载（终态）」，超时未排空 SHALL 恢复可用；已卸载后调用 SHALL 以契约类错误失败；重复卸载 SHALL 幂等；卸载进入终态时 SHALL 从编译缓存逐出该单元；卸载期间到达的同键编译 SHALL 等待卸载完成后按未命中重新编译并产出新句柄。

#### Scenario: 活跃调用排空

- **WHEN** 在长调用执行中发起卸载（带超时或阻塞）
- **THEN** 进行中的调用结果逐位正确且不被注入中断；排空后进入终态

#### Scenario: 与编译交错

- **WHEN** 卸载与同指纹编译并发交错
- **THEN** 编译在卸载完成后按未命中重编，返回新句柄，绝不返回已卸载的旧句柄；旧句柄调用以契约类错误失败

#### Scenario: 卸载逐出缓存

- **WHEN** 编译一个单元、`unload()` 成功后再次编译同一份源码
- **THEN** 缓存未命中并重新执行管线，返回新句柄；旧句柄调用仍以 19 失败
