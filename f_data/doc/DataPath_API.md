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
| **深层嵌套函数表达式 (3+ 层)** | §2.4 | 单层嵌套已验证（`count(match(...))`），深层嵌套未测试 |

---

## 参考

- [RFC 9535: JSONPath: Query Expressions for JSON](https://www.rfc-editor.org/rfc/rfc9535)
- [RFC 9535 覆盖清单](RFC9535_COVERAGE.md)
