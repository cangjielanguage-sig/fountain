# Design

## 背景与实测证据

SDK：`Cangjie Compiler: 1.3.0-alpha.20261112001016`（WSL Ubuntu-24.04）。探针目录 `.autocode/tmp/probe_dup/`（临时，不入库）逐个 `cjc` 编译，结论：

| 探针 | 声明 | 结果 |
| --- | --- | --- |
| p1 | `class A1 <: Comparable<A1> & Equatable<A1>`，`compare`/`==`/`!=` 全部手写 | **error** `interface function '!=(this @local!, other: Generics-T): Bool' must be implemented in 'A1'` |
| p2 | `class A2 <: Comparable<A2>`，`compare`/`==`/`!=` 手写 | 通过 |
| p3 | `class A3 <: Equatable<A3>`，`==`/`!=` 手写 | 通过 |
| p4 | `class A4 <: Hashable & Comparable<A4> & ToString` | 通过 |
| p5 | `class A5 <: Comparable<A5> & Equatable<A5> & Comparable<A5>` | **error** `duplicate interface 'Comparable'` |

两点结论：
1. **问题在「两条路径」，不在 `!=` 缺失**：p1 已经手写 `!=` 仍然报错 ⇒ 补实现、补 `@local!` 都不是出路（补模态会另报 `is not a subtype of`）。
2. **重复声明本身也会报错**：宏无条件 `superTypes.add(...)` 与用户显式声明撞车时同样编不过（实测 `OrderedItem` 报 `duplicate interface 'Equatable'`、`DupDeclared` 报 `duplicate interface 'Hashable'`）。

## 方案一：展开末尾归一化父接口列表

在 `assist()` 的 `ClassDecl` 分支里，`generate(...)` 全部执行完、`d.toTokens()` 之前，调用 `normalizeSuperTypes(d)`：

1. 用 `superTypeText(t)` 把每个父接口的 `toTokens()` 拍平成**无空白字符串**（跳过 `NL` / `COMMENT` 词法单元），保证 `Comparable<X>`、`Comparable< X >` 归一。
2. 收集所有 `Comparable<...>` 的文本；对形如 `Comparable<X>` 的项，推出它隐含的 `Equatable<X>` 文本（`Equatable` + 原文本 `Comparable` 之后的部分）。
3. 重建列表：
   - 文本已出现过 ⇒ 丢弃（去重，解决 p5 与实测的 `duplicate interface`）；
   - 文本命中「被隐含的 `Equatable<X>`」 ⇒ 丢弃（解决 p1，类仍实现 `Equatable`，只是走 `Comparable` 这条路径）。
4. 只有确实删掉了元素时才写回 `decl.superTypes`（`mut prop`，可整体赋值），避免无谓改动 AST。

判定全部基于**文本前缀**（`Comparable<`），不做类型实参的深层语义比较；限定名形式（`std.core.Comparable<X>`）不在归一化范围内——本仓库与 fountain 用户代码都用简单名，且这类写法也不是宏生成的形态。

## 方案二：修正 `generateCompare` 的赋值（新用例暴露）

`generateCompare` 生成的函数体是：

```
var result = Ordering.EQ
f_data_cmp(this.x, other.x)      // ← 只求值，没有赋值
if(result != EQ){ return result }
result
```

`result` 永不更新 ⇒ `compare` 对任何输入都返回 `EQ`，`sort` / 有序容器的排序全部退化为「相等」。修法是把每轮比较写回：

```
result = f_data_cmp(this.x, other.x)
```

`var result` 仍保留在函数开头（逐字段重复 `let` 会触发重复声明错误），语义即「按字段声明顺序、第一个不等字段决定结果」。修复前恒 `EQ` 无法被任何调用方依赖（仓库内只有 `f_data` 自己的测试类用 `[compare]`），因此是纯修复、不是行为升级。

## 为什么不选其他做法

| 备选 | 否决理由 |
| --- | --- |
| 只删宏自己追加的 `Equatable<X>`（不看用户声明） | 用户显式写 `Comparable<X> & Equatable<X>` 时仍报错，不满足「允许同时显式实现两个接口」 |
| 由宏报错要求用户删 `Equatable<X>` | 需求明确要求「允许」，且报错会波及既有代码 |
| 给生成的 `!=` 补 `@local!` 标注 | 普通模式下写不出该模态；p1 已证明手写 `!=` 也救不了 |
| 编译选项绕过（`--experimental --enable-local-mode`） | 治标：重复路径在 local mode 下语义仍有歧义；且不该为宏的产物让整个模块换模式 |
| 只测「能编译」，不碰 `compare` | 新用例已经断言 `compare` 给 `GT`；改写测试去迁就恒 `EQ` 等于把缺陷固化成规格 |

## 影响面

- **父接口归一化只影响被 `@DataAssist` 修饰的类**，且仅在「父接口列表里有重复项 / `Comparable<X>` 与 `Equatable<X>` 并存」时改变输出——正是编译器拒绝的两种形态。
- 生成成员的签名不变；`hashCode` / `==` / `!=` / `toString` / `dataFields` / `toData` 一行不改。
- 旧 SDK（1.2.0 / 无 local mode）下归一化后的声明同样合法：`Comparable<T> <: Equatable<T>` 在旧 std 里也成立。

## 测试策略（TDD）

宏是编译期展开，**编译通过本身就是断言的一半**，所以用例分两层：

1. **编译层（Red 的来源）**：新增 `f_data/src/test/DataAssist_test.cj`，其中
   - `OrderedItem`：显式 `<: Comparable<OrderedItem> & Equatable<OrderedItem>` + `@DataAssist[hash equal props fields tostring compare]`；
   - `DupDeclared`：显式 `<: Hashable & ToString & Equatable<DupDeclared>`（宏还会再追加同名接口）。
   修复前这两个类直接编译失败（`duplicate interface` / `!=` 模态错误），修复后编译通过。
2. **行为层**：断言归一化没有偷走语义——`is Comparable<T>`、`is Equatable<T>`、`is Hashable` 成立；`==`/`!=`/`compare`/`hashCode` 结果符合预期。这一层抓出了 `compare` 恒 `EQ` 的缺陷。

回归：`f_data` 全量 `cjpm test`（修复前编译失败；修复后 165/165）；`f_data` / `f_codec` / `f_rpc` 的 `cjpm build` 全成功；`f_codec` 全量 `cjpm test` 16/16。
