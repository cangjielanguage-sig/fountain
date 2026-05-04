# DataPath RFC 9535 改进计划

## 执行顺序
每完成一步执行收尾仪式：加测试 → ✅标记 → /exp → 提交

---

### Step 1: 数组切片缺省值 + 负步长 ✅
- 21/21 基本测试通过
- RangePathNode 改为三个字段 (start/end/step)
- 支持 [n:m], [:n], [n:], [:], [n:m:step], [4:0:-1], [0:3:0]

### Step 2: `..[*]` 完整语法 ✅
- `..*`: 自动消费后续 MUL 标记
- `..name`: IDENTIFIER 紧跟 RANGEOP 时转为 SubPathNode
- `..[selectors]`: RANGEOP/DOT 作为 LSQUARE 的前驱标记

### Step 3: 存在性测试 ✅
- 新建 `ExistsFilter`
- `?(@.name)` 作为布尔测试（路径返回非空=true）

### Step 4: `null` 字面量过滤 ✅
- 新建 `NullFilter`
- 支持 `?(@.name == null)`, `?(@.name != null)`

### 全部测试结果：51/51 通过 ✅

| 套件 | 通过 |
|------|------|
| DataPath_basic_test | 21 |
| DataPath_filter_test | 19 |
| DataPath_recursive_test | 7 |
| DataPath_compile_error_test | 3 |
