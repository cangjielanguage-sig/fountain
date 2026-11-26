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

import std.collection.HashMap
import fountain::f_rule.exception.{RuleErrorCode, RuleException}
import fountain::f_rule.fact.{Fact, FieldType}

/** 输出值的来源：常量、事实字段或整个事实（`doc/07-decision-table.md` §4.2）。 */
public enum OutputSource <: ToString {
    | Literal(Any)
    | FieldRef(String, String)
    | BindingRef(String)

    public func toString(): String {
        match (this) {
            case Literal(_) => "Literal"
            case FieldRef(binding, field) => "\${${binding}.${field}}"
            case BindingRef(binding) => "\${${binding}}"
        }
    }
}

/**
 * 输出单元格（`doc/07-decision-table.md` §4.2）。
 *
 * `${binding.field}` / `${binding}` 在编译期解析；引用的绑定必须是该行条件中出现的
 * 模式绑定，否则抛 `UNKNOWN_BINDING`。字面量按 `Any` 推断（数字/布尔/时间/文本）。
 */
public class OutputCell {
    public let source: OutputSource

    init(source: OutputSource) {
        this.source = source
    }

    /** 空单元格返回 `None`（该行不写这个输出）。 */
    public static func parse(cell: ?String, availableBindings: Array<String>): ?OutputCell {
        let raw = match (cell) {
            case Some(text) => text.trimAscii()
            case None => return None
        }
        if (raw == "") {
            return None
        }
        if (!raw.startsWith("\${")) {
            return Some(OutputCell(OutputSource.Literal(CellParser.parseValue(raw, FieldType.`Any`))))
        }
        if (!raw.endsWith("}")) {
            throw RuleException(
                RuleErrorCode.TABLE_INVALID,
                "\${} 引用缺少右花括号: ${raw}"
            )
        }
        let inner = raw[2..Int64(raw.size) - 1].trimAscii()
        if (inner == "") {
            throw RuleException(RuleErrorCode.TABLE_INVALID, "\${} 引用为空: ${raw}")
        }
        let parts = inner.split(".")
        match (parts.size) {
            case 1 =>
                let binding = parts[0].trimAscii()
                requireBinding(binding, availableBindings, raw)
                return Some(OutputCell(OutputSource.BindingRef(binding)))
            case 2 =>
                let binding = parts[0].trimAscii()
                let field = parts[1].trimAscii()
                if (binding == "" || field == "") {
                    throw RuleException(RuleErrorCode.TABLE_INVALID, "输出引用路径非法: ${raw}")
                }
                requireBinding(binding, availableBindings, raw)
                return Some(OutputCell(OutputSource.FieldRef(binding, field)))
            case _ =>
                throw RuleException(
                    RuleErrorCode.TABLE_INVALID,
                    "输出引用最多两段（binding.field）: ${raw}"
                )
        }
    }

    /** 运行期取值；绑定或字段缺失返回 `None`。 */
    public func resolve(bindings: HashMap<String, Fact>): ?Any {
        match (source) {
            case OutputSource.Literal(value) => Some(value)
            case OutputSource.BindingRef(binding) =>
                match (bindings.get(binding)) {
                    case Some(fact) => Some(fact)
                    case None => None
                }
            case OutputSource.FieldRef(binding, field) =>
                match (bindings.get(binding)) {
                    case Some(fact) => fact.get(field)
                    case None => None
                }
        }
    }

    private static func requireBinding(binding: String, availableBindings: Array<String>,
        raw: String): Unit {
        if (!availableBindings.contains(binding)) {
            throw RuleException(
                RuleErrorCode.UNKNOWN_BINDING,
                "输出引用 ${raw} 使用了未声明的绑定 ${binding}"
            )
        }
    }
}
