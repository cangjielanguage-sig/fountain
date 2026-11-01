/*
Copyright (c) 2026 WuJingrun（吴京润）

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/
package fountain::f_rule.table

import std.collection.{ArrayList, HashMap}
import std.convert.*
import std.sync.Mutex
import fountain::f_jit.Compiler
import fountain::f_log.LoggerFactory
import fountain::f_rule.condition.{Constraint, JitExpression, Operand, Operator, Pattern}
import fountain::f_rule.exception.{RuleErrorCode, RuleException}
import fountain::f_rule.fact.{Fact, FactSpace, FactSpaceRegistry, FieldType}
import fountain::f_rule.rule.{ActionContext, Rule, RuleAction, Validator}

/** 编译后的一个条件列：`when` 列产出约束，`expr` 列产出 JIT 表达式。 */
public class CompiledCondition {
    public let column: Column
    public let constraint: ?Constraint
    public let expression: ?JitExpression

    init(column: Column, constraint: ?Constraint, expression: ?JitExpression) {
        this.column = column
        this.constraint = constraint
        this.expression = expression
    }

    /** 空单元格表示不约束。 */
    public prop isEmpty: Bool {
        get() {
            constraint.isNone() && expression.isNone()
        }
    }
}

/** 编译后的一个输出列。 */
public class CompiledOutput {
    public let name: String
    public let cell: OutputCell

    init(name: String, cell: OutputCell) {
        this.name = name
        this.cell = cell
    }
}

/** 编译后的一行：规则 + 逐列条件 + 输出解析器。 */
public class CompiledRow {
    public let row: TableRow
    public let rule: Rule
    public let conditions: Array<CompiledCondition>
    public let outputs: Array<CompiledOutput>
    public let salience: Int64

    init(row: TableRow, rule: Rule, conditions: Array<CompiledCondition>,
        outputs: Array<CompiledOutput>, salience: Int64) {
        this.row = row
        this.rule = rule
        this.conditions = conditions
        this.outputs = outputs
        this.salience = salience
    }
}

/** 整表编译结果。 */
public class CompiledTable {
    public let factType: String
    public let binding: String
    public let rows: Array<CompiledRow>
    public let rules: Array<Rule>
    /** 构建期诊断（WARN 级），便于测试与工具展示；不参与编译结果。 */
    public let warnings: Array<String>

    init(factType: String, binding: String, rows: Array<CompiledRow>, rules: Array<Rule>,
        warnings!: Array<String> = Array<String>()) {
        this.factType = factType
        this.binding = binding
        this.rows = rows
        this.rules = rules
        this.warnings = warnings
    }
}

/**
 * 决策表编译器（`doc/07-decision-table.md` §7/§8）。
 *
 * 每行编译为**单模式**规则（设计 D9）：`when.*` → `Pattern(typeTag, binding)` 上的约束，
 * `expr.*` → 脚本条件，`then.*` → 动作写输出槽。校验顺序：
 * 空表 → 类型推断 → 字段/算子/值 → 输出引用 → 行级 salience → `Unique` 重复行。
 */
public class TableCompiler {
    private static let log = LoggerFactory.getLogger<TableCompiler>()
    private static let countMtx = Mutex()
    private static var compileCount_: Int64 = 0
    private let table_: DecisionTable
    private let compiler_: Compiler
    private let space_: FactSpace
    private let factType_: String
    private let hostType_: String
    /** `true` 表示编译结果为议程路径（`RuleSetBuilder.table`），需要提示 HitPolicy 降级。 */
    private let agendaPath_: Bool
    private let warnings_: ArrayList<String>

    /**
     * @param agendaPath 编译目标是议程路径时为 `true`，会对无法完整表达的 HitPolicy 打 WARN；
     *                   `TableExecutor` 的聚合路径传 `false`。
     */
    public init(table: DecisionTable, registry: FactSpaceRegistry, compiler: Compiler,
        agendaPath!: Bool = false) {
        this.table_ = table
        this.compiler_ = compiler
        this.agendaPath_ = agendaPath
        this.warnings_ = ArrayList<String>()
        this.factType_ = table.resolvedFactType(registry)
        this.space_ = match (registry.get(table.factSpace)) {
            case Some(found) => found
            case None =>
                throw RuleException(
                    RuleErrorCode.UNKNOWN_FACT_SPACE,
                    "决策表 ${table.id} 引用了未声明的事实空间 ${table.factSpace}"
                )
        }
        this.hostType_ = match (space_.descriptor(factType_)) {
            case Some(descriptor) => descriptor.hostSimpleName
            case None => ""
        }
    }

    /**
     * 测试观测点：进程内累计编译次数（`doc/11-assembly.md` §7 AS-07）。
     *
     * 不属于稳定 API；生产代码不应依赖。用于断言引擎的执行器缓存只编译一次。
     */
    public static func compileCount(): Int64 {
        synchronized(countMtx) {
            compileCount_
        }
    }

    public func compile(): CompiledTable {
        synchronized(countMtx) {
            compileCount_ += 1
        }
        if (!table_.streaming) {
            if (table_.rows.isEmpty()) {
                throw RuleException(
                    RuleErrorCode.TABLE_INVALID,
                    "决策表 ${table_.id} 没有任何数据行（空表）"
                )
            }
            // 流式表构建期不做跨行去重（`doc/07` §6.4），Unique 的运行期检查仍然生效
            if (table_.hitPolicy == HitPolicy.Unique) {
                requireUniqueRows()
            }
        }
        if (agendaPath_) {
            warnAgendaDegradation()
        }
        let fieldTypes = space_.fieldTypes(factType_)
        let fieldNames = space_.fieldNames(factType_)
        checkColumnTypes(fieldTypes)
        let binding = table_.binding
        let rows = ArrayList<CompiledRow>()
        let rules = ArrayList<Rule>()
        var rowIndex: Int64 = 0
        for (row in table_.rowIterator()) {
            let compiled = compileRow(row, rowIndex, binding, fieldTypes, fieldNames)
            rows.add(compiled)
            rules.add(compiled.rule)
            rowIndex += 1
        }
        CompiledTable(factType_, binding, rows.toArray(), rules.toArray(), warnings: warnings_.toArray())
    }

    /**
     * 载体类型与字段声明比对（`doc/07` §6.3）。
     *
     * 单元格/类型行给出的是**提示**，字段声明才是权威：冲突时按字段声明解析，
     * 并记一条 WARN。文本单元格是万能回退（任何类型都能从文本解析），不报警。
     */
    private func checkColumnTypes(fieldTypes: HashMap<String, FieldType>): Unit {
        var index: Int64 = 0
        for (column in table_.columns) {
            if (column.kind == ColumnKind.When) {
                match (table_.columnTypeAt(index)) {
                    case Some(declared) => match (fieldTypes.get(column.field)) {
                        case Some(field) =>
                            if (TableCompiler.conflicts(declared, field)) {
                                let message = "决策表 ${table_.id} 的列 ${column.name}：" +
                                    "载体类型 ${declared} 与字段声明 ${factType_}.${column.field}（${field}）" +
                                    "冲突，以字段声明为准"
                                warnings_.add(message)
                                TableCompiler.log.warn(message)
                            }
                        case None => ()
                    }
                    case None => ()
                }
            }
            index += 1
        }
    }

    /** 文本可解析为任意声明类型，`Any`/`Scalar` 不作约束，因此这三者不算冲突。 */
    private static func conflicts(carrier: FieldType, declared: FieldType): Bool {
        if (carrier == declared) {
            return false
        }
        if (carrier == FieldType.Text || carrier == FieldType.`Any` || carrier == FieldType.Scalar) {
            return false
        }
        if (declared == FieldType.`Any` || declared == FieldType.Scalar) {
            return false
        }
        true
    }

    private func compileRow(row: TableRow, rowIndex: Int64, binding: String,
        fieldTypes: HashMap<String, FieldType>, fieldNames: Array<String>): CompiledRow {
        let conditions = ArrayList<CompiledCondition>()
        let pattern = Pattern(factType_, binding)
        let scripts = ArrayList<String>()
        var index: Int64 = 0
        for (column in table_.columns) {
            match (column.kind) {
                case ColumnKind.When =>
                    let cell = CellParser.parseCondition(row.values[index],
                        fieldTypeOf(column, fieldTypes))
                    match (cell) {
                        case Some(parsed) =>
                            validateOperator(column, parsed.op, fieldTypes)
                            let value = parsed.value.getOrThrow()
                            pattern.constrain(column.field, parsed.op, value)
                            conditions.add(CompiledCondition(column,
                                Some(Constraint(column.field, parsed.op, right: Operand.Const(value))),
                                None))
                        case None =>
                            conditions.add(CompiledCondition(column, None, None))
                    }
                case ColumnKind.Expr =>
                    let expr = ExprColumn.compile(row.values[index], binding, hostType_, compiler_)
                    match (expr) {
                        case Some(compiled) => scripts.add(compiled.source)
                        case None => ()
                    }
                    conditions.add(CompiledCondition(column, None, expr))
                case _ => ()
            }
            index += 1
        }
        let outputs = compileOutputs(row, binding, fieldNames)
        let salience = agendaSalience(row, rowIndex)
        let action = actionFor(binding, outputs)
        let rule = buildRule(row, pattern, scripts, action, salience)
        CompiledRow(row, rule, conditions.toArray(), outputs, salience)
    }

    /** 先构造模式再建规则；动作闭包按行绑定解析输出。 */
    private func buildRule(row: TableRow, pattern: Pattern, scripts: ArrayList<String>,
        action: RuleAction, salience: Int64): Rule {
        // 表 id 前缀避免不同表的同名行冲突（AS-02）
        let builder = Rule.builder("${table_.id}/${row.ruleId}")
            .salience(salience)
            .facts(table_.factSpace)
            .addPattern(pattern)
        match (agendaGroup()) {
            case Some(group) => builder.activationGroup(group)
            case None => ()
        }
        for (source in scripts) {
            builder.script(source)
        }
        builder.then(action).build()
    }

    /**
     * 议程路径下的互斥组：只有「只执行一行」的策略需要分组。
     *
     * `First` / `Unique` / `Priority` 语义都是多命中时取一条，落到议程即同组互斥；
     * 其余策略允许全部命中，不分组。
     */
    private func agendaGroup(): ?String {
        match (table_.hitPolicy) {
            case First | Unique | Priority => Some(table_.id)
            case _ => None
        }
    }

    /**
     * 议程路径的 salience：以表/行声明的 salience 为基准，按行序递减。
     *
     * `First`/`Unique`/`Priority`/`Collect`/`OutputOrder` 需要行序语义；首行保持原值，
     * 后续行逐行减 1，因此显式 salience 的差异仍然优先，同行基准时才由行序决定。
     * `RuleOrder` 与 `Any` 保留原始 salience。
     */
    private func agendaSalience(row: TableRow, rowIndex: Int64): Int64 {
        let base = salienceOf(row)
        match (table_.hitPolicy) {
            case First | Unique | Priority | Collect | OutputOrder => base - rowIndex
            case _ => base
        }
    }

    /** 议程路径无法完整表达的 HitPolicy 降级；在编译入口提示一次，避免逐行刷屏。 */
    private func warnAgendaDegradation(): Unit {
        var detail = ""
        match (table_.hitPolicy) {
            case Unique => detail = "运行期多命中只执行一条、不报错（构建期仍检查重复行）"
            case Priority => detail = "按行序执行，无法按 outputOrder 比较运行期输出"
            case Any => detail = "不校验多命中的输出一致性"
            case OutputOrder => detail = "按行序执行，无法按输出值排序"
            case _ => return
        }
        TableCompiler.log.warn(
            "决策表 ${table_.id} 的 HitPolicy ${table_.hitPolicy} 在议程路径降级：${detail}；" +
            "需要完整语义请使用 RuleEngine.executeTable"
        )
    }

    private func compileOutputs(row: TableRow, binding: String,
        fieldNames: Array<String>): Array<CompiledOutput> {
        let outputs = ArrayList<CompiledOutput>()
        var index: Int64 = 0
        for (column in table_.columns) {
            if (column.kind == ColumnKind.Then) {
                match (OutputCell.parse(row.values[index], [binding])) {
                    case Some(cell) =>
                        match (cell.source) {
                            case OutputSource.FieldRef(_, field) =>
                                if (!fieldNames.contains(field)) {
                                    throw RuleException(
                                        RuleErrorCode.UNKNOWN_FIELD,
                                        "决策表 ${table_.id} 第 ${row.line} 行的输出引用了未声明字段 " +
                                        "${factType_}.${field}"
                                    )
                                }
                            case _ => ()
                        }
                        outputs.add(CompiledOutput(column.path, cell))
                    case None => ()
                }
            }
            index += 1
        }
        outputs.toArray()
    }

    /** 动作：从当前激活绑定取事实，解析 `${}` 引用后写入输出槽。 */
    private func actionFor(binding: String, outputs: Array<CompiledOutput>): RuleAction {
        { ctx: ActionContext =>
            let facts = HashMap<String, Fact>()
            match (ctx.fact(binding)) {
                case Some(fact) => facts[binding] = fact
                case None => ()
            }
            for (output in outputs) {
                match (output.cell.resolve(facts)) {
                    case Some(value) => ctx.set(output.name, value)
                    case None => ()
                }
            }
        }
    }

    private func salienceOf(row: TableRow): Int64 {
        var index: Int64 = 0
        for (column in table_.columns) {
            if (column.kind == ColumnKind.Salience) {
                match (row.values[index]) {
                    case Some(text) =>
                        if (text.trimAscii() != "") {
                            try {
                                return Int64.parse(text.trimAscii())
                            } catch (_: Exception) {
                                throw RuleException(
                                    RuleErrorCode.TABLE_INVALID,
                                    "决策表 ${table_.id} 第 ${row.line} 行的 salience 不是整数: ${text}"
                                )
                            }
                        }
                    case None => ()
                }
            }
            index += 1
        }
        table_.salience
    }

    private func fieldTypeOf(column: Column, fieldTypes: HashMap<String, FieldType>): FieldType {
        match (fieldTypes.get(column.field)) {
            case Some(found) => found
            case None =>
                throw RuleException(
                    RuleErrorCode.UNKNOWN_FIELD,
                    "决策表 ${table_.id} 的条件列 ${column.name} 引用了未声明字段 ${factType_}.${column.field}"
                )
        }
    }

    private func validateOperator(column: Column, op: Operator,
        fieldTypes: HashMap<String, FieldType>): Unit {
        let fieldType = fieldTypeOf(column, fieldTypes)
        if (!Validator.compatible(fieldType, op)) {
            throw RuleException(
                RuleErrorCode.TYPE_MISMATCH,
                "决策表 ${table_.id} 的列 ${column.name}（${fieldType}）不支持算子 ${op}"
            )
        }
    }

    /** `Unique` 策略：条件单元格完全相同的两行在构建期拒绝（§8）。 */
    private func requireUniqueRows(): Unit {
        let seen = HashMap<String, TableRow>()
        for (row in table_.rows) {
            let key = conditionKey(row)
            match (seen.get(key)) {
                case Some(existing) =>
                    throw RuleException(
                        RuleErrorCode.TABLE_INVALID,
                        "决策表 ${table_.id} 在 Unique 策略下存在条件相同的行: " +
                        "第 ${existing.line} 行与第 ${row.line} 行"
                    )
                case None => seen[key] = row
            }
        }
    }

    private func conditionKey(row: TableRow): String {
        var key = ""
        var index: Int64 = 0
        for (column in table_.columns) {
            if (column.kind == ColumnKind.When || column.kind == ColumnKind.Expr) {
                match (row.values[index]) {
                    case Some(text) =>
                        let trimmed = text.trimAscii()
                        key += "${trimmed.size}:${trimmed};"
                    case None => key += "-;"
                }
            }
            index += 1
        }
        key
    }
}
