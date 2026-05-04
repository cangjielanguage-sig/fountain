# DataPath RFC 9535 改进计划

## 执行顺序
每完成一步执行收尾仪式：加测试 → ✅标记 → /exp → 提交

---

### Step 1: 数组切片缺省值 + 负步长
- **文件**: `DataPath.cj`, `RangePathNode.cj`
- **内容**: 支持 `[:]`, `[:5]`, `[3:]`, `[::-1]`, `[5:2:-1]`
- **方法**: `RangePathNode` 改为三个独立字段(start/end/step)，手动实现迭代

### Step 2: `..[*]` 完整语法
- **文件**: `DataPath.cj`
- **内容**: 支持 `..name`, `..*`, `..['name']`, `..[selectors]`
- **方法**: `doCompile` 中处理 `..` 后跟选择器

### Step 3: 存在性测试
- **文件**: `DataPath.cj`, 新建 `ExistsFilter.cj`
- **内容**: `?(@.name)` 作为布尔测试（路径返回非空=true）

### Step 4: `null` 字面量过滤
- **文件**: `DataPath.cj`, 新建 `NullFilter.cj`
- **内容**: `?(@.name == null)`, `?(@.name != null)`

### Step 5: 函数扩展 `count()`, `match()`, `search()`, `value()`
- **文件**: `DataPath.cj`, 新建 `CountFilter.cj` 等
- **内容**: RFC 9535 标准函数扩展

### Step 6: 测试用例
- **文件**: `DataPath_test.cj`
- **内容**: 以上所有新特性的测试
