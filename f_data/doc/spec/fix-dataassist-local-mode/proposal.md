# Proposal

## Why

`f_data` 的 `cjpm test` 在 SDK `1.3.0-alpha.20261112001016`（nightly 20261110 起 std 全面合入 local mode）下**编译失败**：

```
error: interface function '!=(this @local!, other: Generics-T): Bool' must be implemented in 'DataTest'
note: the error originates in the macro `DataAssist`
```

根因不是测试用例本身，而是新 std 的接口关系与宏生成的父接口列表冲突：

- 新 std：`Comparable<T> <: Equatable<T>`，且 `Equatable<T> <: Equal<T> & NotEqual<T>`（`!=` 自带默认实现）；
- `@DataAssist[equal compare]` 分别向被修饰类的 `superTypes` 追加 `Equatable<X>` 与 `Comparable<X>`，于是 `Equatable<X>` 有**两条继承路径**；
- 重复路径让编译器要求实现带 `@local!` 模态的 `!=`（`Comparable` 侧实例化出来的那条），普通模式下写不出来——探针 p1（`class A1 <: Comparable<A1> & Equatable<A1>` 且已显式实现 `==`/`!=`）同样报这个错。

也就是说：**只要一个类同时列出 `Comparable<X>` 和 `Equatable<X>`，编译必错**，无论 `!=` 是否已实现。`f_data` 的 `DataTest` 是仓库里唯一同时带 `[equal compare]` 的类，因此只有 `f_data` 的 `cjpm test` 被打挂。

另外，为这条需求补用例时发现 `@DataAssist[compare]` 生成的 `compare` **恒返回 `EQ`**：展开里只有
`f_data_cmp(this.x, other.x)` 的求值，没有把结果写回 `result`（见 `generateCompare`），文档承诺的「按字段比较」实际失效。

## What Changes

`@DataAssist` 在展开末尾**归一化被修饰类的父接口列表**：

1. **去掉完全重复的父接口**：同一父接口（同样的类型实参）只保留第一个。此前宏与用户显式声明重复时编译器报 `class 'X' inherits or implements duplicate interface 'Comparable'`（探针 p5）。
2. **`Comparable<X>` 存在时删掉 `Equatable<X>`**：`Comparable` 已隐含 `Equatable`，删掉冗余声明后类**仍然实现两个接口**，语义不变，但不再有两条路径。

效果：`@DataAssist[hash equal compare ...]` 正常展开；用户显式写 `class X <: Comparable<X> & Equatable<X>` 配 `@DataAssist` 也能通过编译（宏会归一化掉冗余的 `Equatable<X>`）。

顺带修掉新用例暴露的 `compare` 缺陷：把每轮比较结果写回 `result`，`compare` 恢复「按字段声明顺序、第一个不等字段决定 `Ordering`」。

**不改任何公开 API 与宏属性名**；生成成员的签名不变，`compare` 从「恒 `EQ`」变为文档承诺的行为。

## Capabilities

### New Capabilities

- `data-assist-supertypes`：`@DataAssist` 展开后的父接口列表必须无完全重复项、无「`Comparable<X>` + `Equatable<X>`」这种冗余路径，且归一化后类仍同时实现 `Comparable<X>` 与 `Equatable<X>`。
- `data-assist-compare`：`@DataAssist[compare]` 生成的 `compare` 必须按字段声明顺序返回真实顺序，不得恒返回 `EQ`。

## Impact

- 代码：`f_data/src/macros/DataAssist.cj`（新增父接口归一化；修正 `generateCompare` 的赋值）。
- 测试：新增 `f_data/src/test/DataAssist_test.cj`；`f_data` 全量 `cjpm test` 165/165。
- 文档：`f_data/README.md` / `README_en.md` 的 `@DataAssist` 章节（中英成对）。
- 兼容性：父接口归一化只删冗余声明，不改变接口实现关系；`compare` 修复前恒 `EQ`（无法被依赖），修复后才有真实顺序——仓库内只有 `f_data` 自己的测试类使用 `[compare]`。
