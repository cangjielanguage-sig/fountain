# Spec Delta

## ADDED Requirements

### Requirement: Any 通道的声明、装箱与禁止面

源语言 SHALL 允许 `Any` 作局部变量、形参、返回值（`LocalType 15`、token 12），SHALL NOT 允许它作 HostObject 字段类型（字段注册面跳过并诊断）。装箱 SHALL 是**类型驱动**的编译期插入：源表达式类型 ≠ 15 而目标位置要求 15 时发射 `any_box(类型码, expr)`，共四类插入点——① 赋值/初始化 Any 槽；② Any 实参；③ Any 返回；④ 容器元素类型为 Any 的写入前（`LIST_APPEND`/`LIST_SET`/`LIST_INSERT`/`MAP_PUT`）。每个装箱点 SHALL 只对操作数求值一次。

`is` / `as` SHALL 按左值静态类型分派：左值静态类型为 15 → `any_is` / `any_as`（H79/H80，`typecode` 与 `aux` 以 cell 压栈）；左值非 15 → 按静态类型关系处理（上行零操作、不相容编译错误），**不发射 helper**。`as T` 的结果静态类型 SHALL 为 `T`，可继续参与 T 的全部既有运算。目标不在可转集（含 `as Closure`、"任意 HostObject"）SHALL 编译错误。

禁止面（编译错误）：15 型表达式上的运算 / 比较 / 等值（含 `EQ_H`）/ 调用；`any_box` 的二次装箱；闭包存入集合（含经 Any 盒的间接路径）。**例外**：15 盒上的点号与下标 SHALL 视为 JSON 访问糖（见「JSON 访问语法糖」），不属禁止面。

#### Scenario: 四类插入点

- **WHEN** 编译 `let a: Any = 1`、`f(x)`（形参 Any）、`return x`（返回 Any）、`list.add(x)`（元素 Any）
- **THEN** 四处均发射一次 `any_box(0, …)`（类型码取自静态类型），且操作数只求值一次

#### Scenario: 静态路径免 helper

- **WHEN** 以非 15 的左值写 `s as String`（`s: String`）
- **THEN** 不发射 `any_as`，产物与直接使用 `s` 逐位一致；若两侧不相容（`i: Int64` 写 `i as String`）则编译错误

#### Scenario: 结果类型可续算

- **WHEN** 写 `(a as Int64) + 1`
- **THEN** 编译通过：`as` 的结果静态类型为 Int64，可参与算术

#### Scenario: 禁止面

- **WHEN** 写 `a + 1`、`a == b`、`a.foo()`（`a: Any`）
- **THEN** 三者均编译错误，消息提示「先 `as`」

#### Scenario: 二次装箱拒绝

- **WHEN** 写 `let b: Any = a`（`a: Any`）
- **THEN** 产物**不含** `any_box(15, …)`：盒不套盒，同型直传（`b` 与 `a` 指向同一盒句柄，零动作）；显式要求对盒再装箱（`any_box(15, …)`）的路径不存在

#### Scenario: 闭包不得入容器

- **WHEN** 把闭包直接放入 `List<Any>`，或先装箱再放入
- **THEN** 两条路径均编译错误

### Requirement: JSON 字面量的词法、静态类型与发射

JSON 字面量 SHALL 只有**反引号**一种书写形态（`` `{…}` `` / `` `[…]` ``），内容零宿主转义、允许跨行，CRLF/CR 换行 SHALL 规范化为 `\n` 后再作 payload。`{`、`[` SHALL 保持 M1 原义（闭包字面量 / 空 Map 构造 / 列表字面值 / 下标语法），**不存在消歧，也不存在空形态的上下文定夺**；`{ "a" : 1 }` SHALL 仍按 M1 解析为映射字面量（`Map<String, Int64>`），**绝不**被解释成 JSON（design D15）。

词法保护 SHALL 覆盖反引号段：段内 `//`、`/*`、引号、`{`、`}` 与行首锚定标记不参与注释识别与括号配对；取界规则 = JSON 字符串感知 + 括号配平（`{"a":"}"}`、`["]"]`、嵌套 `[{…}]` 均正确取界）；无匹配闭合 SHALL 交解析器报错。

编译期 SHALL 对字面量按 JSON 语法解析一遍，非法即源编译错误（消息含位置）；静态类型 SHALL 由**体首非空白字符**决定：`{` → `JsonObject`、`[` → `JsonArray`；标量顶层（数字 / 字符串 / `true` / `false` / `null`）SHALL 编译错误。发射规则：非空字面值 → 常量 kind 11（`PUSH_KH`，句柄码 17/18）；空字面量 `` `{}` `` / `` `[]` `` → `json_new`（H83，运行期构造、非常量）。

#### Scenario: 反引号取界

- **WHEN** 编译 `` `{"a":"}"}` ``、`` `["]"]` ``、`` `[{"k":[]}]` ``
- **THEN** 三者均被完整取界并解析成功，静态类型分别为 JsonObject / JsonArray / JsonArray

#### Scenario: 注释不被剥离

- **WHEN** JSON 内含 `{"url":"http://x"}` 与 `{"p":"/* not a comment */"}`
- **THEN** 两处内容原样进入 payload，不被当作源语言注释移除

#### Scenario: 非法 JSON 编译错误

- **WHEN** 编译 `` `{"a":}` ``
- **THEN** 源编译错误，消息含行号列号与 JSON 错误描述

#### Scenario: 静态类型标注

- **WHEN** 分别把 `` `{"k":1}` `` 与 `` `[1,2]` `` 赋给 `JsonObject` / `JsonArray` 变量
- **THEN** 编译通过；赋给相反类型时编译错误

#### Scenario: 标量顶层拒绝

- **WHEN** 写 `` `123` `` 或 `` `"s"` `` 作顶层字面量
- **THEN** 编译错误

#### Scenario: 空与非空的分界

- **WHEN** 编译 `` `{}` `` 与 `` `{"a":1}` ``
- **THEN** 前者发射 `json_new`（可变、非常量）；后者发射 kind 11 常量（只读、frozen）

#### Scenario: 无消歧

- **WHEN** 编译 `{ args => args }`、`{}`、`[1,2]`、`xs[0]`、`{ "a" : 1 }`
- **THEN** 依次降为闭包、空 Map 构造、列表字面值、下标访问、映射字面量，与 M1 逐位一致（JSON 只能经反引号书写）

### Requirement: JSON 访问语法糖与自动收窄

下标访问 SHALL 按接收者静态类型分派：`JsonArray` 以 `Int64` 索引、`JsonObject` 以 `String` 索引；索引类型不符或对标量节点下标 SHALL 编译错误。读（`j[i]`）SHALL 降为 `json_get`（H81），结果静态类型为 **Any(15) 盒**；写（`j[i] = v`）SHALL 降为 `json_set`（H82），`v` 的值域限于值型 0–3（Unit 除外）/ String / JSON 节点（码 16–19）。

点号访问 SHALL 为**成员优先 → 键兜底**：`.` 右侧名字先查 JSON 成员表（宿主经预定义函数通道声明、首参码 ∈ 16–19 的函数集，成员名 = 函数名，沿 `JsonObject → JsonValue` 继承向上查找，快照语义）；命中 ⇒ 走 M2 成员访问糖；未命中 ⇒ 键访问，与 `o['k']` **逐位等价**（键为标识符常量）。成员与键同名时点号 SHALL 取成员，取键一律用 `o['size']`。

自动收窄 SHALL 适用于接收者静态类型为 `Any`(15) 或 `JsonValue` 的链式访问：点号 ⇒ `as JsonObject`，下标 ⇒ 按索引类型插 `as JsonArray`（`Int64`）/ `as JsonObject`（`String`）；中间值类型不符 SHALL 运行期以 **22** 失败；索引类型判不出 SHALL 编译错误；写侧 SHALL 对称展开。静态已知具体类（`JsonArray` / `JsonNull` / 标量）上取键 SHALL 编译错误。

JSON 谱系类 SHALL NOT 参与 `registerType<T>()`（以 `JsonFamily` 拒绝），且 `JsonObject(…)` 形式的类构造 SHALL 编译错误——构造只能经空字面量（H83）或宿主解析器。

#### Scenario: 点号与下标逐位等价

- **WHEN** 对同一 `JsonObject` 分别写 `o.k` 与 `o['k']`（读），再写 `o.k = v` 与 `o['k'] = v`（写）
- **THEN** 读返回同一盒；写后读回一致；产物除常量键的来源外逐位一致

#### Scenario: 成员优先

- **WHEN** 宿主注册 `func size(o: JsonObject): Int64`，且对象含同名键 `size`
- **THEN** `o.size()` 命中成员；`o['size']` 取键

#### Scenario: 链式自动收窄

- **WHEN** 写 `o.a.b` 与 `o.a.b = 1`（`o: JsonObject`）
- **THEN** 降为 `(o['a'] as JsonObject)['b']` 与对应写；若 `o['a']` 不是对象则以 22 失败

#### Scenario: 下标自动收窄与混链

- **WHEN** 写 `j.a[0]`、`j.a["k"]`、`j.a[0].b`
- **THEN** 依次降为 `(j['a'] as JsonArray)[0]`、`(j['a'] as JsonObject)["k"]`、`((j['a'] as JsonArray)[0] as JsonObject)['b']`

#### Scenario: 负向面

- **WHEN** 写 `arr.k`（`arr: JsonArray`）、`arr["k"]`、`obj[0]`（`obj: JsonObject`）、`n["k"]`（`n: JsonNull`）
- **THEN** 四者均编译错误（静态已知具体类）

#### Scenario: JSON 谱系不可注册

- **WHEN** 调用 `registerType<JsonObject>()`，或写 `JsonObject()`
- **THEN** 前者抛 `RegistrationException(kind=JsonFamily)`；后者编译错误（无注册构造器）
