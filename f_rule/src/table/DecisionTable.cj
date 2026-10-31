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

import std.collection.ArrayList
import fountain::f_jit.Compiler
import fountain::f_rule.exception.{RuleErrorCode, RuleException}
import fountain::f_rule.fact.FactSpace
import fountain::f_rule.rule.{Rule, RuleSet}

/**
 * 决策表模型（`doc/07-decision-table.md` §1）。
 *
 * 一张表绑定一个 `factSpace` 与一个 `factType`；`factType` 未声明时按空间内
 * 唯一类型推断（设计 D9）。`hitPolicy` 只影响结果聚合，不进入单条规则。
 */
public class DecisionTable {
    public let id: String
    public let name: String
    public let version: String
    public let factSpace: String
    /** 空串表示未声明，编译时按空间类型推断。 */
    public let factType: String
    public let hitPolicy: HitPolicy
    public let columns: Array<Column>
    public let rows: Array<TableRow>
    /** 行未声明 salience 时使用的缺省值。 */
    public let salience: Int64
    /** `Priority` / `OutputOrder` 使用的输出列顺序。 */
    public let outputOrder: Array<String>

    init(id: String, name: String, version: String, factSpace: String, factType: String,
        hitPolicy: HitPolicy, columns: Array<Column>, rows: Array<TableRow>, salience: Int64,
        outputOrder: Array<String>) {
        this.id = id
        this.name = name
        this.version = version
        this.factSpace = factSpace
        this.factType = factType
        this.hitPolicy = hitPolicy
        this.columns = columns
        this.rows = rows
        this.salience = salience
        this.outputOrder = outputOrder
    }

    public static func builder(id: String): DecisionTableBuilder {
        DecisionTableBuilder(id)
    }

    /** 单模式表的绑定名；没有条件列时取缺省 `o`。 */
    public prop binding: String {
        get() {
            for (column in columns) {
                if (column.kind == ColumnKind.When) {
                    return column.binding
                }
            }
            "o"
        }
    }

    public func columnsOf(kind: ColumnKind): Array<Column> {
        let out = ArrayList<Column>()
        for (column in columns) {
            if (column.kind == kind) {
                out.add(column)
            }
        }
        out.toArray()
    }

    /**
     * 解析 `when.*` 作用的事实类型。
     *
     * 显式 `factType` 优先；未声明时空间必须恰好有一个类型，否则 `TABLE_INVALID`。
     */
    public func resolvedFactType(ruleSet: RuleSet): String {
        let space = match (ruleSet.registry.get(factSpace)) {
            case Some(found) => found
            case None =>
                throw RuleException(
                    RuleErrorCode.UNKNOWN_FACT_SPACE,
                    "决策表 ${id} 引用了未声明的事实空间 ${factSpace}"
                )
        }
        if (factType != "") {
            if (!space.hasType(factType)) {
                throw RuleException(
                    RuleErrorCode.UNKNOWN_TYPE,
                    "空间 ${factSpace} 未注册类型 ${factType}"
                )
            }
            return factType
        }
        let types = space.typeTags()
        if (types.size == 1) {
            return types[0]
        }
        if (types.size == 0) {
            throw RuleException(
                RuleErrorCode.UNKNOWN_TYPE,
                "空间 ${factSpace} 没有任何已注册类型，决策表 ${id} 无法推断 factType"
            )
        }
        throw RuleException(
            RuleErrorCode.TABLE_INVALID,
            "空间 ${factSpace} 注册了 ${types.size} 个类型，决策表 ${id} 需要显式声明 factType"
        )
    }

    /**
     * 编译为规则（`doc/07-decision-table.md` §7）。
     *
     * 无 `expr` 列时不需要 `f_jit` 注册；有 `expr` 列时建议用
     * `RuleSetBuilder.table()` 或带 `compiler` 的重载，以复用应用的共享编译器。
     */
    public func compile(ruleSet: RuleSet): Array<Rule> {
        compile(ruleSet, Compiler())
    }

    public func compile(ruleSet: RuleSet, compiler: Compiler): Array<Rule> {
        TableCompiler(this, ruleSet, compiler).compile().rules
    }

    public func toString(): String {
        "DecisionTable(${id}, ${rows.size} rows, ${hitPolicy})"
    }
}
