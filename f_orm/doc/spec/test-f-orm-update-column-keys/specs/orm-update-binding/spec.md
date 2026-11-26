# orm-update-binding

## Purpose

定义 `f_orm` UPDATE 的列名解析与参数绑定契约：Column 键重载与 `Map<String, Any>` 版本产生完全相同的 SQL 与参数，字段名键与数据库列名键都能解析到同一列。

## ADDED Requirements

### Requirement: Column 键重载等价

以 `Column` 为键的四个 UPDATE 重载（数组/映射 × 带 id/不带 id）SHALL 先按 `Column.name` 转成字符串键，再走与 `Map<String, Any>` 版本相同的 SQL 构建与参数绑定逻辑。生成的 SQL 文本、占位符顺序与绑定参数 MUST 逐项一致。

#### Scenario: 数组键不带 id

- **WHEN** 调用 `UPDATE<T>(values: Array<(Column, Any)>)`，传入可更新列与主键列
- **THEN** SQL 与绑定参数和同一组键值的 `Map<String, Any>` 调用完全一致

#### Scenario: 数组键带 id

- **WHEN** 调用 `UPDATE<T, ID>(values: Array<(Column, Any)>, id)`
- **THEN** `WHERE` 使用显式 `id` 作为参数，SQL 与映射版本一致

#### Scenario: 映射键

- **WHEN** 调用 `UPDATE<T>(values: Map<Column, Any>)`
- **THEN** SQL 与参数和对应的 `Map<String, Any>` 调用完全一致

#### Scenario: 映射键带 id

- **WHEN** 调用 `UPDATE<T, ID>(values: Map<Column, Any>, id)`
- **THEN** SQL 与参数和对应的 `Map<String, Any>` 调用完全一致

### Requirement: 字段名与列名双键解析

UPDATE 的键查找 SHALL 同时支持实体字段名与数据库列名。两者指向同一列时，生成的 SQL MUST 相同。

#### Scenario: 字段名键

- **WHEN** 传入 `Column('nick')`，而该字段映射到列 `nick_name`
- **THEN** SQL 使用列 `nick_name`，与传入 `Column('nick_name')` 的结果一致

#### Scenario: 列名键

- **WHEN** 传入 `Column('nick_name')`
- **THEN** SQL 与参数与字段名键的结果逐项一致
