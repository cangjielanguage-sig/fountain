## MODIFIED Requirements

### Requirement: 统一调用包装

调用 SHALL 严格按六步执行：参数个数校验 → 封送 → 三态收尾 → 解包 → 返回类型一致性校验 → 返回与清理；纯字节码形态与机器码形态 SHALL 使用同一接口、同一行为。闭包包装实例（桥内部构造，绑定「单元 + `JitClosureId`」）的 `call<T>` SHALL 发起新桥调用（新 ctx，`locals[0]` = 闭包句柄），结果/错误码/site 与直接 `CALL_CLOSURE` 逐位一致；卸载后调用 → 19（site=−1）。`close()` SHALL 为唯一释放路径（提升组计数 −1、归零释放、幂等）；对入口实例 `close` → 19（site=−1）、`isClosed` 恒 false。

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

- **WHEN** 对闭包包装实例重复 `close`，或对入口实例调用 `close`
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

- **WHEN** 两线程各自 `callForFn` 取闭包包装并各自 `close`
- **THEN** 两侧提升组互不干扰，另一侧包装仍可调用

## ADDED Requirements

### Requirement: 调用入口与选项

`invoke<T>(args, options: CallContext)` SHALL 为唯一带选项入口；`call<T>(args)` SHALL 等价于 `invoke<T>(args, CallContext())`。SHALL NOT 引入 `tryInvoke`——错误语义与 `call` 完全一致（>0 抛 `JitException`、−2 抛 `InterruptedException`）。

`options.deadline` SHALL 在调用开始前换算为绝对时刻写入运行期，并在 `finally` 恢复调用前的值（重入安全）；`None` SHALL 表示无期限。`CallContext` SHALL 只承载**调用级**选项；编译期策略（产物版本、严格浮点）SHALL NOT 出现在其中。`callForFn<Fn>` SHALL 与 `call` 一样串行化：整段（调用 + 取提升组 + 构造包装）在本单元调用锁内完成，`lastClosureGroup` SHALL NOT 跨调用残留。

#### Scenario: 两入口三态一致

- **WHEN** 分别用 `call` 与 `invoke(args, CallContext())` 调用同一单元的正常值、>0 错误码、−2 三条出口
- **THEN** 结果、错误码与 site 逐位相同

#### Scenario: lastClosureGroup 不残留

- **WHEN** 连续两次 `callForFn`（两次之间不 close）
- **THEN** 第二次取到的提升组与第一次互不相同，且第一次的包装仍可调用

### Requirement: 编译选项的版本与严格浮点

`CompileOptions.verMajor` SHALL 决定源码产物的字节码主版本，缺省为 `Version.LATEST`；不受支持的值 SHALL 在 `compile` 时以 `SourceCompileException` 拒绝，SHALL NOT 落到运行期错误槽。

`CompileOptions.strictFp` SHALL 决定 `Float64` 的 `/` 的发射形态：`false` → `FDIV`（÷0 得 ±Inf，IEEE）；`true` → `FDIV_CHK`（÷0 → 错误码 1）。缓存键 SHALL 同时包含主版本与严格浮点标记，同源不同配置 SHALL 产出独立单元。

`CallContext` SHALL NOT 包含 `literalCopy`：字面量是编译期常量，桥层不存在「深拷贝字面量」的时机，该字段自始无消费点。

#### Scenario: 版本选项生效

- **WHEN** 以 `verMajor = Version.M2_MAJOR` 编译一段含 `Any` 的源码
- **THEN** `compile` 抛 `SourceCompileException`（局部槽类型码 15 非法）；改用 `Version.LATEST` 后编译通过

#### Scenario: 严格浮点开与关

- **WHEN** 分别以 `strictFp = false` 与 `true` 编译 `{ x: Float64 => 1.0 / x }` 并按 `x = 0.0` 调用
- **THEN** 前者返回 `+Inf`（错误码 0）；后者以 1（`DIV_ZERO`）失败；两者产物里的除法 opcode 分别为 `FDIV` 与 `FDIV_CHK`

#### Scenario: 同源不同配置不串缓存

- **WHEN** 同一源码先用 `strictFp = false` 编译，再用 `true` 编译
- **THEN** 得到两个不同单元，各自的除法 opcode 与调用行为互不影响
