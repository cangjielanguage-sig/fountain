# f-rule-decision-table Specification

## Purpose
定义以决策表形式声明规则的行为契约：表的模型与构建方式、单元格语法、命中策略，以及 CSV 与 XLSX 两种载体的读取与翻译规则。它保证同一张表在任一载体上加载后编译出的规则与执行结果一致，并携带可解释的出处信息。

## Requirements

### Requirement: 表模型与构建 API

`DecisionTable` SHALL 由 `id`、`name`、`version`、`factSpace`、`factType`、`hitPolicy`、`columns`、
`rows`、默认 `salience` 构成；`DecisionTable.builder(id)` SHALL 提供 `name` / `version` /
`factSpace` / `factType` / `hitPolicy` / `salience` / `whenColumn(fieldPath)` / `exprColumn(name)` /
`thenColumn(name)` /
`row(values)` / `row(ruleId, values)` / `build()`。

`when` 是仓颉关键字，列方法统一以 `Column` 结尾。

`TableRow` SHALL 携带 `line`（物理行号，从 1 开始）、`values: Array<?String>`、`ruleId`；
`ColumnKind` SHALL 为 `When / Then / Expr / Salience / Metadata`。

一张表 SHALL 只绑定一个 `factSpace`；所有行编译出的规则 SHALL 属于该空间。

`factType` SHALL 声明该表 `when.*` 列作用的事实类型；未声明时，若该空间恰好只有一个已注册类型则 SHALL
自动取之，否则构建期抛 `RuleException(TABLE_INVALID)` 并提示补 `factType`。理由：`when.<field>` 只给出
字段路径，无法唯一确定 `typeTag`，隐式猜测会在多类型空间产生歧义。

#### Scenario: 缺 factType 且多类型

- **WHEN** `pricing` 空间注册了 `Order` 与 `Coupon`，表未声明 `factType`
- **THEN** 构建期抛 `RuleException(TABLE_INVALID)`，message 含 `factType`

#### Scenario: 单类型自动推断

- **WHEN** `orders` 空间只注册了 `Order`
- **THEN** 表自动使用 `Order` 作为 `typeTag`，编译成功

### Requirement: 单元格语法

条件单元格 SHALL 支持：`<op> <value>`、裸 `<value>`（等价 `Eq`）、`-`（不约束，等价 null）、
`== /=`、`!=`、`> >= < <=`、`in [..]`、`not in [..]`、`between [..]`、`contains`、`startsWith`、
`endsWith`、`matches`、`null`（`IsNull`）、`not null`（`NotNull`）。

输出单元格 SHALL 支持字面量、`${binding.field}`、`${binding}`；`${...}` SHALL 在编译期解析为字段引用，
运行时从绑定取值；引用的绑定 SHALL 是该行条件中出现的绑定，否则构建期抛 `RuleException(UNKNOWN_BINDING)`。

`expr` 列单元格 SHALL 是裸布尔表达式，构建期按 `FactType` 与绑定名包装成 lambda 后编译，
失败抛 `RuleException(SCRIPT_COMPILE)`。

值解析 SHALL 按字段声明的 `FieldType` 进行（`Number` 整数优先、含 `.`/`e` 转浮点；`Text` 去引号；
`Bool` 大小写不敏感；`Time` 接受 ISO-8601；`List` 解析 `[a, b]`；`Any` 按字面量推断），
解析失败抛 `RuleException(TYPE_MISMATCH)`。

#### Scenario: 算子单元格

- **WHEN** 条件列为 `when.order.level`，单元格为 `>=3`
- **THEN** 编译为 `Constraint("level", Ge, Const(3))`（T-05）

#### Scenario: 输出取字段

- **WHEN** 输出单元格为 `${o.level}`
- **THEN** 运行时输出该绑定的 `level` 字段值（T-06）

#### Scenario: 未声明绑定

- **WHEN** 输出引用 `${u.name}`，但该行条件没有绑定 `u`
- **THEN** 构建期抛 `RuleException(UNKNOWN_BINDING)`

### Requirement: 命中策略

`HitPolicy` SHALL 支持 `Unique`、`First`（默认）、`Priority`、`Any`、`Collect`、`RuleOrder`、`OutputOrder`，
0/1/N 行命中的行为 SHALL 等于 `doc/07-decision-table.md` §2 的表格：

| 策略 | 0 行 | 1 行 | N 行 |
|---|---|---|---|
| `Unique` | `TABLE_NO_MATCH` | 返回 | `TABLE_MULTI_MATCH` |
| `First` | 空 | 返回 | 第一行 |
| `Priority` | 空 | 返回 | 按 `outputOrder` 取最小 |
| `Any` | 空 | 返回 | 输出一致才返回，否则 `TABLE_MULTI_MATCH` |
| `Collect` | 空 | 返回 | 全返回（行序） |
| `RuleOrder` | 空 | 返回 | 全返回（salience 降序） |
| `OutputOrder` | 空 | 返回 | 全返回（输出值排序） |

`hitPolicy` SHALL 不进入单条 `Rule`，由 `TableExecutor` 在收集命中后应用。

#### Scenario: Unique 零命中

- **WHEN** `Unique` 表无行命中
- **THEN** 抛 `RuleException(TABLE_NO_MATCH)`（T-07）

#### Scenario: Unique 多命中

- **WHEN** `Unique` 表两行命中
- **THEN** 抛 `RuleException(TABLE_MULTI_MATCH)`（T-08）

#### Scenario: Any 输出冲突

- **WHEN** `Any` 表两行命中但输出不同
- **THEN** 抛 `RuleException(TABLE_MULTI_MATCH)`（T-11）

### Requirement: CSV 载体

`CsvTableParser.parse(text)` / `parseFile(path)` SHALL 解析 CSV：`# key: value` 行作为表属性，
其余 `#` 行为注释；第一行非注释行为表头；`id` / `name` 列可选（缺省按数据行号生成 `R1`、`R2`…）；
空单元格表示不约束或不输出。

解析 SHALL 遵循 RFC 4180：含逗号/引号/换行的单元格用双引号包裹，内部引号写作 `""`，行尾接受
`\r\n` 与 `\n`。只接受 UTF-8：检测到 BOM 跳过，检测到非 UTF-8 抛 `RuleException(TABLE_INVALID)`。
列数不一致、未知表头列、非法算子 SHALL 抛 `RuleException(TABLE_INVALID)` 并携带 `line` 与 `column`。

#### Scenario: 引号转义

- **WHEN** 单元格内容为 `a,"b"`（含逗号与引号）
- **THEN** 解析出的值与原值一致（T-02）

#### Scenario: 列数不一致

- **WHEN** 第 5 行少一列
- **THEN** 抛 `RuleException(TABLE_INVALID)`，message 含 `line=5`

#### Scenario: BOM

- **WHEN** 文件以 UTF-8 BOM 开头
- **THEN** 正常解析，表头首列名不带 BOM 字符

### Requirement: XLSX 载体（硬依赖 f_excel）

`XlsxTableParser` SHALL 只通过 `fountain::f_excel` 的读取 API 读取（`ExcelDocument(Path)` /
`ExcelSheetStream.open(Path)`），SHALL NOT 自行解析 OOXML、SHALL NOT 把 `ExcelDocument` /
`CellValue` 泄漏进 `DecisionTable` 模型。

解析规则 SHALL 为：sheet 名为表 `id`；第 1 行表头（`id`/`name`/`when.*`/`then.*`/`expr.*`/`salience`）；
第 2 行可选类型行（`number/text/bool/time/list`）；第 3 行起数据；合并单元格取左上角值；
表属性放在名为 `_meta` 的隐藏 sheet（`key` / `value` 两列）。

单元格类型 SHALL 优先取 `CellValue` 变体，其次类型行，最后字段声明；三者冲突时以字段声明为准并记 WARN。
`CellValue.Formula(_, None)`（无缓存值）SHALL 抛 `RuleException(TABLE_INVALID)`；`CellValue.Error` 同理。

`parse(path)` SHALL 返回工作簿内全部决策表；`parse(path, sheet)` 返回单表；`stream(path)` SHALL 返回
逐表迭代器，大表（> 10 万行）SHALL 走 `ExcelSheetStream` 逐行读取、内存恒定、不回写 `rows`。

#### Scenario: 与 CSV 等价

- **WHEN** `pricing.xlsx` 与 `pricing.csv` 内容等价
- **THEN** 两者编译出的 `Rule` 逐字段相同（T-12）

#### Scenario: 合并单元格

- **WHEN** `A3:C3` 合并，左上角为 `">=3"`
- **THEN** 该行三列都取 `">=3"`（T-13）

#### Scenario: 公式无缓存

- **WHEN** 条件单元格是公式且 `CellValue.Formula(_, None)`
- **THEN** 抛 `RuleException(TABLE_INVALID)`

#### Scenario: 流式大表

- **WHEN** 读取 10 万行工作簿的 `stream`
- **THEN** 内存占用不随行数线性增长（T-14）

### Requirement: 编译与校验清单

`DecisionTable.compile(ruleSet)` SHALL 输出 `Array<Rule>`：`factSpace` 属性 → `Rule.factSpace`；
`when.<field>` → `Pattern(factType, binding).constrain(...)`（`where` 是关键字）；`expr.<name>` → `ConditionExpr.Script`；
`then.<name>` → `TableAction` 写输出槽；`id` 列 → `Rule.id`；`salience` 列 → `Rule.salience`。

构建期 SHALL 通过 `doc/07-decision-table.md` §8 的校验清单：表头列名合法（`TABLE_INVALID`）、
`when.*` 字段可解析（`UNKNOWN_FIELD`）、算子可解析（`TABLE_INVALID`）、值可解析为字段类型
（`TYPE_MISMATCH`）、`${}` 绑定存在（`UNKNOWN_BINDING`）、`salience` 可解析（`TABLE_INVALID`）、
`Unique` 下无两行条件完全相同（`TABLE_INVALID`）、无数据行（`TABLE_INVALID`）、列数一致。

#### Scenario: 空表

- **WHEN** CSV 只有表头没有数据行
- **THEN** 抛 `RuleException(TABLE_INVALID)`（T-15）

#### Scenario: Unique 重复行

- **WHEN** `Unique` 表两行条件单元格完全相同
- **THEN** 构建期抛 `RuleException(TABLE_INVALID)`

### Requirement: 执行与可解释性

`TableExecutor(table, registry: FactSpaceRegistry).execute(facts: FactBaseView)` SHALL 运行议程并按 `hitPolicy` 聚合输出，
返回 `TableResult(hits, outputs, trace)`。

> 实施修订：入参由 `RuleSet` 收窄为 `FactSpaceRegistry`（`doc/11-assembly.md` S2）。编译器原本只用
> `ruleSet.registry` 一处，收窄后表可脱离完整 `RuleSet` 编译，也是解开 `rule ↔ table` 包循环的前提。

`TableResult.hits` SHALL 是按 `hitPolicy` 处理后的命中行；`outputs` SHALL 单值时 size == 1、
`Collect` 类策略时按行序多条；`trace` SHALL 仅在显式开启 tracing 时非空，且每条 `RowTrace` 记录
每行每个条件列的求值结果，用于回答"为什么这行没命中"。

#### Scenario: 端到端

- **WHEN** 订单 `level=3, amount=500`，表 `First` 且 R1 条件 `>=3, >200`
- **THEN** `outputs[0]["discount"] == 0.85`，`hits[0].ruleId == "R1"`（I-01）

#### Scenario: 收集多行

- **WHEN** `Collect` 表三行命中
- **THEN** `outputs.size == 3`，顺序与行序一致（T-10）

#### Scenario: 追踪

- **WHEN** 开启 tracing 后某行未命中
- **THEN** `trace` 中该行对应条件列的 `result` 为 false 或 unknown，且带列名
