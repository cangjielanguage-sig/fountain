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
import fountain::f_rule.exception.{RuleErrorCode, RuleException}

/**
 * 决策表构建器（`doc/07-decision-table.md` §3）。
 *
 * 仓颉的 `when` 是关键字，因此条件列方法命名为 [whenColumn]；`then`/`expr` 保持原义，
 * 但为对称统一使用 [thenColumn] / [exprColumn]。
 */
public class DecisionTableBuilder {
    private let id_: String
    private var name_: String
    private var version_: String
    private var factSpace_: String
    private var factType_: String
    private var hitPolicy_: HitPolicy
    private var salience_: Int64
    private let outputOrder_: ArrayList<String>
    private let columns_: ArrayList<Column>
    private let rows_: ArrayList<TableRow>

    init(id: String) {
        this.id_ = id
        this.name_ = ""
        this.version_ = "v1"
        this.factSpace_ = "default"
        this.factType_ = ""
        this.hitPolicy_ = HitPolicy.First
        this.salience_ = 0
        this.outputOrder_ = ArrayList<String>()
        this.columns_ = ArrayList<Column>()
        this.rows_ = ArrayList<TableRow>()
    }

    public func name(value: String): DecisionTableBuilder {
        name_ = value
        this
    }

    public func version(value: String): DecisionTableBuilder {
        version_ = value
        this
    }

    /** 整表绑定的事实库空间，缺省 `default`。 */
    public func factSpace(space: String): DecisionTableBuilder {
        factSpace_ = space
        this
    }

    /** 条件列作用的事实类型；多类型空间必须显式声明。 */
    public func factType(typeTag: String): DecisionTableBuilder {
        factType_ = typeTag
        this
    }

    public func hitPolicy(policy: HitPolicy): DecisionTableBuilder {
        hitPolicy_ = policy
        this
    }

    /** 行未声明 salience 时的缺省优先级。 */
    public func salience(value: Int64): DecisionTableBuilder {
        salience_ = value
        this
    }

    /** `Priority` 策略的输出比较顺序。 */
    public func outputOrder(names: Array<String>): DecisionTableBuilder {
        for (name in names) {
            outputOrder_.add(name)
        }
        this
    }

    /** 追加任意表头列；未知列名抛 `TABLE_INVALID`。 */
    public func column(header: String): DecisionTableBuilder {
        let parsed = Column.parse(header)
        for (existing in columns_) {
            if (existing.name == parsed.name) {
                throw RuleException(
                    RuleErrorCode.TABLE_INVALID,
                    "决策表 ${id_} 的列重复: ${parsed.name}"
                )
            }
        }
        columns_.add(parsed)
        this
    }

    /** 条件列；`path` 可写 `level`、`order.level` 或完整的 `when.order.level`。 */
    public func whenColumn(path: String): DecisionTableBuilder {
        column(DecisionTableBuilder.header("when", path))
    }

    /** 输出列；`name` 可写 `discount` 或 `then.discount`。 */
    public func thenColumn(name: String): DecisionTableBuilder {
        column(DecisionTableBuilder.header("then", name))
    }

    /** 表达式条件列；`name` 可写 `risk` 或 `expr.risk`。 */
    public func exprColumn(name: String): DecisionTableBuilder {
        column(DecisionTableBuilder.header("expr", name))
    }

    /** 追加数据行，规则 id 自动生成 `R1`、`R2`…。 */
    public func row(values: Array<?String>): DecisionTableBuilder {
        row("", values)
    }

    /** 追加数据行并指定规则 id；空 id 回退自动编号。 */
    public func row(ruleId: String, values: Array<?String>): DecisionTableBuilder {
        rowAt(Int64(rows_.size) + 2, ruleId, values)
    }

    /** 追加数据行并显式指定物理行号（CSV/XLSX 解析器使用）。 */
    func rowAt(line: Int64, ruleId: String, values: Array<?String>): DecisionTableBuilder {
        if (values.size != columns_.size) {
            throw RuleException(
                RuleErrorCode.TABLE_INVALID,
                "决策表 ${id_} 第 ${line} 行列数不一致: 期望 ${columns_.size}，实际 ${values.size}（line=${line}）"
            )
        }
        let id = if (ruleId.trimAscii() == "") {
            "R${rows_.size + 1}"
        } else {
            ruleId.trimAscii()
        }
        rows_.add(TableRow(line, values, id))
        this
    }

    public func build(): DecisionTable {
        if (columns_.isEmpty()) {
            throw RuleException(
                RuleErrorCode.TABLE_INVALID,
                "决策表 ${id_} 没有任何列"
            )
        }
        DecisionTableBuilder.ensureSingleBinding(id_, columns_.toArray())
        DecisionTable(id_, name_, version_, factSpace_, factType_, hitPolicy_, columns_.toArray(),
            rows_.toArray(), salience_, outputOrder_.toArray())
    }

    /** 单模式表：全部条件列必须使用同一个绑定名。 */
    private static func ensureSingleBinding(id: String, columns: Array<Column>): Unit {
        var binding = ""
        for (column in columns) {
            if (column.kind != ColumnKind.When) {
                continue
            }
            if (binding == "") {
                binding = column.binding
            } else if (binding != column.binding) {
                throw RuleException(
                    RuleErrorCode.TABLE_INVALID,
                    "决策表 ${id} 只支持单模式，条件列绑定名不一致: ${binding} vs ${column.binding}"
                )
            }
        }
    }

    private static func header(prefix: String, value: String): String {
        let trimmed = value.trimAscii()
        if (trimmed.startsWith("${prefix}.")) {
            trimmed
        } else {
            "${prefix}.${trimmed}"
        }
    }
}
