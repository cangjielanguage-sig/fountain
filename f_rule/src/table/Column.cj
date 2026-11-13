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

import fountain::f_rule.exception.{RuleErrorCode, RuleException}

/** 列种类（`doc/07-decision-table.md` §1）。 */
public enum ColumnKind <: ToString & Equatable<ColumnKind> {
    | When
    | Then
    | Expr
    | Salience
    | Metadata

    public func toString(): String {
        match (this) {
            case When => "When"
            case Then => "Then"
            case Expr => "Expr"
            case Salience => "Salience"
            case Metadata => "Metadata"
        }
    }

    public operator func ==(other: ColumnKind): Bool {
        this.toString() == other.toString()
    }

    public operator func !=(other: ColumnKind): Bool {
        !(this == other)
    }
}

/**
 * 决策表列（`doc/07-decision-table.md` §1）。
 *
 * [name] 是表头原文；[path] 是去掉前缀后的载荷（条件/输出名）；
 * 条件列额外拆出 [binding] 与 [field]，输出列的 [path] 即输出槽名。
 *
 * 表头语法：
 * - `id` / `name` / `salience`；
 * - `when.<field>` 或 `when.<binding>.<field>`（单模式表可省略 binding，缺省 `o`）；
 * - `then.<输出名>`；
 * - `expr.<列名>`。
 */
public class Column {
    public let kind: ColumnKind
    public let name: String
    public let path: String
    public let binding: String
    public let field: String

    init(kind: ColumnKind, name: String, path: String, binding: String, field: String) {
        this.kind = kind
        this.name = name
        this.path = path
        this.binding = binding
        this.field = field
    }

    /** 解析表头；未知列名抛 `TABLE_INVALID`。 */
    public static func parse(header: String): Column {
        let trimmed = header.trimAscii()
        if (trimmed == "id" || trimmed == "name") {
            return Column(ColumnKind.Metadata, trimmed, "", "", "")
        }
        if (trimmed == "salience") {
            return Column(ColumnKind.Salience, trimmed, "", "", "")
        }
        if (trimmed.startsWith("when.")) {
            let rest = trimmed[5..].trimAscii()
            return conditionColumn(ColumnKind.When, trimmed, rest)
        }
        if (trimmed.startsWith("then.")) {
            let rest = trimmed[5..].trimAscii()
            if (rest == "") {
                throw RuleException(RuleErrorCode.TABLE_INVALID, "输出列名不能为空: ${header}")
            }
            return Column(ColumnKind.Then, trimmed, rest, "", "")
        }
        if (trimmed.startsWith("expr.")) {
            let rest = trimmed[5..].trimAscii()
            if (rest == "") {
                throw RuleException(RuleErrorCode.TABLE_INVALID, "表达式列名不能为空: ${header}")
            }
            return Column(ColumnKind.Expr, trimmed, rest, "", "")
        }
        throw RuleException(
            RuleErrorCode.TABLE_INVALID,
            "未知的决策表列名: ${header}（允许 id/name/salience/when.*/then.*/expr.*）"
        )
    }

    /** `when.a.b` → binding `a`、field `b`；`when.b` → binding `o`、field `b`。 */
    private static func conditionColumn(kind: ColumnKind, name: String, rest: String): Column {
        if (rest == "") {
            throw RuleException(RuleErrorCode.TABLE_INVALID, "条件列名不能为空: ${name}")
        }
        let parts = rest.split(".")
        match (parts.size) {
            case 1 => return Column(kind, name, rest, "o", rest)
            case 2 =>
                let binding = parts[0].trimAscii()
                let field = parts[1].trimAscii()
                if (binding == "" || field == "") {
                    throw RuleException(RuleErrorCode.TABLE_INVALID, "条件列路径非法: ${name}")
                }
                return Column(kind, name, rest, binding, field)
            case _ =>
                throw RuleException(
                    RuleErrorCode.TABLE_INVALID,
                    "条件列路径最多两段（binding.field）: ${name}"
                )
        }
    }

    public func toString(): String {
        "${kind}(${name})"
    }
}
