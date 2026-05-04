# DataPath RFC 9535 改进计划

## 执行顺序
每完成一步执行收尾仪式：加测试 → ✅标记 → /exp → 提交

---

### Step 1: 数组切片缺省值 + 负步长 ✅
- RangePathNode 改为三个字段 (start/end/step)
- 支持 [n:m], [:n], [n:], [:], [n:m:step], [4:0:-1], [::-1], [0:3:0]

### Step 2: `..[*]` 完整语法 ✅
- `..*`: 自动消费后续 MUL
- `..name`: IDENTIFIER 紧跟 RANGEOP → SubPathNode
- `..[selectors]`: RANGEOP/DOT 作为 LSQUARE 前驱

### Step 3: 存在性测试 ✅
- ExistsFilter: `?(@.name)` 路径返回非空=true

### Step 4: `null` 字面量过滤 ✅
- NullFilter: `?(@.name == null)`, `?(@.name != null)`

### Step 5: 函数扩展 count/match/search/value ✅
- CountPathNode, ValuePathNode 路径函数
- MatchFilter, SearchFilter filter 函数

### 全部测试：56/56 通过 ✅

---

### 未覆盖的 RFC 9535 特性

参见 `f_data/doc/RFC9535_GAPS.md`

**P1**: 标准化路径 (Normalized Paths)
**P2**: filter 内 count/value 比较、null 集合运算
**P3**: I-JSON 范围校验、结构相等、复杂函数表达式、length() 函数语法
