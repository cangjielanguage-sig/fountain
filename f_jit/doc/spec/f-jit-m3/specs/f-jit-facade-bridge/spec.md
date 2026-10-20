# Spec Delta

## MODIFIED Requirements

### Requirement: 参数封送与返回解包表

封送 SHALL 按类型表逐行把宿主值转为字节码侧表示（不接受可选/空值、不做隐式宽化），解包 SHALL 按对应表把结果转回宿主值；句柄型返回 SHALL 走逃逸登记并在调用收尾自动回收；清理 SHALL 覆盖正常与异常全路径。M2 SHALL 增加参数行：声明类型为注册类 `C` 时接受 `C` 实例（`is C`，含子类，opaque 视图）→ `pin`（tag=11）→ cell，null → 19；声明为 HostClosure `(T1..Tn) -> R` 时接受仓颉函数值 → **`FunctionTypeInfo` 逐位验签**（14 按具体类名）→ pin（tag=10）→ cell，失败 → 19（site=-1）。解包 SHALL 增加行：`retType=12 → JitClosureId`（提升组已登记）、`retType=13 → 原样带回宿主闭包引用`、`retType=14 → get 宿主类实例引用`。包装值（`JitFunction`）SHALL NOT 直接作实参（→19），回传须由宿主包一层闭包。

M3 SHALL 增加参数行：声明类型为 `Any`（15）时接受**任意宿主值**（含仓颉闭包、注册类实例、任意对象）→ 装箱入条目（存放原生 `Any`）→ cell = 句柄，null → 19；解包 SHALL 增加行：`retType=15 → get 原生 Any 原样返回`。JSON 内建码（16–19）跨桥 SHALL 沿用 token 11 的例外行，零注册。桥的错误码映射 SHALL 覆盖 1–22（含 22 `ANY_CAST`）。

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

## ADDED Requirements

### Requirement: 转发特化的桥内接入与开关

桥 SHALL 在 `CompilePipeline` 暴露特化开关（强制通用 / 强制特化），默认开启特化；开关只影响性能路径，SHALL NOT 影响任何可观察语义。H63 SHALL 在 fetch 后优先使用条目已绑定的 `SignaturePlan`；plan 缺失或构建失败时 SHALL 回退通用流程并记诊断，不得报错。两条路径的结果、错误码（含 21/99）、site 与窗口账目 SHALL 逐位一致。

#### Scenario: 双路径对拍

- **WHEN** 以强制通用与强制特化分别执行 T30–T36 全部用例
- **THEN** 每组的结果、错误码、site、窗口账目逐位一致

#### Scenario: 冷路径回退

- **WHEN** 人为令 plan 构建失败（注入诊断）后调用 H63
- **THEN** 调用仍成功、结果与通用流程一致；仅多一条诊断记录

#### Scenario: 开关不改变语义

- **WHEN** 在两种开关状态下跑同一含异常宿主回调的用例
- **THEN** 错误码与 site 完全相同（21 + CALL_HOST 偏移）
