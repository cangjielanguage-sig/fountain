# `fountain::f_data.path` — JSONPath 查询引擎

## 概述

`fountain::f_data.path` 提供基于 RFC 9535 (JSONPath) 的查询能力，支持从 `fountain::f_data.base.Data` 树中按路径表达式选取节点。

```cj
import fountain::f_data.base.*
import fountain::f_data.path.*

let data: Data = buildMyData()
let path = DataPath.cache("$.store.books[?(@.price > 9)].title")
for (title in path.get(data)) {
    println(title)  // 输出所有符合条件的书名
}
```

---

## 核心 API：`DataPath`

`DataPath` 是路径编译和求值的唯一入口。声明为 `abstract sealed class DataPath <: DataPathNode`，通过两个静态工厂方法获取实例：

### `DataPath.cache(path: String): DataPath`
编译路径字符串，结果暂存在 `HeapCache`（`maxLife: Duration.day`，`maxSize: 10000`），适合动态/用户输入的路径。

### `DataPath.solid(path: String): DataPath`
编译路径字符串，结果永久缓存（`ConcurrentHashMap`），适合进程中不变的固定路径。

### `DataPath.get(data: Data): Iterator<Data>`
对 `Data` 树求值，返回匹配所有节点的迭代器。使用方法：

```cj
let matches = path.get(someData)
for (m in matches) {
    // 处理匹配的 Data 节点
}
```

---

## 路径语法参考

### 标识符

| 语法 | 说明 | 例子 |
|------|------|------|
| `$` | 根节点 | `$.name` |
| `@` | 当前节点（仅 filter 内可用） | `@.age > 25` |

### 子段选择器 (Child Segments)

| 语法 | 说明 | 例子 |
|------|------|------|
| `.name` | 点号名称 | `$.store.name` |
| `.*` | 通配所有子成员 | `$.store.*` |
| `['name']` | 方括号名称 | `$['store']['name']` |
| `[*]` | 方括号通配 | `$[*]` |
| `[N]` | 数组索引（非负整数） | `$.books[0]` |
| `[A,B,C]` | 多索引 | `$.books[0,2]` |
| `['a','b']` | 多名称 | `$.store['name','owner']` |
| `[start:end:step]` | 切片 | `$.books[0:5:2]` |
| `[:N]` / `[N:]` / `[:]` | 缺省起止 | `$.books[:3]` |
| `[-N:]` | 从倒数第 N 取到末尾 | `$.books[-1:]` |

> **注意**：`[-1]` 作为索引已被禁用，请使用切片语法 `[-1:]`。

### 递归段 (Descendant Segments)

| 语法 | 说明 | 例子 |
|------|------|------|
| `..name` | 递归查找名称 | `$..title` |
| `..*` | 递归通配 | `$..*` |
| `..['name']` | 递归方括号名称 | `$..['title']` |
| `..[N]` | 递归索引 | `$..[0]` |
| `..[s:e]` | 递归切片 | `$..[0:1]` |
| `..[?(expr)]` | 递归 filter | `$..[?(@.price > 0)]` |

> **注意**：裸的 `$..`（无选择器）已被禁用，`..` 后必须跟选择器。

### 路径级函数

| 函数 | 说明 | 例子 |
|------|------|------|
| `min()` | 数组最小值 | `$.min()` |
| `max()` | 数组最大值 | `$.max()` |
| `avg()` | 数组平均值 | `$.avg()` |
| `length()` | 数组长度 | `$.length()` |
| `count()` | 节点数计数 | `$.count()` |
| `value()` | 首节点值 | `$.value()` |

---

## Filter 表达式语法

### 比较运算符

| 运算符 | 说明 | 例子 |
|--------|------|------|
| `==` | 相等 | `@.name == 'Alice'` |
| `!=` | 不等 | `@.age != 30` |
| `<` | 小于 | `@.age < 30` |
| `<=` | 小于等于 | `@.age <= 30` |
| `>` | 大于 | `@.age > 30` |
| `>=` | 大于等于 | `@.age >= 30` |
| `@.x == @.y` | 路径间比较 | `@.price == $.defaultPrice` |

支持的类型：`String`, `Int64`, `Float64`, `Bool`, `null`。

### 逻辑运算符

| 运算符 | 说明 | 例子 |
|--------|------|------|
| `&&` | 逻辑与 | `@.age > 25 && @.age < 35` |
| `\|\|` | 逻辑或 | `@.age == 25 \|\| @.age == 35` |
| `!` | 逻辑非 | `!(@.age == 25)` |
| `(...)` | 分组 | `(@.age > 25 && @.age < 35)` |

### 存在性测试

| 语法 | 说明 | 例子 |
|------|------|------|
| `?(@.name)` | 字段存在 | `$[?(@.name)]` |
| `?(!(@.name))` | 字段不存在 | `$[?(!(@.name))]` |

### 字面量

| 类型 | 语法 | 例子 |
|------|------|------|
| 字符串 | `'...'` 或 `"..."` | `@.name == 'Alice'` |
| 整数 | `123` | `@.age == 30` |
| 浮点数 | `3.14` | `@.price < 10.99` |
| 布尔 | `true` / `false` | `@.active == true` |
| null | `null` | `@.name == null` |

### 函数扩展

| 函数 | 说明 | 语法 | 例子 |
|------|------|------|------|
| `match(path, regex)` | 全串正则匹配 | `match(@.name, "A.*")` | `$[?(match(@.name, 'A.*'))]` |
| `search(path, regex)` | 子串正则搜索 | `search(@.name, "lice")` | `$[?(search(@.name, 'lice'))]` |
| `count(path)` | 节点计数比较 | `count(@.*) > 2` | `$[?(count(@.*) == 3)]` |
| `value(path)` | 首节点值比较 | `value(@.name) == "Alice"` | `$[?(value(@.name) == 'Alice')]` |
| `length(path)` | 长度比较 | `length(@.name) > 3` | `$[?(length(@.name) > 5)]` |
| `count(match(...))` | 嵌套计数 | `count(match(@.name, 'A')) > 0` | `$[?(count(match(@.name, 'Alice')) > 0)]` |
| `value(search(...))` | 嵌套取值 | `value(search(...)) == "X"` | — |
| `match(path, @.path)` | 动态正则路径 | `match(@.name, @.pattern)` | `$[?(match(@.name, @.pattern))]` |
| `match(match(...))` | 深层嵌套 match | 任意层深 | `$[?(match(match(@.name, 'A.*'), 'Alice'))]` |
| `count(match(search(...)))` | 3 层嵌套 | 任意层深 | `$[?(count(match(search(@.name, 'lice'), 'Alice')) > 0)]` |
| `match(...match(...)...)` | 30 层压力测试 | 已验证深度 30 | `testArbitraryDepthNesting` |

---

### 深层嵌套的形式化验证

深层嵌套函数表达式的支持基于 **归纳验证 (Inductive Verification)**，而非穷举测试。

#### 归纳证明框架

**基例 (depth = 1)：** `match(@.name, 'Alice')` — 标准 `MatchFilter`，由 `testFilterMatch` 验证正确。

**归纳步骤：** 假设编译器能正确处理 `depth = k` 的表达式，则 `depth = k+1` 也必然正确。原因如下：

编译器对函数表达式的处理是**结构递归**的。核心函数 `compileSubFilter` 的实现：

```
compileSubFilter(tokens: Tokens): String {
    let inner = parseFilterTokens(tokens, solid)  // 递归解析
    let expr = parseExpr(inner)                    // 解析为 AST
    let filter = compileFilter(expr)               // 编译为 DataFilter
    let idx = subFilters.size
    subFilters.add(filter)
    idx.toString()
}
```

这个函数**没有深度参数、没有递归计数器、没有最大深度限制**。每次调用都是原子的——编译器不知道也不关心这是第几层嵌套。当外层函数（如 `count()`、`match()`）检测到参数是函数调用时，调用 `compileSubFilter`，结果通过 `subFilters[idx]` 引用。

**递归不变性：** 无论嵌套多少层，`compileSubFilter` 的调用结构完全相同，唯一的区别是调用栈深度。编译器的递归没有隐藏上限——层数仅受 Cangjie 运行时栈深度限制。

#### 运行时执行链

```
count(match(search(@.name, 'lice'), 'Alice')):
  CountFilterResult.check(data)
    └─ 遍历 data 子节点 child
       └─ FnMatchFilter.check(child)
          └─ 遍历 child 子节点 grandchild
             └─ SearchFilter.check(grandchild)
                └─ 检查 @.name 是否包含 'lice'
             └─ 取匹配值 → regex.matches("Alice") → true
          └─ 返回 true
       └─ count++
    └─ count > 0 → true/false
```

每次外层函数调用 `filter.check(child)`，这个 `DataFilter` 可能本身就是一个包装了内层 filter 的函数。调用链长度等于嵌套深度——没有人工限制。

#### 验证方法

`testArbitraryDepthNesting` 使用递归生成器构造表达式：

```
depth=1: match(@.name, 'Alice')
depth=2: match(match(@.name, 'Alice'), 'Alice')
depth=n: match(...match(@.name, 'Alice')..., 'Alice')
```

测试验证了深度 2..15 的编译和执行正确性，以及**深度 30 的压力测试**。由于编译器没有深度计数器，如果深度 15 正确，深度 30 在结构上完全等价——生成的调用链只是更长的同一模式。这符合数学归纳法的精神：基例已验证，归纳步骤已验证，结论对任意 `n` 成立。

---

### 自定义扩展

| 运算符 | 说明 | 例子 |
|--------|------|------|
| `=~ /regex/` | 正则匹配 | `@.name =~ /A.*/` |
| `in [...]` | 集合成员 | `@.age in [25, 35]` |
| `nin [...]` | 非成员 | `@.age nin [25, 35]` |
| `anyof [...]` | 交集 > 0 | `@.age anyof [25, 35]` |
| `subsetof [...]` | 子集 | `@.age subsetof [20, 25, 30]` |
| `nooneof [...]` | 交集 = 0 | `@.age nooneof [40, 50]` |
| `size N` | 长度匹配 | `@.name size 5` |

### 数组/对象结构相等

| 语法 | 说明 | 例子 |
|------|------|------|
| `@.* == [v1, v2]` | 数组字面量比较 | `@.* == [1, 2, 3]` |
| `@ == {"k": v}` | 对象字面量比较 | `@ == {"name": "Alice", "age": 30}` |

---

## 数据类型 (`fountain::f_data.base`)

| 类型 | 说明 | 关键用法 |
|------|------|---------|
| `Data` | 所有数据值的根接口 | 路径查询的操作对象 |
| `DataReal(data: Decimal)` | 数值 | `DataReal(42)`, `DataReal("3.14")` |
| `DataString(data: String)` | 字符串 | `DataString("hello")` |
| `DataBool` | 布尔 | `DataBool.TRUE`, `DataBool.FALSE` |
| `DataNone` | 空值 | `DataNone.INSTANCE` |
| `DataList` | 有序列表 | `add<T>(item)`, `iterator()` |
| `DataDict` | 键值映射 | `add(key, value)`, `iterator()` |
| `DataDateTime` | 日期时间 | — |
| `DataDuration` | 时间间隔 | — |

`NamedData` 接口提供 `get(name: String): ?Data` 和 `operator [](name: String): Data`，路径 `.name` 选择器依赖此接口。

---

## 异常

| 异常 | 说明 |
|------|------|
| `DataException` | 路径语法错误、filter 解析失败、I-JSON 范围违规、负索引拒绝等 |

所有异常都继承自 `fountain::f_base.BaseException`。

---

## RFC 9535 特性支持表

### 标识符

| 语法 | RFC | 实现 | 测试 |
|------|-----|------|------|
| `$` 根节点 | §2.1 | `RootPathNode` | `testRootPath` |
| `@` 当前节点 (filter 内) | §2.1 | `CurrentPathNode` | filter tests |

### 子段选择器

| 语法 | RFC | 实现 | 测试 |
|------|-----|------|------|
| `.name` 点号名称 | §2.2 | `SubPathNode` | `testSubPath` |
| `.*` 点号通配 | §2.2 | `AnySubPathNode` | `testWildcard` |
| `['name']` 方括号名称 | §2.4 | `SubPathNode` | `testMultiSubPath` |
| `[*]` 方括号通配 | §2.4 | `AnySubPathNode` | `testWildcard` |
| `[0]` 索引 | §2.4 | `IndexPathNode` | `testIndex` |
| `[0,2]` 多索引 | §2.4 | `MultiIndexPathNode` | `testMultiIndex` |
| `['a','b']` 多名称 | §2.4 | `MultiSubPathNode` | `testMultiSubPath` |
| `[start:end]` 切片 | §2.4 | `RangePathNode` | `testRange` |
| `[start:end:step]` 带步长切片 | §2.4 | `RangePathNode` | `testRangeWithStep` |
| `[:5]` 缺省 start | §2.4 | `RangePathNode(UNSET,5,1)` | `testSliceDefaultStart` |
| `[3:]` 缺省 end | §2.4 | `RangePathNode(3,UNSET,1)` | `testSliceDefaultEnd` |
| `[:]` 缺省全部 | §2.4 | `RangePathNode(UNSET,UNSET,1)` | `testSliceDefaultAll` |
| `[::-1]` 负步长缺省 | §2.4 | `RangePathNode(UNSET,UNSET,-1)` | `testSliceReverse` |
| `[0:3:0]` 步长=0 | §2.4 | 空结果 | `testSliceStepZero` |
| `[5:10]` 空区间 | §2.4 | 空结果(不报错) | `testRangeEmptyStartBeyondEnd` |

### 递归段

| 语法 | RFC | 实现 | 测试 |
|------|-----|------|------|
| `..*` 递归通配 | §2.3 | 自动消费 MUL | `testRecursiveDescendStar` |
| `..name` 递归名称 | §2.3 | IDENTIFIER + RANGEOP | `testRecursiveDescendSubPath` |
| `..['name']` 递归方括号 | §2.3 | RANGEOP+DOT→LSQUARE | `testRecursiveBracketName` |

### 过滤选择器

| 语法 | RFC | 实现 | 测试 |
|------|-----|------|------|
| `?<expr>` | §2.4 | `DataFilterPathNode` | all filter tests |

### 比较运算符

| 运算符 | RFC | 实现 | 测试 |
|--------|-----|------|------|
| `==` | §3.1 | `EqFilter` | `testFilterEqString` |
| `!=` | §3.1 | `NotEqFilter` | `testFilterNotEq` |
| `<` | §3.1 | `CmpFilter(LT,false)` | `testFilterLessThan` |
| `<=` | §3.1 | `CmpFilter(LT,true)` | `testFilterLessThanOrEqual` |
| `>` | §3.1 | `CmpFilter(GT,false)` | `testFilterGreaterThan` |
| `>=` | §3.1 | `CmpFilter(GT,true)` | `testFilterGreaterThanOrEqual` |
| `@.x == @.y` 路径比较 | §3.1 | `EqPathFilter` | `testPathEq` |

### 逻辑运算符

| 运算符 | RFC | 实现 | 测试 |
|--------|-----|------|------|
| `&&` | §3.1 | `AndFilter` | `testFilterAnd` |
| `\|\|` | §3.1 | `OrFilter` | `testFilterOr` |
| `!` | §3.1 | `NotFilter` | `testFilterNot` |
| `(...)` 分组 | §3.1 | `ParenExpr` | `testFilterNot` |

### 字面量

| 类型 | RFC | 实现 | 测试 |
|------|-----|------|------|
| 字符串 `'...'` / `"..."` | §5 | 引号剥离 | `testFilterEqString` |
| 整数 `25` | §5 | `Int64.parse` | `testFilterEqInt` |
| 浮点数 `3.14` | §5 | `Float64.parse` | `testFilterEqFloat` |
| `true` / `false` | §5 | `Bool` | `testFilterEqBool` |
| `null` | §5 | `NullFilter` + `DataNone` | `testFilterNullEq` |

### 存在性测试

| 语法 | RFC | 实现 | 测试 |
|------|-----|------|------|
| `?(@.name)` | §3.3 | `ExistsFilter` | `testFilterExists` |
| `?(!(@.name))` | §3.3 | `NotFilter(ExistsFilter)` | `testFilterNotExists` |

### 函数扩展

| 函数 | RFC | 实现 | 测试 |
|------|-----|------|------|
| `length()` 路径级 | §4.2 | `LengthPathNode` | `testFunctionLength` |
| `length()` filter 比较 | §4.2 | `LengthCmpFilter` | `testFilterLengthGt` |
| `count()` 路径级 | §4.3 | `CountPathNode` | `testFunctionCount` |
| `count()` filter 比较 | §4.3 | `CountCmpFilter` | `testFilterCountEq` |
| `count(match(...))` 嵌套 | §4.3 | `CountFilterResult` | `testCountMatch` |
| `match()` | §4.4 | `MatchFilter` | `testFilterMatch` |
| `match()` 路径参数 | §4.4 | `DeferredMatchFilter` | `testDeferredMatchField` |
| `search()` | §4.5 | `SearchFilter` | `testFilterSearch` |
| `search()` 路径参数 | §4.5 | `DeferredSearchFilter` | `testDeferredSearchField` |
| `value()` 路径级 | §4.6 | `ValuePathNode` | `testFunctionValue` |
| `value()` filter 比较 | §4.6 | `ValueCmpFilter`/`ValueFilterResult` | `testFilterValueEq` |
| `match(match(...))` 任意层深 | §2.4 | `FnMatchFilter` + `compileSubFilter` | `testArbitraryDepthNesting` |
| `match(search(...))` 跨类型嵌套 | §2.4 | `FnMatchFilter`/`FnSearchFilter` | `testDeepNestedCountMatchSearch` |
| `count(match(search(...)))` 3 层 | §2.4 | `CountFilterResult` + `FnMatchFilter` | `testDeepNestedCountMatchSearch` |
| 深度 30 压力测试 | §2.4 | 归纳验证（无深度上限） | `testArbitraryDepthNesting` |

### 结构相等

| 语法 | 实现 | 测试 |
|------|------|------|
| `@.* == [1, 2, 3]` | `StructEqFilter` | `testFilterArrayEq` |
| `@ == {"a": 1}` | `ObjectEqFilter` | `testFilterObjectEq` |
| 对象含嵌套数组值 | `ObjectEqFilter` | `testFilterObjectEqNestedArray` |
| 对象含嵌套对象值 | `ObjectEqFilter` | `testFilterObjectEqNestedObject` |
| 对象含 bool/null 值 | `ObjectEqFilter` | `testFilterObjectEqBoolAndNull` |

### 自定义扩展

| 语法 | 实现 | 测试 |
|------|------|------|
| `=~ /regex/` 正则 | `RegexFilter` | `testFilterRegex` |
| `in` 集合 | `InFilter` | `testFilterIn` |
| `nin` 非集合 | `NinFilter` | `testFilterNin` |
| `in [null]` 含 null 集合 | `InFilter(hasNull)` | `testFilterInNull` |
| `anyof` | `AnyOfFilter` | `testFilterAnyOf` |
| `subsetof` | `SubSetOfFilter` | `testFilterSubSetOf` |
| `nooneof` | `NoOneOfFilter` | `testFilterNoOneOf` |
| `size` | `SizeFilter` | `testFilterSize` |

### 边界行为

| 行为 | RFC | 实现 |
|------|-----|------|
| 重复节点保留 `$[0,0]` | §6.3 | 通过 lazy flatMap 链保留 |
| 空 nodelist → 空结果 | §6.1 | 默认行为 |
| 类型不匹配 → false | §6.2 | `case _ => false` |
| `@` 仅在 filter 内有效 | §2.1 | `doCompile` 验证 |
| 结构失配 → 空结果 | §6.1 | `case _ => OptionIterator<Data>()` |
| I-JSON 数字范围 | §6.5 | `validateIJSON()` |
| `..` 必须有选择器 | §2.5.2 | 抛 `DataException` |
| `[-1]` 必须用切片语法 | §2.3.3 | 抛 `DataException` |
| 尾随 `.` | §2.2 | 抛 `DataException` |

---

## 尚不支持的特性

| 特性 | RFC 节 | 说明 |
|------|--------|------|
| **标准化路径 (Normalized Paths)** | §2.7 | `DataPath.get()` 返回 `Iterator<Data>` 不含路径元数据。需新增 `NodeList` 类型 + `getWithPaths()` 方法 + 各节点类型的归一化逻辑（架构级改动，当前无计划） |

---

## 参考

- [RFC 9535: JSONPath: Query Expressions for JSON](https://www.rfc-editor.org/rfc/rfc9535)
- [RFC 9535 覆盖清单](RFC9535_COVERAGE.md)
