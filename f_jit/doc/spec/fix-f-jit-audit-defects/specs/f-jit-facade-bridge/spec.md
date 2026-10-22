# Spec Delta

## MODIFIED Requirements

### Requirement: 参数封送与返回解包表

封送 SHALL 按类型表逐行把宿主值转为字节码侧表示（不接受可选/空值、不做隐式宽化），解包 SHALL 按对应表把结果转回宿主值；句柄型返回 SHALL 走逃逸登记并在调用收尾自动回收；清理 SHALL 覆盖正常与异常全路径。M2 SHALL 增加参数行：声明类型为注册类 `C` 时接受 `C` 实例（`is C`，含子类，opaque 视图）→ `pin`（tag=11）→ cell，null → 19；声明为 HostClosure `(T1..Tn) -> R` 时接受仓颉函数值 → **`FunctionTypeInfo` 逐位验签**（14 按具体类名）→ pin（tag=10）→ cell，失败 → 19（site=-1）。解包 SHALL 增加行：`retType=12 → JitClosureId`（提升组已登记）、`retType=13 → 原样带回宿主闭包引用`、`retType=14 → get 宿主类实例引用`。包装值（`JitFunction`）SHALL NOT 直接作实参（→19），回传须由宿主包一层闭包。

M3 SHALL 增加参数行：声明类型为 `Any`（15）时接受**任意宿主值**（含仓颉闭包、注册类实例、任意对象）→ 装箱入条目（存放原生 `Any`）→ cell = 句柄，null → 19；解包 SHALL 增加行：`retType=15 → get 原生 Any 原样返回`。JSON 内建码（16–19）跨桥 SHALL 沿用 token 11 的例外行，零注册。桥的错误码映射 SHALL 覆盖 1–22（含 22 `ANY_CAST`）。

M3.1 SHALL 补齐**宿主可达面**：解包 SHALL 覆盖 0–19 的全部类型码——值型 0–3 直返、4–11 走逃逸取回、12 走闭包提升组、13 取回宿主闭包引用、14 走 tag 11 取回、**15 逃逸后拆盒交还原生 `Any`**、**16–19 按 tag 11 例外行取回 JSON 节点**。`call<T>` 的 `T` 到类型码的映射 SHALL 与解包表逐行一致：`Any → 15`、`JsonValue/JsonObject/JsonArray/JsonNull → 16/17/18/19`，SHALL NOT 因缺少映射而以 19（`CALL_CONTRACT`）拒绝调用。**逃逸槽的归还条件 SHALL 覆盖 15 与 16–19**（与 4–14 同一条尾段），SHALL NOT 只对 4–14 归还。

#### Scenario: 注册类实参

- **WHEN** 以 `User` 实例（含其子类实例）调用声明为 `User` 形参的单元
- **THEN** 实参以 tag=11 pin 进入；同一对象在闭包内引用与返回值带回时身份相同；null 或非 `User` 实例 → 19

#### Scenario: HostClosure 实参

- **WHEN** 以合法仓颉闭包调用声明为 `(Int64) -> Bool` 的形参
- **THEN** `FunctionTypeInfo` 验签通过，pin 为 tag=10；非函数值/签名不符 → 19（site=-1）；14 的具体类名不符同样 → 19

#### Scenario: 解包三行

- **WHEN** 单元分别返回 12/13/14 型值
- **THEN** 12 解包为 `JitClosureId`（已提升）、13 原样返回宿主闭包引用、14 返回宿主类实例引用；三者均零拷贝

#### Scenario: 包装值不作实参

- **WHEN** 把 `callForFn` 或包装 `JitFunction` 直接放入 `args`
- **THEN** 以 19 失败；宿主改包一层闭包后可正常传入

#### Scenario: 全类型行可断言

- **WHEN** 以各类型（整型、浮点、布尔、字符串、十进制、日期时间、时长、区间、正则、列表、映射，以及 M2 新增的宿主闭包、宿主对象引用与闭包返回值）传参与返回
- **THEN** 往返值逐位一致；类型不符时以契约类错误失败（验签失败为 19）

#### Scenario: Any 实参

- **WHEN** 分别以 Int64、String、注册类实例、仓颉闭包、JSON 句柄调用声明为 `Any` 形参的单元
- **THEN** 五者均装箱为 tag=12 的盒句柄进入；单元内可持有并原样返回；null → 19

#### Scenario: Any 返回

- **WHEN** 单元返回 `Any` 型值
- **THEN** 宿主侧 `get` 得到原生仓颉 `Any`，引用型保持同一对象身份，零拷贝

#### Scenario: 集合外类型可持有转发

- **WHEN** 宿主传入一个不在可转集内类型的值（如函数值），单元内只持有并返回
- **THEN** 往返成功；对其做 `is` 恒 false，做 `as` 以 22 失败——不构成逃逸通道

#### Scenario: `call<Any>` 可达

- **WHEN** 单元返回 `Any`，宿主以 `call<Any>` 调用
- **THEN** 拿回原生对象（不是盒句柄），身份与字节码世界内引用一致

#### Scenario: JSON 节点跨桥

- **WHEN** 单元返回 `JsonObject` / `JsonArray` / `JsonNull`，宿主以对应 `T` 调用
- **THEN** 三者分别取回具体节点对象；`T` 与返回码不符时仍为 19

#### Scenario: 15/16–19 行不再不可达

- **WHEN** 逐个以 0–19 的 `T` 声明的适配器做一次映射断言
- **THEN** 每个 `T` 的 `unboxCode` 与解包表行号一致，没有「表里有行但 `T` 映射不出」的类型码

#### Scenario: 逃逸槽按返回码归还

- **WHEN** 连续 1000 次调用分别返回 15 与 16–19，宿主每次取回后结束调用
- **THEN** `windowUsed()` 与句柄表长度不随次数增长（15/16–19 的逃逸槽与 4–14 同样归还）

### Requirement: 三态收尾与异常转换

收尾 SHALL 按错误槽取值分派：成功则解包返回；去优化标记则在解释器上透明重跑且结果与直接解释一致；中断则抛出中断异常；正值错误码则抛出带原错误码、原站点与报告的运行期异常；契约类错误站点为 -1；非预期异常一律兜底为防御错误码，不逃逸其它异常类型。

DEOPT（−1）的透明重放 SHALL 在重放前复位错误槽（`errCode = 0`，并清除由 DEOPT 占用的 `site`/末帧残留），重放结束后 SHALL **重新读取**错误槽并分派：`0` → 值路径；`-2` → `InterruptedException`；`>0` → 按原码与原 `site` 抛 `JitException`。重放过程中抛出的 `JitException` / `InterruptedException` SHALL 原样透传；其余异常 SHALL 兜底 99。

#### Scenario: 去优化透明

- **WHEN** 机器码路径返回去优化标记
- **THEN** 自动以解释器重跑并返回，结果与错误码对调用方与直接解释执行完全一样

#### Scenario: 错误码与站点透传

- **WHEN** 执行产生某正值错误码
- **THEN** 抛出的异常携带同一错误码与同一站点，报告含源码行与变量清单

#### Scenario: 重放成功不再被误判

- **WHEN** 触发 DEOPT 后重放一个必然成功的函数
- **THEN** 宿主拿到正确返回值，且 `errCode` 为 0

#### Scenario: 重放中途失败

- **WHEN** 重放体内发生 `DIV_ZERO`（4）
- **THEN** 宿主收到 `JitException(4)`，不会把中间 cell 当返回值

#### Scenario: 重放中途被中断

- **WHEN** 重放体内 `interrupt_poll` 检测到 deadline 到期
- **THEN** 宿主收到 `InterruptedException`

#### Scenario: 兜底 99 不变

- **WHEN** 重放抛出非 `JitException` 的宿主异常
- **THEN** 仍为 `JIT_PANIC(99)`、`site = -1`、`cause` 保留

### Requirement: 统一调用包装

调用 SHALL 严格按六步执行：参数个数校验 → 封送 → 三态收尾 → 解包 → 返回类型一致性校验 → 返回与清理；纯字节码形态与机器码形态 SHALL 使用同一接口、同一行为。M2 SHALL 让 `JitFunction` 同时承载两种绑定的调用语义：入口实例按 M1 六步不变；**闭包包装实例**（桥内部构造，绑定「单元 + `JitClosureId`」）的 `call<T>` SHALL 发起新桥调用（新 ctx，`locals[0]` = 闭包句柄 → 闭包帧格式），结果/错误码/site 与直接 `CALL_CLOSURE` 逐位一致；卸载后调用 → 19（site=-1）。`close()` SHALL 为唯一释放路径（提升组计数 −1、归零释放、幂等）；非闭包包装实例 `close` → 19（site=-1）、`isClosed` 恒 false。`callForFn<Fn>(args)` SHALL 调用单元并返回承接其返回闭包的 `JitFunction`（`Fn` 为返回闭包的函数类型，零运行期判定），实参面与 `call<T>` 一致。

M3.1 SHALL 提供带调用选项的入口 `invoke<T>(args, options: CallContext)`；`call<T>(args)` SHALL 等价于 `invoke<T>(args, CallContext())`。SHALL NOT 引入 `tryInvoke`——错误语义与 `call` 完全一致（>0 抛 `JitException`、−2 抛中断）。`options.deadline` SHALL 在调用开始前换算为绝对时刻写入运行期，并在 `finally` 恢复调用前的值（重入安全）；`None` SHALL 表示无期限。`options.strictFp` / `options.literalCopy` 的实际生效面 SHALL 与文档口径一致（要么接线，要么显式标注未接线）。

`callForFn<Fn>` SHALL 与 `call` 一样串行化：整段（调用 + 取提升组 + 构造包装）在本单元调用锁内完成，`lastClosureGroup` SHALL NOT 跨调用残留。

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
- **THEN** 在安全点返回 −2 并抛 `InterruptedException`（当前实现不可达，本变更后必须可达）

#### Scenario: 重入不串 deadline

- **WHEN** 外层带 deadline 调用，内层闭包再以无期限调用 JIT
- **THEN** 内层不受外层 deadline 影响；内层返回后外层 deadline 恢复生效

#### Scenario: callForFn 并发

- **WHEN** 两线程各自 `callForFn` 取闭包包装并各自 `close`
- **THEN** 两侧提升组互不干扰，另一侧包装仍可调用
