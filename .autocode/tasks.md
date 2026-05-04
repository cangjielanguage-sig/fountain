# DataPath RFC 9535 改进计划

## 执行顺序
每完成一步执行收尾仪式：加测试 → ✅标记 → /exp → 提交

---

### Step 1: 数组切片缺省值 + 负步长 ✅
- 21/21 基本测试通过
- RangePathNode 改为三个字段 (start/end/step)
- 支持 [n:m], [:n], [n:], [:], [n:m:step], [4:0:-1], [0:3:0]

### Step 2: `..[*]` 完整语法 ✅
- 44/44 全部测试通过
- `..*`: 自动消费后续 MUL 标记
- `..name`: IDENTIFIER 紧跟 RANGEOP 时转为 SubPathNode
- `..[selectors]`: RANGEOP/DOT 作为 LSQUARE 的前驱标记

### Step 3: 存在性测试
- 新建 `ExistsFilter.cj`
- `parseFilterTokens` AT 分支：无操作符时生成存在性测试
- `compileFilter` 添加 ExistsFilter 分支

### Step 4: `null` 字面量过滤
- 新建 `NullFilter.cj`
- 支持 `?(@.name == null)`, `?(@.name != null)`

### Step 5: 函数扩展 `count()`, `match()`, `search()`, `value()`
- 新建 filter 类
- `parseFilterTokens` 和 `compileFilter` 添加函数名分支

### Step 6: 遗留问题
- `[::-1]` 缺省值支持
- RegexFilter 修复（std.regex.matches 行为）
