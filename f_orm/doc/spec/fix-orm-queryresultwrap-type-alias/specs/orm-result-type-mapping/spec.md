# Spec Delta

## Purpose

规定 `f_orm` 结果集包装层接受的列类型名范围（`std.database.sql` 抽象名与仓颉类型名）、各类型名对应的读取类型、未识别类型名的兜底行为，以及结果集读取接口的兼容边界。

## ADDED Requirements

### Requirement: 类型名只接受 std 抽象名与仓颉类型名

系统 SHALL 只把 `std.database.sql` 的抽象类型名（`Sql*`）与仓颉类型名识别为列类型，并把它们映射到固定的读取类型。

#### Scenario: 抽象名映射

- **WHEN** typeName 为 `SqlChar` / `SqlVarchar` → 读取 `String`；`SqlClob` / `SqlBlob` → `InputStream`；`SqlBinary` / `SqlVarBinary` → `Array<Byte>`；`SqlDecimal` → `Decimal`；`SqlBool` → `Bool`；`SqlByte` → `Int8`；`SqlSmallInt` → `Int16`；`SqlInteger` → `Int32`；`SqlBigInt` → `Int64`；`SqlReal` → `Float32`；`SqlDouble` → `Float64`；`SqlDate` / `SqlTime` / `SqlTimeTz` / `SqlTimestamp` → `DateTime`；`SqlInterval` → `Duration`
- **THEN** 以对应读取类型取值 SHALL 返回该列的驱动值

#### Scenario: 仓颉类型名映射

- **WHEN** typeName 为 `String` → `String`；`InputStream` / `std.io.InputStream` → `InputStream`；`Array<Byte>` / `Array<UInt8>` → `Array<Byte>`；`Decimal` / `std.math.numeric.Decimal` → `Decimal`；`Bool` → `Bool`；`Int8` → `Int8`；`UInt8` / `Byte` → `UInt8`；`Int16` → `Int16`；`UInt16` → `UInt16`；`Int32` → `Int32`；`UInt32` → `UInt32`；`Int64` → `Int64`；`UInt64` → `UInt64`；`Float32` → `Float32`；`Float64` → `Float64`；`DateTime` / `std.time.DateTime` → `DateTime`；`Duration` → `Duration`
- **THEN** 以对应读取类型取值 SHALL 返回该列的驱动值

### Requirement: SQL 与方言拼写按未识别类型处理

系统 SHALL NOT 为抽象名与仓颉类型名之外的拼写（`text`、`varchar`、`char`、`string`、`numeric`、`bool`、`bytea`、`int4`、`float8`、`timestamptz`、空串等）建立专门映射，这些拼写 SHALL 按未识别类型处理。

#### Scenario: 半方言拼写不再被识别

- **WHEN** 列 typeName 为 `numeric` 而驱动值为 `Decimal`，或 typeName 为 `bool` 而驱动值为 `Bool`
- **THEN** 以 `Decimal` / `Bool` 取值 SHALL 抛 `ORMException`（按未识别类型走兜底，兜底取不到该值）

#### Scenario: 未识别拼写仍按 String 兜底

- **WHEN** 列 typeName 为 `text` 而驱动值为 `String`
- **THEN** `getOrNull<String>` 返回该字符串（未识别类型的既有兜底口径）

### Requirement: 未识别类型名的兜底口径不变

系统 SHALL 继续把未识别类型名按 `String` 读取：驱动值为字符串时取值成功，驱动值不是字符串时按既有兜底失败（`getOrNull` 与 `get` 均抛 `ORMException`），不得改为其他类型或静默返回 `None`。

#### Scenario: 完全未知的类型名

- **WHEN** 列 typeName 为 `weird_unknown_type`，驱动值为 `String`
- **THEN** `getOrNull<String>` 返回该字符串

#### Scenario: 未知类型名遇到非字符串值

- **WHEN** 列 typeName 未识别，驱动值不是 `String`
- **THEN** 取值抛 `ORMException`

### Requirement: 读取接口保持向后兼容

系统 SHALL 保持结果集读取接口的签名与语义不变：按索引取值、按列名取值、`get` / `getOrNull` / `toMap` / `columnInfos` / `next` / `close` 的行为不变，不新增公开 API。

#### Scenario: 按索引与按列名同源

- **WHEN** 调用方分别用列索引和列名读取同一列
- **THEN** 两次返回相同的值

#### Scenario: 公开签名的调用方式不变

- **WHEN** 已有代码以 `getOrNull<Array<Byte>>(index)` 或 `getOrNull<Array<Byte>>(columnName)` 读取二进制列
- **THEN** 无需修改调用方式即可编译并按既有语义取值
