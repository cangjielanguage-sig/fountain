# 07 决策表

## 1. 模型

```
DecisionTable
├── id: String
├── name: String
├── version: String
├── factSpace: String           # 整表绑定的事实库空间，缺省 "default"
├── hitPolicy: HitPolicy
├── columns: Array<Column>
└── rows: Array<TableRow>
```

一张决策表只能绑定一个 `factSpace`：所有行编译出的规则属于同一空间。需要跨空间时拆成多张表，各自 `.factSpace(...)`。

`Column`：

```cangjie
public enum ColumnKind {
    | When        // 条件列：when.<字段路径>
    | Then        // 输出列：then.<输出名>
    | Expr        // 表达式条件列
    | Salience    // 优先级列
    | Metadata    // 规则 id / 名称 / 说明 / 启用开关
}
```

`TableRow` 表示一行，即一条规则：

```cangjie
public class TableRow {
    /** 行号，从 1 开始（含表头行），用于报错定位。 */
    public let line: Int64
    public let values: Array<?String>
    public let ruleId: String
}
```

## 2. 命中策略

```cangjie
public enum HitPolicy <: ToString {
    /** 只允许一行命中；零命中或多命中都抛错。 */
    | Unique
    /** 按行序取第一条命中。 */
    | First
    /** 按输出列的优先级顺序取（需声明 outputOrder）。 */
    | Priority
    /** 任意多行命中，但所有输出必须一致，否则抛错。 */
    | Any
    /** 收集所有命中的输出，按行序。 */
    | Collect
    /** 收集所有命中的输出，按 salience 降序。 */
    | RuleOrder
    /** 收集所有命中的输出，按输出值排序。 */
    | OutputOrder
}
```

| 策略 | 命中 0 行 | 命中 1 行 | 命中 N 行 |
|---|---|---|---|
| `Unique` | `TABLE_NO_MATCH` | 返回 | `TABLE_MULTI_MATCH` |
| `First` | 返回空 | 返回 | 取第一行 |
| `Priority` | 返回空 | 返回 | 按 outputOrder 取最小 |
| `Any` | 返回空 | 返回 | 输出一致才返回，否则 `TABLE_MULTI_MATCH` |
| `Collect` | 返回空 | 返回 | 全返回（数组） |
| `RuleOrder` | 返回空 | 返回 | 全返回（按 salience） |
| `OutputOrder` | 返回空 | 返回 | 全返回（按输出值排序） |

默认 `First`。理由：业务最常用，行为最可预测。

### 2.1 两条执行路径下的差异

上表描述的是**聚合路径**（`RuleEngine.executeTable`，整表求值）。决策表也可以编译成规则进议程（`RuleSetBuilder.table`），此时 `HitPolicy` 由 `activationGroup` + `salience` 表达，有三项降级：

| 策略 | 聚合路径 | 议程路径 |
|---|---|---|
| `Unique` | 零/多命中均抛错 | 同组只执行一条；运行期**不报错**（构建期仍查重复行） |
| `First` / `Collect` / `RuleOrder` | 见上表 | 等价 |
| `Priority` | 按 `outputOrder` 取最小 | **降级为行序**：议程的比较键不含运行期输出值 |
| `Any` | 多命中校验输出一致 | 不校验 |
| `OutputOrder` | 按输出值排序 | **按行序**执行 |

需要完整语义时用聚合路径。两条路径对同一张表**互斥**，跨用抛 `TABLE_MODE_CONFLICT`。详见 [11-assembly.md](11-assembly.md) §4.4、§4.5。

## 3. 构建 API

```cangjie
public class DecisionTable {
    public static func builder(id: String): DecisionTableBuilder
    public prop id: String
    public prop factSpace: String
    public prop hitPolicy: HitPolicy
    public prop columns: Array<Column>
    public prop rows: Array<TableRow>
    /** 编译成规则。构建期做全量校验。 */
    public func compile(ruleSet: RuleSet): Array<Rule>
}

public class DecisionTableBuilder {
    public func name(name: String): DecisionTableBuilder
    public func version(version: String): DecisionTableBuilder
    /** 整表绑定事实库空间，缺省 "default"。 */
    public func factSpace(space: String): DecisionTableBuilder
    public func hitPolicy(policy: HitPolicy): DecisionTableBuilder
    public func salience(default: Int64): DecisionTableBuilder

    /** 条件列。 */
    public func when(fieldPath: String): DecisionTableBuilder
    /** 表达式条件列。 */
    public func expr(name: String): DecisionTableBuilder
    /** 输出列。 */
    public func then(name: String): DecisionTableBuilder

    /**
     * 追加一行。值的顺序与列声明顺序一致；null 表示该条件不约束。
     */
    public func row(values: Array<?String>): DecisionTableBuilder
    public func row(ruleId: String, values: Array<?String>): DecisionTableBuilder

    public func build(): DecisionTable
}
```

示例：

```cangjie
let table = DecisionTable.builder("pricing")
    .name("订单折扣")
    .version("v1")
    .hitPolicy(HitPolicy.First)
    .when("order.level")
    .when("order.amount")
    .then("discount")
    .then("event")
    .row("R1", [">=3", ">200", "0.85", "order.discounted"])
    .row("R2", [">=1", ">500", "0.90", "order.discounted"])
    .row("R3", [null, null, "1.0", "order.discounted"])
    .build()

let rules = table.compile(ruleSet)
```

## 4. 单元格语法

### 4.1 条件单元格

```
<op> <value>          # 显式算子
<value>               # 等价于 == <value>
-                     # 不约束（等价于 null）
```

算子写法：

| 写法 | 等价 |
|---|---|
| `== 3` / `= 3` | `Eq` |
| `!= 3` | `Ne` |
| `> 200` / `>= 200` / `< 200` / `<= 200` | 对应算子 |
| `in [A, B, C]` | `In` |
| `not in [A, B]` | `NotIn` |
| `between [1, 100]` | `Between` |
| `contains foo` | `Contains` |
| `startsWith foo` | `StartsWith` |
| `endsWith foo` | `EndsWith` |
| `matches ^[A-Z]+$` | `Matches` |
| `null` | `IsNull` |
| `not null` | `NotNull` |

值类型推断（按字段声明的 `FieldType`）：

| `FieldType` | 解析规则 |
|---|---|
| `Number` | `Int64` 优先，含 `.` 或 `e` 时 `Float64` |
| `Text` | 原样，去掉包裹的单/双引号 |
| `Bool` | `true` / `false`（大小写不敏感） |
| `Time` | ISO-8601 `yyyy-MM-dd HH:mm:ss` 或 `yyyy-MM-dd` |
| `List` | `[a, b, c]` |
| `Any` | 按字面量推断：数字 → 布尔 → 时间 → 字符串 |

### 4.2 输出单元格

```
<literal>             # 常量
${<binding>.<field>}  # 从事实取值
${<binding>}          # 整个事实
```

示例：

```cangjie
.row("R4", [">=3", null, "${o.level}", "order.discounted"])
```

`${...}` 在编译期解析成 `FieldRef`，运行期从绑定取值。引用的绑定必须是该行条件中出现的模式绑定，否则构建期抛 `UNKNOWN_BINDING`。

### 4.3 表达式单元格

`expr` 列的单元格是一段 f_jit 源码（或内置解释器语法）：

```
o.amount > 200 && o.level >= 3
```

构建期编译，失败抛 `SCRIPT_COMPILE`。

## 5. CSV 载体

### 5.1 格式

```csv
# f_rule decision table v1
# id: pricing
# name: 订单折扣
# version: v1
# factSpace: orders
# hitPolicy: First
# salience: 100
id,name,when.order.level,when.order.amount,then.discount,then.event
R1,VIP 大额,>=3,>200,0.85,order.discounted
R2,普通大额,>=1,>500,0.90,order.discounted
R3,兜底,,,1.0,order.discounted
```

规则：

1. 以 `#` 开头的行是注释 / 元数据；`# key: value` 形式被解析为表属性；
2. 第一行非注释行是表头；
3. `id` 列可选；缺省时按行号生成 `R1`、`R2`…（跳过注释行计数）；
4. `name` 列可选，仅用于可读性；
5. 空单元格 = 不约束（条件列）/ 不输出（输出列）；
6. 字段路径用 `.` 分隔：`when.<binding>.<field>` 或 `when.<field>`（单模式规则可省略 binding）；
7. 输出列同理：`then.<name>`；
8. `factSpace` 缺省为 `default`；值必须是 `RuleSet` 已声明或即将声明的空间。

### 5.2 转义

遵循 RFC 4180：

- 含逗号、引号、换行的单元格必须用双引号包裹；
- 单元格内的双引号写作 `""`；
- 行尾允许 `\r\n` 或 `\n`。

### 5.3 解析器

```cangjie
public class CsvTableParser {
    public static func parse(text: String): DecisionTable
    public static func parseFile(path: Path): DecisionTable
}
```

错误定位：`RuleException(TABLE_INVALID)` 携带 `line`（物理行号）与 `column`（列名）。

### 5.4 BOM 与编码

只接受 UTF-8。检测到 BOM 时跳过；检测到非 UTF-8 字节序列抛 `TABLE_INVALID`。

## 6. XLSX 载体

### 6.1 结构

| 元素 | 约定 |
|---|---|
| Sheet 名 | 决策表 id；一个工作簿可含多张表 |
| 第 1 行 | 表头：`id`、`name`、`when.*`、`then.*`、`expr.*`、`salience` |
| 第 2 行（可选） | 类型行：`number`、`text`、`bool`、`time`、`list`，用于覆盖字段类型推断 |
| 第 3 行起 | 数据行 |
| 单元格批注 | 作为该列的说明，解析时忽略 |
| 合并单元格 | 只取左上角值；合并区域视为同一值 |

表属性放在工作簿自定义属性或名为 `_meta` 的隐藏 sheet：

```
key         | value
id          | pricing
version     | v1
factSpace   | orders
hitPolicy   | First
salience    | 100
```

### 6.2 解析器

```cangjie
public class XlsxTableParser {
    public static func parse(path: Path): Array<DecisionTable>
    public static func parse(path: Path, sheet: String): DecisionTable
    /** 流式读取，适合大表；内存恒定。 */
    public static func stream(path: Path): Iterator<DecisionTable>
}
```

依赖 `f_excel` 的 `ExcelDocument` 与 `ExcelSheetStream`：

```cangjie
let doc = ExcelDocument(Path("rules.xlsx"))
let sheet = doc.sheet("pricing").getOrThrow()
let name = sheet.cell("A1")
```

### 6.3 类型推断

Excel 单元格本身带类型（`CellValue.Number` / `.Text` / `.Bool` / `.Date`），优先用单元格类型，其次用类型行，最后用字段声明。三者冲突时以**字段声明**为准并记 `WARN`。

### 6.4 大表

超过 10 万行时：

1. 用 `ExcelSheetStream` 逐行读，不整体加载；
2. 逐行编译为 `Rule`，直接注入 `RuleSet`，不回写 `DecisionTable.rows`；
3. 构建期不做跨行去重（`Unique` 策略的运行期检查仍然生效）。

## 7. 编译

```
DecisionTable
   │ 校验（列名、算子、类型、绑定引用）
   ▼
Array<Rule>（每条规则 = 一个模式 + 一组约束 + 一组输出动作）
   │
   ├── 直接进 RuleSet（产生式模式）
   └── 每条 Rule 生成一个 RuleFlow（决策流模式）
```

`Rule` 的映射：

| 决策表元素 | Rule 元素 |
|---|---|
| `factSpace` 属性 | `Rule.factSpace`（整表统一） |
| `when.<field>` 列 | `Pattern(typeTag, binding).where(field, op, value)` |
| `expr.<name>` 列 | `ConditionExpr.Script(JitExpression)` |
| `then.<name>` 列 | `TableAction` 写输出槽 `name` |
| `id` 列 | `Rule.id` |
| `salience` 列 | `Rule.salience` |
| `hitPolicy` | 表级，不进单条 Rule；由 `TableExecutor` 在收集结果后应用 |

`hitPolicy` 不参与单条规则的匹配，而是在"多行命中"时决定输出。因此 `DecisionTable` 编译出的规则集需要一层结果聚合：

```cangjie
public class TableExecutor {
    public init(table: DecisionTable, ruleSet: RuleSet)
    /** 跑完议程后按 hitPolicy 聚合输出。 */
    public func execute(facts: FactBaseView): TableResult
}
```

## 8. 校验清单

构建期必须全部通过：

| 检查 | 失败码 |
|---|---|
| 表头列名合法（`id`/`name`/`when.*`/`then.*`/`expr.*`/`salience`） | `TABLE_INVALID` |
| `when.*` 的字段路径可解析到已注册类型 | `UNKNOWN_FIELD` |
| 单元格算子可解析 | `TABLE_INVALID` |
| 单元格值可解析为字段声明的类型 | `TYPE_MISMATCH` |
| `${...}` 引用的绑定在该行条件中出现 | `UNKNOWN_BINDING` |
| `salience` 列可解析为 `Int64` | `TABLE_INVALID` |
| `hitPolicy = Unique` 时不存在两行条件完全相同 | `TABLE_INVALID` |
| 空表（无数据行） | `TABLE_INVALID` |
| 列数不一致的行 | `TABLE_INVALID`（带行号） |

## 9. 可解释性

```cangjie
public class TableResult {
    /** 命中的行，按 hitPolicy 处理后的顺序。 */
    public let hits: Array<TableRow>
    /** 最终输出：单值时 size == 1，Collect 类策略时可能多条。 */
    public let outputs: Array<HashMap<String, Any>>
    /** 每行的条件判定明细，仅在 trace 开启时非空。 */
    public let trace: Array<RowTrace>
}
```

`RowTrace` 记录每行每个条件列的求值结果，用于回答"为什么这行没命中"。

## 10. 与 f_excel 的边界

- `f_rule` 只依赖 `f_excel` 的**读取**能力，不写 xlsx；
- 不把 `ExcelDocument`、`CellValue` 泄漏到 `DecisionTable` 模型：解析后立即转成字符串/字面量；
- Excel 的公式不求值：决策表单元格必须是静态值或 `${}` 引用，公式单元格按缓存值读取，无缓存值抛 `TABLE_INVALID`。
