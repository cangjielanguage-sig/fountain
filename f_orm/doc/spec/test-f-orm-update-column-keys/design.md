# 设计：保留 Column 键等价回归，停止 local 化

## Context

见 `proposal.md`。关键证据：

| 项 | 结果 |
| --- | --- |
| 独立探针：3 键 `HashMap<String, Any>` | 普通 1,542 B/次；`@ local!` 120 B/次 |
| 真实代码：`values2[k.name] = v` | `cannot assign to this subscript expression`（4 处） |
| 真实代码：`arg(v)`（`v` 来自 local 映射） | `mismatched types`（3 处，local `Any` → 堆参数） |
| 真实代码：`arg(values[idColumn])` | `unable to infer generic argument` |
| mock 下每次 UPDATE 总分配 | 16,763 B；中间映射 1,542 B（9%） |

独立探针能跑，是因为 `HashMap<String, Int64>` 的值是值类型；一旦值是 `Any`，local 限定会附着在读出结果上，既不能写回下标，也不能交给 `arg(Any)`。

## Goals / Non-Goals

**Goals：**
- 用测试锁住四个 Column 键重载与 `Map<String, Any>` 版本的等价性（此前零覆盖）。
- 在审计表记录阻断原因与收益上限，避免后续重复尝试。

**Non-Goals：**
- 不改 `SqlPartial.cj` 与 `f_orm/cjpm.toml`。
- 不启用 local mode。
- 不做「去掉中间映射」的结构性重构（见 D1 的替代方案）。

## Decisions

### D1 停止 local 化，记录阻断

收益上限 9%，且阻断来自类型系统（非写法）。继续投入需要改公开重载主体或引入查找函数抽象，风险与收益不匹配。

**替代方案（否决）**：去掉中间 `HashMap`，改为私有 helper + 查找闭包：
- 需要保留「重复键 last-wins」语义（当前 `values2` 是 HashMap，重复列名后者覆盖前者）；
- 需要保留「既无 field 键也无 column 键」时 `values[idColumn]` 的异常行为；
- 需要为数组/映射各写一套查找，并新增重复键、缺键用例；
- 收益仍是约 1.5 KB/次（相对 DB I/O 可忽略）。

### D2 新增等价回归测试

`f_orm/src/base/SqlPartialColumnKey_test.cj`：

- 实体 `OrmUpdateProbe`：`id`（主键）、`name`、`age`、`nick`（列名 `nick_name`，用于双键解析）。
- `MOCKDB.execution` 捕获 SQL 与参数；每次调用前重置参数窗口。
- 5 条用例：
  1. `Array<(Column, Any)>` vs `Map<String, Any>`；
  2. `Array<(Column, Any)>, id` vs `Map<String, Any>, id`；
  3. `Map<Column, Any>` vs `Map<String, Any>`；
  4. `Map<Column, Any>, id` vs `Map<String, Any>, id`；
  5. 字段名键 `nick` 与列名键 `nick_name` 产生相同 SQL。
- 比较口径：SQL 文本逐字符相等、绑定参数按文本逐项相等。

### D3 审计表回写

`docs/LocalMode.md` 的 f_orm 行改为「不改：local 化被 `Any` 的 local 限定阻断；中间映射占单次 UPDATE 分配约 9%」，并注明已补等价回归。

## Risks / Trade-offs

| 风险 | 处理 |
| --- | --- |
| 测试依赖 `MOCKDB` 与执行器线程态 | 每次用例重新 `ORM.register` + `MOCKDB.clear`，参数窗口按调用切分 |
| SQL 文本随方言变化 | 不做字面量断言，只与同一次测试内的字符串键版本对比 |
| 实体/列名改动导致测试失效 | 实体与用例同文件，改动时一并可见 |
| 审计结论过期 | 阻断原因与 9% 上限写在文档里，含错误信息 |

## Migration Plan

- 纯测试与文档，无迁移。回退：删除测试文件与文档行。

## Open Questions

无。
