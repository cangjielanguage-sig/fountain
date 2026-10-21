# Spec Delta

## Purpose

`compiler` 包把「源入口 lambda 文本」编译为 `.fbc`：词法 → 语法 → 名字解析 → 明确赋值 → 降低 → 汇编校验 → 容器组装，所有编译期失败一律以编译期异常给出，不占用运行期错误码。M2 增量增加宿主互操作的类型记法、类注册表视图、CALL_HOST / 成员访问 / 构造降低，以及逃逸闭包捕获白名单。

## MODIFIED Requirements

### Requirement: 源入口语法与名字解析

解析器 SHALL 接受 lambda 源入口（形参带类型注解、`=>` 必需、尾表达式即返回值），拒绝具名/默认参数与缺失箭头；类型注解 SHALL 接受内建类型、宿主闭包函数类型 `(T1, T2) -> R` 与已注册类名（opaque 形参/局部/返回），未注册类名与禁高阶签名 SHALL 编译期拒绝。调用点名字 SHALL 按「自递归 → 已注册预定义函数 → HostClosure 形参/局部（静态类型 13） → 未定义」顺序解析；HostClosure 形参/局部与已注册 user helper **同名** SHALL 编译期拒绝（禁止静默择一）。

#### Scenario: 未注册函数诊断

- **WHEN** 调用一个未注册的标识符
- **THEN** 编译期失败，消息含名字、位置与已注册清单

#### Scenario: HostClosure 静态判定

- **WHEN** 源码声明 `fn: (Int64) -> Bool` 并在函数体内调用 `fn(1)`
- **THEN** 名字解析命中 HostClosure 分支，降低为 `CALL_HOST 1`，不尝试 `CALL_CLOSURE` 或运行期查找

#### Scenario: 同名冲突拒绝

- **WHEN** 某 HostClosure 形参或局部与已注册 user helper 同名
- **THEN** 编译期拒绝，消息含冲突名字与位置

#### Scenario: 缺失箭头与非法形参

- **WHEN** 源码省略 `=>` 或使用具名/默认参数
- **THEN** 以对应编译期错误类别拒绝；HostClosure 形参的类型记法缺失 `->` 时同样按该类别拒绝

### Requirement: 明确赋值在编译期强制

读未赋值局部变量 SHALL 在汇编期被拒绝；循环出口不视为已赋值；分支需全部赋值才视为已赋值；空值直存句柄型槽与捕获未赋值变量同样被拒绝。M2 SHALL 把 13（HostClosure）与 14（HostObject）纳入同一句柄型规则：13 的空安全同 12，14 恒非空；14 槽不得由 `PUSH_NULL` 直存。

#### Scenario: 读未赋值拒绝

- **WHEN** 编译一段读取尚未赋值局部的源码
- **THEN** 汇编期拒绝，且零值填充不可被任何用例观察到

#### Scenario: 14 槽恒非空

- **WHEN** 把 `null` 直存到声明为注册类的 14 型局部槽
- **THEN** 编译期拒绝；13 型槽的空值判定与 12 同型

#### Scenario: 捕获未赋值变量

- **WHEN** 闭包捕获一个尚未完成明确赋值的 13/14 型变量
- **THEN** 编译期拒绝，不生成捕获快照

#### Scenario: 回边不动点

- **WHEN** 循环体在回边处才完成赋值，出口后读取该变量
- **THEN** 仍判定为未赋值并拒绝；13/14 槽沿用同一不动点判定

### Requirement: 降低产物符合规范模式

算术/比较/位运算、取余、字面值与混合提升、插值、控制流与循环、多重赋值、闭包与立即调用、自递归与尾递归、空容器构造、区间与正则操作符 SHALL 各自按规格降低模式展开，逐指令产物可断言且操作数栈平衡。M2 SHALL 增加：HostClosure 调用降低为「实参左→右入栈 → `LOADL fn`（句柄压栈底）→ `CALL_HOST u8 argc` → 自动 `CHECK_ERR`」；成员访问糖按降级表降低；构造 `C(args...)` 降低为 `CALL_HELPER <ctor-user-hid>`；14 型实参/返回/链内传参按签名静态校验；静态成员不参与语法糖。

#### Scenario: CALL_HOST 降低

- **WHEN** 编译 `fn(a1, a2)` 且 `fn` 声明为 13 型
- **THEN** 产物依次为 `a1`、`a2` 的求值指令、`LOADL fn`、`CALL_HOST 2`、`CHECK_ERR`

#### Scenario: 求值顺序

- **WHEN** 编译 `u.m(a1, a2)` 与 `u.f = v`
- **THEN** 前者求值顺序为 `u → a1 → a2`，后者为 `u → v`；副作用顺序可用记录型 user helper 断言

#### Scenario: 构造结果类型

- **WHEN** 编译 `User(addr).save()` 或 `User().name`
- **THEN** 构造结果携带 `User` 的静态类知识，可直接进入成员链；每层类型由注册表/签名提供

#### Scenario: 取余仅整型

- **WHEN** 对整型求余与对浮点/十进制/混合类型求余
- **THEN** 前者降低为整型求余指令，后者编译期拒绝；符号四象限与除零边界与规格一致

#### Scenario: 小数字面值精确构造

- **WHEN** 源码出现 `0.1` 字样的小数、超大整数字面值、指数形式
- **THEN** 分别精确构造为十进制值（不经浮点中间值）、scale 为 0 的十进制、按指数换算的 scale

#### Scenario: 控制流栈平衡

- **WHEN** 编译 if 的语句用法与值用法、while、四类 for-in、break/continue
- **THEN** 语句用法以丢弃收尾且栈无残留；值用法分支类型逐位一致且必须带 else；循环回边带安全点

#### Scenario: 多重赋值先读后写

- **WHEN** 编译多元同时赋值（含交换、忽略位、右侧含可失败调用）
- **THEN** 右侧按从左到右求值、写入发生在读取之后，忽略位仍求值后丢弃

#### Scenario: 闭包与自递归三路降低

- **WHEN** 编译嵌套闭包、立即调用、值化自递归与尾位置自递归
- **THEN** 闭包生成独立目录项并带捕获快照；自递归在顶层/闭包层/值位分别走不同降低路径；尾位置展开为「实参逆序写局部 + 回边」，不发射返回指令

#### Scenario: 空容器需上下文类型

- **WHEN** 编译空列表/空映射字面值
- **THEN** 有上下文类型时降低为构造指令，无上下文类型时编译期拒绝；非空字面值仍走常量路径

### Requirement: 构建器与汇编期校验

构建器 SHALL 支持标签回填与相对偏移、在可能失败点前记录站点、为可失败调用自动追加错误检查，并在收尾时给出最大栈深与函数标志；汇编期 SHALL 执行全部既定校验，每条校验至少有一个拒绝用例。M2 SHALL 增加：`CALL_HOST` 的 argc 展开与 `[h_fn, a1..an]` 栈布局校验；含 `CALL_HOST` 或 H65 的函数 SHALL 置 `FuncEntry.flags.bit0` 并拒绝作为 deopt 源；`CALL_HOST` 在 v2 规则集下合法、v1 下仍为 `ERR_NOT_IMPL`。

#### Scenario: 缺失错误检查被拒

- **WHEN** 人为构造缺少错误检查的可失败调用序列（含 `CALL_HOST`）
- **THEN** 汇编期拒绝

#### Scenario: 变更型与去优化禁令

- **WHEN** 含 H65 调用（或 `CALL_HOST`）的函数试图走去优化路径
- **THEN** 汇编期拒绝，且函数标志的变更位被正确标记

#### Scenario: CALL_HOST 版本门槛

- **WHEN** 在 v1 规则集下汇编 `CALL_HOST`
- **THEN** 返回 `ERR_NOT_IMPL`；同一序列在 v2 规则集下通过

## ADDED Requirements

### Requirement: 类型记法解析（TypeRef）

前端 SHALL 提供 `TypeRef` 枚举，构造器为 `Builtin(UInt16)`（参数序 = code）、`HostClosureT(Array<UInt16>, UInt16)`（参数序 = params, ret）与 `HostObjectT(String)`（参数序 = className）。HostClosure 的 T/R SHALL 取自 0–8、10–11、14；9（Regex）与 12/13（函数类型）SHALL 拒绝；**禁高阶**：T/R 不得为函数类型。未注册类名 SHALL 编译期拒绝。类型注解的解析顺序 SHALL 为「内建类型 → 注册类名 → 未知=编译错误」。

#### Scenario: 三类记法解析

- **WHEN** 解析 `Int64`、`(Int64, String) -> Bool`、`User`
- **THEN** 分别得到 `Builtin(0)`、`HostClosureT([0,4], 2)`、`HostObjectT("User")`

#### Scenario: 禁高阶与 9/12/13

- **WHEN** 解析 `((Int64) -> Bool) -> Unit`、`(Regex) -> Unit` 或 T/R 为 12/13 的函数类型
- **THEN** 全部编译期拒绝，消息含不合法分量

#### Scenario: 未注册类名

- **WHEN** 解析一个未在快照中注册的类名
- **THEN** 编译期拒绝，消息含类名与「未注册」语义

### Requirement: 编译期类注册表视图

前端 SHALL 提供只读 `ClassRegistryView`，支持 `classOf`、`fieldOf`、`methodOf`、`ctorsOf`、`isRegistered`，并绑定到 `SourceCompiler` 构造时捕获的注册表快照；注册变更 SHALL NOT 影响已编译单元。字段解析 SHALL 给出 `name → index/type/mutable/typeRef`；方法解析 SHALL 给出绑定目标；构造器解析 SHALL 返回重载列表。前端 SHALL 只查注册表中该类的条目，**不做继承谱系上溯**：条目在快照中即可绑定，不在快照中（手工注册未列或不在反射覆盖面）SHALL 编译错误。

#### Scenario: 命中与未命中

- **WHEN** 查询已注册类的字段/方法/构造器与未注册类或未知成员
- **THEN** 前者返回完整条目；后者编译错误，消息含类名与成员名

#### Scenario: 快照语义

- **WHEN** 某源码编译成功后向注册表新增或修改成员
- **THEN** 已编译单元使用的视图不变；新编译单元才反映新快照

#### Scenario: 继承成员按表解析

- **WHEN** 访问一个在注册快照中没有条目、但存在于宿主继承谱系中的成员
- **THEN** 前端编译错误（不按谱系上溯）；若该成员已由反射注册入表，则正常绑定

### Requirement: 成员访问语法糖降低

前端 SHALL 支持 `u.f`（读）、`u.f = v`（写）、`u.m(a...)`（调用）三种语法糖，并分别降级为 H64、H65 与预定义函数调用 `m(u, a...)`。`.` 仅接成员标识符，仅对静态已知为某注册类的 14 型表达式合法；链式 `u.a.b` 与 `u.m().f` SHALL 合法（每层类型由注册表/签名提供）；13 型字段读后按既有闭包调用语法使用。求值顺序 SHALL 为左到右。`let` 字段写、非 HostObject 用点号、未注册类、未知成员、方法签名不匹配 SHALL 编译错误；`mutable=false` 的裸 H65 防御 SHALL 返回 19（双防线）。

#### Scenario: 糖 ≡ 手写

- **WHEN** 分别编译 `u.f` / `u.f = v` / `u.m(a)` 与等价的手写 `get_field` / `set_field` / 包装调用
- **THEN** 两者产物逐指令等价；三引擎结果、错误码与站点逐位一致

#### Scenario: 编译期拒绝集

- **WHEN** 对非 HostObject 表达式用点号、访问未注册类、未知成员、写 `let` 字段或调用签名不匹配的方法
- **THEN** 全部编译错误，消息含类名/成员名

#### Scenario: 链式与 typeRef

- **WHEN** 编译 `u.addr.city` 且 `addr` 为 `type=14, typeRef="Address"` 的字段
- **THEN** 第二层按 `Address` 的注册条目解析；`typeRef=None` 的 14 字段链式访问编译错误

### Requirement: 字节码侧构造降低

前端 SHALL 支持 `C(args...)`（`C` 为已注册类）并降级为 `CALL_HELPER <ctor-user-hid>`（构造器物化为单元私有 user helper）；实参 SHALL 从左到右求值并按注册签名静态校验；重载解析 SHALL 静态匹配，无匹配或歧义 SHALL 编译错误；14 型参数（嵌套构造 `User(Addr(...))`）SHALL 合法；构造结果类型 SHALL 为该类（14，携带具体类静态知识），可直接进入成员链。JSON 谱系类（`JsonValue` / `JsonObject` / `JsonArray` / `JsonNull`）的构造写法 SHALL 编译错误（M3 内建码、无注册构造器）。未注册类名 SHALL 编译错误；类名与已注册函数名冲突 SHALL 走注册期拒绝。

#### Scenario: 构造降级与自动检查

- **WHEN** 编译 `let u = User("a", 1)`
- **THEN** 产物为实参求值、`CALL_HELPER <ctor-user-hid>` 与自动 `CHECK_ERR`；不出现新指令或新 helper

#### Scenario: 重载与嵌套

- **WHEN** 编译 `User(Addr("x"))` 且 `User` 有多个构造器
- **THEN** 按静态类型选择唯一匹配；无匹配/歧义编译错误；嵌套构造的 14 实参合法

#### Scenario: JSON 谱系拒绝

- **WHEN** 编译 `JsonObject(...)` 或 `JsonArray(...)`
- **THEN** 编译错误，消息说明 JSON 谱系为内建类型、无注册构造器

### Requirement: 逃逸闭包捕获描述符与白名单

前端 SHALL 为每个可能跨桥返回的闭包生成**静态捕获描述符**，逐项分类为：值型捕获（恒有效）、路径 A 常量捕获（ConstTable 持有，恒有效）、路径 B 参数捕获（pin，调用结束失效）、路径 C 窗口分配捕获（窗口重置后失效）。描述符 SHALL NOT 写入 `.fbc`（无格式变更）。第 0 步（白名单版）SHALL 对含路径 B/C 捕获的逃逸闭包编译错误（消息含捕获名与来源）；第 1 步 SHALL 放开该拒绝面，并把句柄型捕获集交给提升组。`LOAD_CAP` 语义 SHALL 零变化，读到提升后的有效槽。

#### Scenario: 第 0 步白名单拒绝

- **WHEN** 一个返回闭包捕获了函数形参（路径 B）或窗口分配结果（路径 C）
- **THEN** 第 0 步编译错误，消息含捕获名与来源；值型/路径 A 捕获可逃逸

#### Scenario: 第 1 步放开

- **WHEN** 同一闭包在第 1 步编译
- **THEN** 不再编译错误；捕获描述符给出句柄型捕获集，提升组据此登记

#### Scenario: 描述符不入产物

- **WHEN** 对比第 0 步与第 1 步的 `.fbc`
- **THEN** 容器格式与段布局不变，捕获描述符不出现在任何段中

#### Scenario: LOAD_CAP 语义不变

- **WHEN** 提升后读取被捕获的句柄型槽
- **THEN** `LOAD_CAP` 读到提升后的有效槽，结果与提升前逐位一致
