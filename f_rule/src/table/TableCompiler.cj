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
import fountain::f_jit.Compiler
import fountain::f_rule.condition.{Constraint, JitExpression, Operand, Operator, Pattern}
import fountain::f_rule.exception.{RuleErrorCode, RuleException}
import fountain::f_rule.fact.{Fact, FactSpace, FieldType}
import fountain::f_rule.rule.{ActionContext, Rule, RuleAction, RuleSet, Validator}

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

    init(factType: String, binding: String, rows: Array<CompiledRow>, rules: Array<Rule>) {
        this.factType = factType
        this.binding = binding
        this.rows = rows
        this.rules = rules
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
    private let table_: DecisionTable
    private let compiler_: Compiler
    private let space_: FactSpace
    private let factType_: String
    private let hostType_: String

    public init(table: DecisionTable, ruleSet: RuleSet, compiler: Compiler) {
        this.table_ = table
        this.compiler_ = compiler
        this.factType_ = table.resolvedFactType(ruleSet)
        this.space_ = match (ruleSet.registry.get(table.factSpace)) {
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

    public func compile(): CompiledTable {
        if (table_.rows.isEmpty()) {
            throw RuleException(
                RuleErrorCode.TABLE_INVALID,
                "决策表 ${table_.id} 没有任何数据行（空表）"
            )
        }
        if (table_.hitPolicy == HitPolicy.Unique) {
            requireUniqueRows()
        }
        let fieldTypes = space_.fieldTypes(factType_)
        let fieldNames = space_.fieldNames(factType_)
        let binding = table_.binding
        let rows = ArrayList<CompiledRow>()
        let rules = ArrayList<Rule>()
        for (row in table_.rows) {
            let compiled = compileRow(row, binding, fieldTypes, fieldNames)
            rows.add(compiled)
            rules.add(compiled.rule)
        }
        CompiledTable(factType_, binding, rows.toArray(), rules.toArray())
    }

    private func compileRow(row: TableRow, binding: String,
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
        let salience = salienceOf(row)
        let action = actionFor(binding, outputs)
        let rule = buildRule(row, pattern, scripts, action, salience)
        CompiledRow(row, rule, conditions.toArray(), outputs, salience)
    }

    /** 先构造模式再建规则；动作闭包按行绑定解析输出。 */
    private func buildRule(row: TableRow, pattern: Pattern, scripts: ArrayList<String>,
        action: RuleAction, salience: Int64): Rule {
        let builder = Rule.builder(row.ruleId)
            .salience(salience)
            .facts(table_.factSpace)
            .addPattern(pattern)
        for (source in scripts) {
            builder.script(source)
        }
        builder.then(action).build()
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
