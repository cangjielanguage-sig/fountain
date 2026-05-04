# RFC 9535 覆盖清单

> 实现 branch: `feature/datapath`
> 测试: **63/63 通过** (21 basic + 30 filter + 9 recursive + 3 compile error)
> 文件: 18 个新文件 + 7 个修改文件

---

## ✅ 已覆盖 (Covered)

### 1. 标识符 (Identifiers)

| 语法 | RFC | 实现 | 测试 |
|------|-----|------|------|
| `$` 根节点 | §2.1 | `RootPathNode` | `testRootPath` |
| `@` 当前节点(filter内) | §2.1 | `CurrentPathNode` | filter tests |

### 2. 子段 (Child Segments)

| 语法 | RFC | 实现 | 测试 |
|------|-----|------|------|
| `.name` 点号名称 | §2.2 | `SubPathNode` | `testSubPath` |
| `.*` 点号通配 | §2.2 | `AnySubPathNode` | `testWildcard` |
| `['name']` 方括号名称 | §2.4 | `SubPathNode` | `testMultiSubPath` |
| `[*]` 方括号通配 | §2.4 | `AnySubPathNode` | `testWildcard` |
| `[0]` 索引 | §2.4 | `IndexPathNode` | `testIndex` |
| `[-1]` 负索引 | §2.4 | `IndexPathNode` | `testNegativeIndex` |
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

### 3. 递归段 (Descendant Segments)

| 语法 | RFC | 实现 | 测试 |
|------|-----|------|------|
| `..` 递归下降 | §2.3 | `RecursiveDescentPathNode` | `testRecursiveDescentSimple` |
| `..*` 递归通配 | §2.3 | 自动消费 MUL | `testRecursiveDescendStar` |
| `..name` 递归名称 | §2.3 | IDENTIFIER + RANGEOP | `testRecursiveDescendSubPath` |
| `..['name']` 递归方括号 | §2.3 | RANGEOP+DOT→LSQUARE | — |

### 4. 过滤选择器 (Filter Selectors)

| 语法 | RFC | 实现 | 测试 |
|------|-----|------|------|
| `?<expr>` | §2.4 | `DataFilterPathNode` | all filter tests |

### 5. 比较运算符 (Comparison Operators)

| 语法 | RFC | 实现 | 测试 |
|------|-----|------|------|
| `==` | §3.1 | `EqFilter` | `testFilterEqString` |
| `!=` | §3.1 | `NotEqFilter` | `testFilterNotEq` |
| `<` | §3.1 | `CmpFilter(LT,false)` | `testFilterLessThan` |
| `<=` | §3.1 | `CmpFilter(LT,true)` | `testFilterLessThanOrEqual` |
| `>` | §3.1 | `CmpFilter(GT,false)` | `testFilterGreaterThan` |
| `>=` | §3.1 | `CmpFilter(GT,true)` | `testFilterGreaterThanOrEqual` |

### 6. 逻辑运算符 (Logical Operators)

| 语法 | RFC | 实现 | 测试 |
|------|-----|------|------|
| `&&` | §3.1 | `AndFilter` | `testFilterAnd` |
| `\|\|` | §3.1 | `OrFilter` | `testFilterOr` |
| `!` | §3.1 | `NotFilter` | `testFilterNot` |
| `(...)` 分组 | §3.1 | `ParenExpr` via `parseExpr` | `testFilterNot` |

### 7. 字面量 (Literals)

| 类型 | RFC | 实现 | 测试 |
|------|-----|------|------|
| 字符串 `'...'` / `"..."` | §5 | 引号剥离 | `testFilterEqString` |
| 整数 `25` | §5 | `Int64.parse` | `testFilterEqInt` |
| 浮点数 `3.14` | §5 | `Float64.parse` | — |
| `true` / `false` | §5 | `Bool` | — |
| `null` | §5 | `NullFilter` + `DataNone` | `testFilterNullEq` |

### 8. 存在性测试 (Existence Tests)

| 语法 | RFC | 实现 | 测试 |
|------|-----|------|------|
| `?(@.name)` | §3.3 | `ExistsFilter` | `testFilterExists` |
| `?(!(@.name))` | §3.3 | `NotFilter(ExistsFilter)` | `testFilterNotExists` |

### 9. 函数扩展 (Function Extensions)

| 函数 | RFC | 实现 | 语法 | 测试 |
|------|-----|------|------|------|
| `count()` 路径级 | §4.3 | `CountPathNode` | `$.count()` | `testFunctionCount` |
| `count()` filter 比较 | §4.3 | `CountCmpFilter` | `count(@.*) OP N` | `testFilterCountEq` |
| `match()` | §4.4 | `MatchFilter` | `match(@.name, "pat")` | `testFilterMatch` |
| `search()` | §4.5 | `SearchFilter` | `search(@.name, "pat")` | `testFilterSearch` |
| `value()` 路径级 | §4.6 | `ValuePathNode` | `$.value()` | `testFunctionValue` |
| `value()` filter 比较 | §4.6 | `ValueCmpFilter` | `value(@.name) == X` | `testFilterValueEq` |
| `length()` 路径级 | §4.2 | `LengthPathNode` | `$.length()` | `testFunctionLength` |
| `length()` filter 比较 | §4.2 | `LengthCmpFilter` | `length(@.name) OP N` | `testFilterLengthGt` |

### 10. 自定义扩展 (Extensions)

| 语法 | 实现 | 测试 |
|------|------|------|
| `=~ /regex/` 正则 | `RegexFilter` | `testFilterRegex` |
| `in` 集合 | `InFilter` | `testFilterIn` |
| `nin` 非集合 | `NinFilter` | `testFilterNin` |
| `in [null]` 含null集合 | `InFilter(hasNull)` | `testFilterInNull` |
| `anyof` | `AnyOfFilter` | — |
| `subsetof` | `SubSetOfFilter` | — |
| `nooneof` | `NoOneOfFilter` | — |
| `size` | `SizeFilter` | `testFilterSize` |
| `min()` / `max()` / `avg()` | 路径函数 | `testFunctionMin/Max/Avg` |

### 11. 边界行为 (Edge Cases)

| 行为 | RFC | 实现 |
|------|-----|------|
| 重复节点保留 `$[0,0]` | §6.3 | 通过 lazy flatMap 链保留 |
| 空 nodelist → 空结果 | §6.1 | 默认行为 |
| 类型不匹配 → false | §6.2 | `case _ => false` |
| `@` 仅在 filter 内有效 | §2.1 | `doCompile` 验证 |
| 结构失配 → 空结果 | §6.1 | `case _ => OptionIterator<Data>()` |
| I-JSON 数字范围 | §6.5 | `validateIJSON()` |

---

## ⚠️ 部分覆盖 (Partial)

| 特性 | 说明 |
|------|------|
| 标准化路径 (Normalized Paths) §8 | 未实现。需要为匹配节点生成 `$['name'][0]` 形式路径 |
| 对象/数组结构相等 | 未实现。需要 parser 支持数组/对象字面量 |
| 复杂函数表达式 | 仅单层函数调用，不支持嵌套 `match(x, search(...))` |

---

## 文件清单 (Files)

### 源文件 (Source)

| 文件 | 类型 | 行数 |
|------|------|------|
| `DataPath.cj` | 路径解析器 | ~560 |
| `DataPathNode.cj` | 路径节点接口 | ~20 |
| `RootPathNode.cj` | `$` 节点 | ~25 |
| `CurrentPathNode.cj` | `@` 节点 | ~24 |
| `SubPathNode.cj` | `.name` 子路径 | ~26 |
| `MultiSubPathNode.cj` | `['a','b']` 多名称 | ~23 |
| `AnySubPathNode.cj` | `*` 通配 | ~36 |
| `IndexPathNode.cj` | `[0]` 索引 | ~40 |
| `MultiIndexPathNode.cj` | `[0,2]` 多索引 | ~23 |
| `RangePathNode.cj` | `[start:end:step]` 切片 | ~73 |
| `RecursiveDescentPathNode.cj` | `..` 递归 | ~25 |
| `RecursiveDescentIterator.cj` | 递归迭代器 | ~50 |
| `DataFilter.cj` | 过滤器接口 | ~82 |
| `DataFilterPathNode.cj` | 过滤器桥接 | ~33 |
| `EqFilter.cj` | `==` 过滤 | ~50 |
| `NotEqFilter.cj` | `!=` 过滤 | ~30 |
| `CmpFilter.cj` | 比较过滤 | ~62 |
| `AndFilter.cj` | `&&` 过滤 | ~24 |
| `OrFilter.cj` | `\|\|` 过滤 | ~24 |
| `NotFilter.cj` | `!` 过滤 | ~23 |
| `InFilter.cj` | `in` 集合 | ~60 |
| `NinFilter.cj` | `nin` 非集合 | ~30 |
| `AnyOfFilter.cj` | `anyof` | ~28 |
| `SubSetOfFilter.cj` | `subsetof` | ~38 |
| `Subset.cj` | 子集基类 | ~47 |
| `NoOneOfFilter.cj` | `nooneof` | ~28 |
| `SizeFilter.cj` | `size` 过滤 | ~52 |
| `RegexFilter.cj` | `=~` 正则 | ~50 |
| `ExistsFilter.cj` | 存在性测试 | ~25 |
| `NullFilter.cj` | `null` 比较 | ~30 |
| `ConfigFilter.cj` | 配置过滤 | — |
| **新文件** | | |
| `CountCmpFilter.cj` | `count()` filter 比较 | ~42 |
| `ValueCmpFilter.cj` | `value()` filter 比较 | ~25 |
| `LengthCmpFilter.cj` | `length()` filter 比较 | ~55 |
| `CountPathNode.cj` | `$.count()` 路径函数 | ~32 |
| `ValuePathNode.cj` | `$.value()` 路径函数 | ~30 |
| `MatchFilter.cj` | `match()` 函数 | ~42 |
| `SearchFilter.cj` | `search()` 函数 | ~42 |

### 测试文件

| 文件 | 测试数 |
|------|--------|
| `DataPath_test.cj` | 63 |

---

## git 分支

```
feature/datapath — 17 commits, ±2000 lines changed
```
