# Spec Mirror — f-jit-facade-bridge（M2.2 增量）

> 只收录 `f-jit-m2.2` 改动的 requirement；其余 capability 的验收仍由
> `check_scenarios.sh m2` / `m1` 承担。与主规范的差异仅限本变更的改动本身。

### Requirement: 统一调用包装

调用 SHALL 严格按六步执行：参数个数校验 → 封送 → 三态收尾 → 解包 → 返回类型一致性校验 → 返回与清理；纯字节码形态与机器码形态 SHALL 使用同一接口、同一行为。M2 SHALL 让 `JitFunction` 同时承载两种绑定的调用语义：入口实例按 M1 六步不变；**闭包包装实例**（桥内部构造，绑定「单元 + `JitClosureId`」）的 `call<T>` SHALL 发起新桥调用（新 ctx，`locals[0]` = 闭包句柄 → 闭包帧格式），结果/错误码/site 与直接 `CALL_CLOSURE` 逐位一致；卸载后调用 → 19（site=-1）。`close()` SHALL 为唯一释放路径（提升组计数 −1、归零释放、幂等）；非闭包包装实例 `close` → 19（site=-1）、`isClosed` 恒 false。`callForFn<Fn>(args)` SHALL 调用单元并返回承接其返回闭包的 `JitFunction`（`Fn` 为返回闭包的函数类型，零运行期判定），实参面与 `call<T>` 一致。

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


## ADDED Requirements

### Requirement: 宿主闭包调用的类型化快速路径

`CALL_HOST` 的转发器（H63）SHALL 接受两条调用路径：句柄条目内已缓存**类型化适配器**时直接调用它（静态类型调用，不经反射）；否则走 `FunctionTypeInfo.apply` 反射。适配器 SHALL 由宿主在编译期用具体函数类型登记（`JitHost.registerSignature<F>`），按「形参码序列 + 逐位类名 + 返回码 + 返回类名」的结构匹配。未登记 SHALL 与 M1/M2 行为完全一致。查找 SHALL 发生在句柄条目创建（pin）时，调用期零查找；逐参 `cell → 仓颉值` 转换 SHALL 由两条路径共用同一实现。适配器抛出的宿主异常 SHALL 与反射路径同口径转 21 + cause。

#### Scenario: 登记后走适配器

- **WHEN** 宿主登记 `(Int64) -> Int64` 的适配器，JIT 单元以该签名调用传入的宿主闭包
- **THEN** 命中适配器（其返回值带适配器特有的加工），不经过 `FunctionTypeInfo.apply`

#### Scenario: 未登记仍走反射

- **WHEN** 同一单元、同一闭包，但签名未登记
- **THEN** 走反射路径，返回闭包自身的结果，行为与 M2 一致

#### Scenario: 签名结构不同不命中

- **WHEN** 已登记 `(Int64) -> Int64`，而调用点签名是 `(Int64, Int64) -> Int64`
- **THEN** 不命中，走反射；不得按「元数更少」之类的近似规则误配

#### Scenario: 回调循环有收益

- **WHEN** 一次 JIT 调用内部循环回调宿主闭包 5 万次，分别在有/无适配器下计时
- **THEN** 适配器路径显著更快（回归门禁 ≥1.3×）

