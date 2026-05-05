# migro 模块静态诊断报告

> 审查日期: 2026-05-05
> 审查范围: `./f_orm/src/migro/` (6 个源文件, 584 行)
> 状态: 所有 P0-P3 问题全部修复

---

## 已修复的问题

| 等级 | 问题 | 修复内容 |
|------|------|---------|
| P1 | MariaDBSchemaFinder.driverName 冲突 | 改为 `'mariadb'` |
| P1 | generateDropTableSql 从未被调用 | 新增 `listTables()` + 实现 + mediator 调用 |
| P1 | Postgres ALTER COLUMN 缺列名 | 4 处补 `alter column ${name}` |
| P1 | Postgres 缺失 TYPE 变更 | 增加 `ALTER COLUMN ... TYPE` |
| P2 | 重复 HashMap fold 模式 | 提取 `indexColumns()` / `indexIndexes()` 辅助方法 |
| P3 | 重命名 default/extra 用旧列值 | MysqlSchema.cj:120 改为用新列 |
| P3 | 默认值引号未转义 | 添加 `esc()` 函数，修复 MySQL+Postgres 共 10 处 |
| P4 | SchemaFinder.cj 残留注释 | 待清理 |
| P4 | listTables PO 膨胀 | 待优化 |
| P4 | MigroCommand struct 注册 | 待评估 |

## 测试

- **migro_test.cj**: 12 个 DDL 生成测试用例（CREATE/DROP/ALTER/INDEX MySQL + Postgres）
