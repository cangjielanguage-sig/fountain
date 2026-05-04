# DataPath RFC 9535 改进计划

## 执行顺序
每完成一步执行收尾仪式：加测试 → ✅标记 → /exp → 提交

---

### Step 1: 数组切片缺省值 + 负步长 ✅
- **文件**: `DataPath.cj`, `RangePathNode.cj`, `DataPath_test.cj`
- **结果**: 21/21 基本测试通过
- **支持**: `[:]`, `[:5]`, `[3:]`, `[4:0:-1]`, `[0:3:0]`
- **待完善**: `[::-1]` 缺省 start/end 负步长 (token 解析需要 `hasColon` 跨方法调用支持)

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

### Step 6: `[::-1]` 缺省值支持 + 更多测试
- **文件**: `DataPath.cj`, `DataPath_test.cj`
- **内容**: 解决 `hasColon` 前向引用问题，添加 `[::-1]` 测试
