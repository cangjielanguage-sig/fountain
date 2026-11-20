# Proposal

## Why

`f_orm` 模块 `cjpm test` 失败：`QueryResultWrapTest.testEveryReaderBranchAndAlias` 报 `ORMException`（列索引 5，`typeName` 为 `bytea`，要求 `Array<UInt8>`）。失败原因是**用例喂了契约外的列类型名**：`QueryResultWrap` 用 `result.columnInfos[i].typeName` 选读取类型，而本仓三个驱动（`pgsql`、`postgres_driver`、`mysql`）上报的 `typeName` 都是**仓颉类型名**（`Int32` / `String` / `Array<Byte>` / `DateTime` / `Decimal` …），原生数据库类型名放在 `databaseTypeName`；`fdbm` 构造列信息前还会再走一次 `SqlTypes.canonicalName` 归一。用例里的 `bytea` / `money` / `int4` / `float8` / 空串属于已被 `2b4940693` 删除的方言别名，只有用例还在使用。

同时，`makeReader` 里仍残留半套 SQL 拼写（`text` / `varchar` / `char` / `string` / `numeric` / `bool`），与同文件 `toMap()` 的命名口径（只认 `std.database.sql` 抽象名 `Sql*` 与仓颉类型名）不一致：同一份类型名在两处得到不同结论，容易让人误以为方言拼写仍受支持。

## What Changes

- **清理 `QueryResultWrap.makeReader` 中残留的方言 / 小写拼写**，使类型名集合收敛为「`std.database.sql` 抽象名（`Sql*`）+ 仓颉类型名」：
  - 删除 `string`、`char`、`text`、`varchar`（`String` 分支）
  - 删除 `numeric`（`Decimal` 分支）
  - 删除 `bool`（`Bool` 分支）
  - 保留：全部 `Sql*` 抽象名、`String`/`Int8`/`UInt8`/`Byte`/`Int16`/`UInt16`/`Int32`/`UInt32`/`Int64`/`UInt64`/`Float32`/`Float64`/`Bool`/`Decimal`/`std.math.numeric.Decimal`/`DateTime`/`std.time.DateTime`/`Duration`/`InputStream`/`std.io.InputStream`/`Array<Byte>`/`Array<UInt8>`
- **不恢复** `2b4940693` 删除的方言别名：`bytea`、`money`、`int2`、`int4`、`int8`、`float4`、`float8`、`date`、`time`、`timetz`、`timestamptz`、空串、`interval`、`name`、`bpchar`、`json`、`jsonb`、`xml`、`uuid`。
- **修正既有宽用例** `testEveryReaderBranchAndAlias`：把 6 处契约外 typeName 换成契约写法（`text`→`String`、`bytea`→`Array<UInt8>`、`money`→`Decimal`、`int4`→`UInt32`、`float8`→`Float64`、空串→`std.time.DateTime`），分支覆盖不减少。
- **新增一条用例**钉住「SQL / 方言拼写按未识别类型处理」：`numeric` / `bool` 列取值抛 `ORMException`，`text` 列按未知名兜底以 `String` 读出。
- **不改**：公开 API（`get` / `getOrNull` / `toMap` / `columnInfos` / `next` / `close` 的签名与返回语义）；`toMap()` 的类型名判定；未知名走 `String` 兜底的既有语义；`getOrNull` 的兜底异常文案；`f_orm` 的依赖与模块结构。

## Capabilities

### New Capabilities

- `orm-result-type-mapping`: 结果集列类型名的契约（只接受 `std.database.sql` 抽象名与仓颉类型名）、各拼写到读取类型的映射，以及未识别类型名的兜底行为。

### Modified Capabilities

（无）

## Impact

- 代码：`f_orm/src/wrap/QueryResultWrap.cj`（`makeReader` 删 6 个拼写）、`f_orm/src/wrap/QueryResultWrap_test.cj`（改 6 处输入、新增 1 条用例）。
- 公开 API：无变化；不新增、不修改签名。
- 行为变化：以 SQL / 方言拼写上报 `typeName` 的调用方（本仓三个驱动均不如此）会落到 `String` 兜底 —— 这类输入本就不在契约内，用户已明确「驱动只返回仓颉类型名」。
- 依赖 / 模块结构 / 配置项：无变化。
- 文档：`README.md` / `README_en.md` 未记录 `typeName` 拼写清单，公开 API 不变，本轮不改文档。
