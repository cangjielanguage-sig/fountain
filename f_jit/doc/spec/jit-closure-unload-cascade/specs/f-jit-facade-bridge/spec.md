## ADDED Requirements

### Requirement: 统一调用包装

调用 SHALL 严格按六步执行：参数个数校验 → 封送 → 三态收尾 → 解包 → 返回类型一致性校验 → 返回与清理；纯字节码形态与机器码形态 SHALL 使用同一接口、同一行为。闭包包装实例（桥内部构造，绑定「单元 + `JitClosureId`」）的 `call<T>` SHALL 发起新桥调用（新 ctx，`locals[0]` = 闭包句柄），结果/错误码/site 与直接 `CALL_CLOSURE` 逐位一致；单元已卸载后调用 → 19（site=−1）。

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

- **WHEN** 闭包逃逸后卸载其单元，再调用包装实例
- **THEN** 以 19 失败（site=-1）；闭包不阻止卸载

#### Scenario: deadline 到期可中断

- **WHEN** 以 `deadline` 为过去时刻调用一个含 `LOOP_BACK` 的函数
- **THEN** 在安全点返回 −2 并抛 `InterruptedException`

#### Scenario: 重入不串 deadline

- **WHEN** 外层带 deadline 调用，内层闭包再以无期限调用 JIT
- **THEN** 内层不受外层 deadline 影响；内层返回后外层 deadline 恢复生效

### Requirement: 逃逸闭包的释放协议

逃逸闭包（`callForFn` 返回的包装实例）的唯一释放入口 SHALL 为 `unload()`：只释放该函数值的提升组（计数 −1、归零释放、幂等），单元与其编译缓存不受影响；`unloadFn()` SHALL 为内部私有实现。释放 SHALL 先排空该闭包自身的在飞调用再归还提升组：卸载中拒绝新调用，`timeoutMs` 内未排空 SHALL 回退为可用并返回 `false`；已释放后重复卸载 SHALL 返回 `true`。`isClosed` SHALL 描述包装实例自身是否已释放，非包装实例恒 `false`。

#### Scenario: 包装实例释放协议

- **WHEN** 在闭包包装实例上调用 `unload()`
- **THEN** 该实例的提升组归零释放、`isClosed` 与 `isUnloaded()` 转真、返回 `true`；单元仍可调用、编译缓存不逐出；重复 `unload()` 幂等且返回 `true`

#### Scenario: 释放先排空本闭包的在飞调用

- **WHEN** 该闭包的一次调用尚未返回时调用 `unload(0)`
- **THEN** 返回 `false`，闭包保持可用（`isClosed` 为假、提升组未归还）；该调用返回后再 `unload()` 成功

#### Scenario: 释放后调用

- **WHEN** 包装实例 `unload()` 之后再调用它
- **THEN** 以 19 失败（site=-1）

#### Scenario: callForFn 并发

- **WHEN** 两线程各自 `callForFn` 取闭包包装并各自 `unload()`
- **THEN** 两侧提升组互不干扰，另一侧包装仍可调用

### Requirement: 卸载状态机与资产清点

卸载 SHALL 经历「可用 → 卸载中（拒绝新调用、活跃调用照常完成）→ 已卸载（终态）」，超时未排空 SHALL 恢复可用；已卸载后调用 SHALL 以契约类错误失败；重复卸载 SHALL 幂等；卸载进入终态时 SHALL 从编译缓存逐出该单元；卸载期间到达的同键编译 SHALL 等待卸载完成后按未命中重新编译并产出新句柄。进入终态时 SHALL **先**级联释放该单元登记在册的全部逃逸闭包（**含尚未承接为包装实例的提升组**；每个逃逸闭包置为已释放、其提升组归零释放），**再**释放代码内存/常量与逐出编译缓存；超时回退路径 SHALL NOT 释放任何闭包。

#### Scenario: 活跃调用排空

- **WHEN** 在长调用执行中发起卸载（带超时或阻塞）
- **THEN** 进行中的调用结果逐位正确且不被注入中断；排空后进入终态

#### Scenario: 与编译交错

- **WHEN** 卸载与同指纹编译并发交错
- **THEN** 编译在卸载完成后按未命中重编，返回新句柄，绝不返回已卸载的旧句柄；旧句柄调用以契约类错误失败

#### Scenario: 卸载逐出缓存

- **WHEN** 编译一个单元、`unload()` 成功后再次编译同一份源码
- **THEN** 缓存未命中并重新执行管线，返回新句柄；旧句柄调用仍以 19 失败

#### Scenario: 单元卸载级联释放逃逸闭包

- **WHEN** 单元产出的逃逸闭包未显式释放，宿主直接对该单元 `unload()` 且成功进入终态
- **THEN** 该单元登记的全部逃逸闭包转为已释放（包装实例 `isClosed` 为真），其提升组占用的句柄全部归还（`HandleTable` 活跃计数回到产出前水位），被捕获的宿主对象可被回收

#### Scenario: 未承接的逃逸闭包随单元卸载释放

- **WHEN** 以 `call<JitClosureId>` 取得闭包而未经 `callForFn` 承接，随后对单元 `unload()` 成功进入终态
- **THEN** 该闭包的提升组同样归零释放，不存在「无人承接即无人释放」的组

#### Scenario: 超时回退不级联

- **WHEN** 存在活跃调用导致 `unload(timeoutMs)` 排空超时并返回 `false`
- **THEN** 单元恢复可用，登记在册的闭包既未释放也未被摘除，包装实例仍可调用

#### Scenario: 级联后重复释放幂等

- **WHEN** 单元卸载已级联释放，宿主再对包装实例调用 `unload()`
- **THEN** 返回 `true` 且不重复释放提升组；其它单元的包装实例不受影响
