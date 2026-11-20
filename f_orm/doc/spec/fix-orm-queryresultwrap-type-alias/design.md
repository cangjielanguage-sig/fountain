# Design

## Context

见 `proposal.md` — Why。

现状（`f_orm/src/wrap/QueryResultWrap.cj`）：

- 列类型名来自驱动上报的 `result.columnInfos[i].typeName`，构造期快照进 `columns`；取值路径为 `getOrNull<T>` → 首次读某列时用 `makeReader(result, typeName)` 构造该列取值器并缓存进 `list`。
- `makeReader` 是 `private static func`，当前接受三类拼写：`Sql*` 抽象名、仓颉类型名、以及残留的半方言拼写（`string` / `char` / `text` / `varchar` / `numeric` / `bool`）；未命中落 `String` 兜底。
- 同文件的 `toMap()` 是另一张类型名表，只认 `Sql*` 抽象名与仓颉类型名（另含 `Rune` 与 `Nullable/Option` 变体），**从来没有**方言拼写 —— 两份表口径不一致。
- 驱动侧事实（本机中心仓缓存核对）：`pgsql` 的 `PgColumnInfo.typeName` 走 `cangjieTypeName(oid)`（`Int32` / `String` / `Array<Byte>` / `DateTime` / 未知时 `pg_oid_<n>`）；`postgres_driver` 的 `cdbc_column_info.cj` 注明「typeName 是规范类型名（如 `Int64`、`std.time.DateTime`），原生类型名在 `databaseTypeName`」；`mysql` 的 `typeName` 取 `definition.columnType.cangjieType(unsigned)`；`fdbm` 构造列信息前还会走 `SqlTypes.canonicalName` 归一。
- 提交 `83e7547f7`（ORM-2）新增的 `testEveryReaderBranchAndAlias` 用了 `bytea` / `money` / `int4` / `float8` / 空串这些已被 `2b4940693` 删除的方言别名，用例因此变红。

## Goals / Non-Goals

**Goals:**

- 让 `f_orm` 的 `cjpm test` 全绿。
- 把 `makeReader` 的类型名集合收敛为「`Sql*` 抽象名 + 仓颉类型名」，与 `toMap()` 口径一致。
- 用一条用例钉住「SQL / 方言拼写按未识别类型处理」，防止半方言拼写再被加回来。

**Non-Goals:**

- 不恢复 `2b4940693` 删除的任何方言别名（含 `int2`/`int4` → `UInt32`）。
- 不改 `QueryResultWrap` 的公开 API 与返回语义；不改 `toMap()` 的类型名判定。
- 不改未识别类型名走 `String` 兜底的既有口径，不改兜底异常文案。
- 不引入 `f_dbd` 依赖，也不在 `f_orm` 内复制 `SqlTypes` 的归一逻辑。
- 不在驱动侧/上层做类型名归一（三个驱动已上报仓颉类型名，`fdbm` 另有归一路径）。

## Decisions

### 决策 1：删除 `makeReader` 里残留的半方言拼写

- 删除：`string`、`char`、`text`、`varchar`（`String` 分支）、`numeric`（`Decimal` 分支）、`bool`（`Bool` 分支）。
- 理由：与 `toMap()` 的口径对齐，避免"同一份 typeName 在取数与 `toMap()` 两处结论不同"；也和驱动上报形态一致。
- 备选（否决）：保留它们 —— 会让人以为方言拼写仍受支持，与契约矛盾。
- 备选（否决）：恢复 `2b4940693` 删除的全部别名 —— 用户已决策「驱动只返回仓颉类型名」，恢复等于把废弃拼写固化进契约。

### 决策 2：保留 `InputStream`、`Byte`、`Decimal`、`DateTime` 等简单名

- 这些是仓颉类型名（简单名 / 类型别名），不是数据库方言名：`Byte` 是 `UInt8` 的类型别名，`InputStream` 是 `std.io.InputStream` 的简单名；`f_dbd.SqlTypes.canonicalName` 也会原样透传 `std.io.InputStream`。
- 同时保留其全限定写法（`std.io.InputStream`、`std.time.DateTime`、`std.math.numeric.Decimal`），因为驱动可能带包前缀上报。

### 决策 3：修正既有宽用例的 6 处输入

| 列 | 现在 | 改成 | 覆盖分支 |
| --- | --- | --- | --- |
| c1 | `text` | `String` | `String` |
| c5 | `bytea` | `Array<UInt8>` | `Array<Byte>` |
| c7 | `money` | `Decimal` | `Decimal` |
| c14 | `int4` | `UInt32` | `UInt32` |
| c18 | `float8` | `Float64` | `Float64` |
| c20 | 空串 | `std.time.DateTime` | `DateTime` |

- 用例的意图（每个取值器分支至少被一列覆盖）不变，改的只是输入拼写；`c22` 的 `weird_unknown_type` 继续钉住未知名兜底。
- 该用例当前是红的（用户运行输出即 RED 证据），改完转绿。

### 决策 4：新增用例钉住「SQL 拼写按未识别类型处理」，而不是「契约拼写全表」

- 新增 `testSqlSpellingTypeNamesAreTreatedAsUnknown`：
  - `numeric` 列 + `Decimal` 值 → `getOrNull<Decimal>` 抛 `ORMException`；
  - `bool` 列 + `Bool` 值 → `getOrNull<Bool>` 抛 `ORMException`；
  - `text` 列 + `String` 值 → `getOrNull<String>` 返回该字符串（兜底口径）。
- 该用例在清理前**必须先红**（`numeric`/`bool` 现在仍命中分支并返回值），清理后转绿 —— 这是本次唯一可观察的行为变化，符合严格 RED。
- 备选（否决）：「契约拼写全表」的表驱动用例（逐行断言 `Sql*`/仓颉名 → 读取类型）会在改代码前就通过，不能证明任何行为变化，违反严格 RED；这部分覆盖由修正后的 `testEveryReaderBranchAndAlias` 承担。

### 决策 5：不复用 `f_dbd.SqlTypes.canonicalName`

- 理由：① `f_orm` 当前不依赖 `f_dbd`，为一次清理引入模块依赖方向不划算；② `canonicalName` 会把 `TINYINT(1)` 归一成 `Bool`、把 `varchar(80)` 去后缀、对未知名打 WARN —— 这些都属于**新增语义**，与"只接受 `Sql*` 抽象名 + 仓颉类型名"的目标相反。

## Risks / Trade-offs

- [以 SQL 拼写上报 `typeName` 的第三方驱动会退化为 `String` 兜底] → 本仓三个驱动均上报仓颉类型名；若确有此类驱动，应在驱动侧归一并另开变更，不在 `f_orm` 内兜。
- [字符串类拼写（`text`/`varchar`/`char`/`string`）删除后行为与兜底不可区分，测试无法证明其被删] → 由 `testSqlSpellingTypeNamesAreTreatedAsUnknown` 覆盖 `text` 的兜底语义 + 代码审阅（diff 只有字面量删除）。
- [删除 `bool`/`numeric` 对"半方言"输入是行为变化] → 属契约外输入，用户已明确决策；新增用例把这一变化钉住。
- [`toMap()` 与 `makeReader` 仍有两张表，未来可能再次漂移] → 本次只对齐命名口径，不合并实现（合并会改动 `toMap()` 的 `Rune`/`Nullable` 语义）；记录为已知结构性问题。
- [兜底异常消息只带列定位、不转发底层原因（本次故障因此显示 "requires: Array<UInt8>"）] → 保持文案不变；排查时先确认 typeName 是否命中分支。

## Migration Plan

- 无数据迁移、无配置变更、无发布顺序要求。
- 回滚：还原 `makeReader` 的 6 个字面量与用例改动即可（纯代码改动）。
- 发布：合并到 `sts/1.3.x` 后随下次升版发布；发布前 `f_orm` 全量 `cjpm test` 全绿。
