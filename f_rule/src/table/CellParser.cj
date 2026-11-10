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
import std.convert.*
import std.time.{DateTime, Month}
import fountain::f_rule.condition.Operator
import fountain::f_rule.exception.{RuleErrorCode, RuleException}
import fountain::f_rule.fact.FieldType

/** 解析后的条件单元格：算子 + 常量右值（`IsNull`/`NotNull` 无值）。 */
public class ConditionCell {
    public let op: Operator
    public let value: ?Any

    public init(op: Operator, value: ?Any) {
        this.op = op
        this.value = value
    }

    public func toString(): String {
        match (value) {
            case Some(_) => "${op} <value>"
            case None => op.toString()
        }
    }
}

/**
 * 条件/值单元格解析（`doc/07-decision-table.md` §4.1）。
 *
 * 算子写法大小写不敏感；裸值等价于 `==`；`-` 与空单元格等价于"不约束"。
 * 值按字段声明的 [FieldType] 解析，无法解析抛 `TYPE_MISMATCH`；算子本身非法抛
 * `TABLE_INVALID`。两者严格区分：前者是数据问题，后者是表结构问题。
 */
public class CellParser {
    private init() {}

    /** 解析条件单元格；`None`/空串/`-` 返回 `None`（不约束）。 */
    public static func parseCondition(cell: ?String, fieldType: FieldType): ?ConditionCell {
        let raw = match (cell) {
            case Some(text) => text.trimAscii()
            case None => return None
        }
        if (raw == "" || raw == "-") {
            return None
        }
        let lower = raw.toAsciiLower()
        if (lower == "null") {
            return Some(ConditionCell(Operator.IsNull, None))
        }
        if (lower == "not null") {
            return Some(ConditionCell(Operator.NotNull, None))
        }
        if (lower.startsWith("not in")) {
            return Some(ConditionCell(Operator.NotIn, CellParser.requireList(raw[6..], fieldType, "not in")))
        }
        if (lower.startsWith("between")) {
            let values = CellParser.requireList(raw[7..], fieldType, "between")
            if (values.size != 2) {
                throw RuleException(
                    RuleErrorCode.TABLE_INVALID,
                    "between 需要恰好两个边界值: ${raw}"
                )
            }
            return Some(ConditionCell(Operator.Between, values))
        }
        if (lower.startsWith("in ") || lower.startsWith("in[")) {
            return Some(ConditionCell(Operator.In, CellParser.requireList(raw[2..], fieldType, "in")))
        }
        if (lower.startsWith("contains ")) {
            return Some(ConditionCell(Operator.Contains, CellParser.parseValue(raw[9..], fieldType)))
        }
        if (lower.startsWith("startswith ")) {
            return Some(ConditionCell(Operator.StartsWith, CellParser.parseValue(raw[11..], fieldType)))
        }
        if (lower.startsWith("endswith ")) {
            return Some(ConditionCell(Operator.EndsWith, CellParser.parseValue(raw[9..], fieldType)))
        }
        if (lower.startsWith("matches ")) {
            return Some(ConditionCell(Operator.Matches, CellParser.parseValue(raw[8..], fieldType)))
        }
        if (raw.startsWith(">=")) {
            return Some(ConditionCell(Operator.Ge, CellParser.operatorValue(raw, 2, fieldType)))
        }
        if (raw.startsWith("<=")) {
            return Some(ConditionCell(Operator.Le, CellParser.operatorValue(raw, 2, fieldType)))
        }
        if (raw.startsWith("!=")) {
            return Some(ConditionCell(Operator.Ne, CellParser.operatorValue(raw, 2, fieldType)))
        }
        if (raw.startsWith("==")) {
            return Some(ConditionCell(Operator.Eq, CellParser.operatorValue(raw, 2, fieldType)))
        }
        if (raw.startsWith("=")) {
            return Some(ConditionCell(Operator.Eq, CellParser.operatorValue(raw, 1, fieldType)))
        }
        if (raw.startsWith(">")) {
            return Some(ConditionCell(Operator.Gt, CellParser.operatorValue(raw, 1, fieldType)))
        }
        if (raw.startsWith("<")) {
            return Some(ConditionCell(Operator.Lt, CellParser.operatorValue(raw, 1, fieldType)))
        }
        if (raw.startsWith("!") || raw.startsWith("~")) {
            throw RuleException(RuleErrorCode.TABLE_INVALID, "无法解析的条件算子: ${raw}")
        }
        Some(ConditionCell(Operator.Eq, CellParser.parseValue(raw, fieldType)))
    }

    /** 取算子后的值部分；紧随其后再出现算子符号视为非法算子（如 `>> 3`、`=! 3`）。 */
    private static func operatorValue(raw: String, offset: Int64, fieldType: FieldType): Any {
        let rest = raw[offset..].trimAscii()
        if (rest == "") {
            throw RuleException(RuleErrorCode.TABLE_INVALID, "条件缺少右值: ${raw}")
        }
        let first = rest[0]
        if (first == b'=' || first == b'!' || first == b'>' || first == b'<' || first == b'~') {
            throw RuleException(RuleErrorCode.TABLE_INVALID, "无法解析的条件算子: ${raw}")
        }
        CellParser.parseValue(rest, fieldType)
    }

    /** 解析单个值；失败抛 `TYPE_MISMATCH`。 */
    public static func parseValue(raw: String, fieldType: FieldType): Any {
        let text = raw.trimAscii()
        match (fieldType) {
            case FieldType.Number => number(text)
            case FieldType.Text => unquote(text)
            case FieldType.`Bool` => bool(text)
            case FieldType.Time => time(text)
            case FieldType.List => list(text)
            case FieldType.`Any` => infer(text)
            case FieldType.Scalar => infer(text)
        }
    }

    /** `[a, b, c]` → 数组；非数组写法抛 `TABLE_INVALID`。 */
    private static func requireList(raw: String, fieldType: FieldType, label: String): Array<Any> {
        let text = raw.trimAscii()
        if (!text.startsWith("[") || !text.endsWith("]")) {
            throw RuleException(
                RuleErrorCode.TABLE_INVALID,
                "${label} 的值必须是 [a, b] 形式: ${raw}"
            )
        }
        let inner = text[1..Int64(text.size) - 1].trimAscii()
        let out = ArrayList<Any>()
        if (inner == "") {
            return out.toArray()
        }
        for (part in inner.split(",")) {
            out.add(CellParser.parseValue(part, fieldType))
        }
        out.toArray()
    }

    private static func list(text: String): Array<Any> {
        CellParser.requireList(text, FieldType.`Any`, "list")
    }

    private static func number(text: String): Any {
        if (text == "") {
            throw typeMismatch(text, FieldType.Number)
        }
        let isReal = text.contains(".") || text.contains("e") || text.contains("E")
        try {
            if (isReal) {
                return Float64.parse(text)
            }
            return Int64.parse(text)
        } catch (_: Exception) {
            throw typeMismatch(text, FieldType.Number)
        }
    }

    private static func bool(text: String): Bool {
        match (text.toAsciiLower()) {
            case "true" => true
            case "false" => false
            case _ => throw typeMismatch(text, FieldType.`Bool`)
        }
    }

    private static func time(text: String): DateTime {
        match (CellParser.tryTime(text)) {
            case Some(found) => found
            case None => throw typeMismatch(text, FieldType.Time)
        }
    }

    /** 接受 `yyyy-MM-dd` 与 `yyyy-MM-dd HH:mm:ss`（也接受 `T` 分隔）。 */
    private static func tryTime(text: String): ?DateTime {
        let trimmed = text.trimAscii()
        var datePart = trimmed
        var timePart = ""
        var separator = -1
        var i = 0
        while (i < Int64(trimmed.size)) {
            let byte = trimmed[i]
            if (byte == b' ' || byte == b'T') {
                separator = i
                break
            }
            i += 1
        }
        if (separator >= 0) {
            datePart = trimmed[0..separator].trimAscii()
            timePart = trimmed[separator + 1..].trimAscii()
        }
        let date = datePart.split("-")
        if (date.size != 3) {
            return None
        }
        var hour: Int64 = 0
        var minute: Int64 = 0
        var second: Int64 = 0
        if (timePart != "") {
            let clock = timePart.split(":")
            if (clock.size != 3) {
                return None
            }
            hour = CellParser.parseIntOr(clock[0], -1)
            minute = CellParser.parseIntOr(clock[1], -1)
            second = CellParser.parseIntOr(clock[2], -1)
            if (hour < 0 || hour > 23 || minute < 0 || minute > 59 || second < 0 || second > 59) {
                return None
            }
        }
        let year = CellParser.parseIntOr(date[0], -1)
        let month = CellParser.parseIntOr(date[1], -1)
        let day = CellParser.parseIntOr(date[2], -1)
        if (year < 1 || month < 1 || month > 12 || day < 1 || day > 31) {
            return None
        }
        try {
            return Some(DateTime.of(year: year, month: Month.of(month), dayOfMonth: day,
                hour: hour, minute: minute, second: second))
        } catch (_: Exception) {
            None
        }
    }

    private static func parseIntOr(text: String, fallback: Int64): Int64 {
        try {
            Int64.parse(text.trimAscii())
        } catch (_: Exception) {
            fallback
        }
    }

    /** 字面量推断：数字 → 布尔 → 时间 → 字符串。 */
    private static func infer(text: String): Any {
        try {
            if (text.contains(".") || text.contains("e") || text.contains("E")) {
                return Float64.parse(text)
            }
            return Int64.parse(text)
        } catch (_: Exception) {
            ()
        }
        match (text.toAsciiLower()) {
            case "true" => return true
            case "false" => return false
            case _ => ()
        }
        if (text.size >= 10 && text[4] == b'-' && text[7] == b'-') {
            match (CellParser.tryTime(text)) {
                case Some(found) => return found
                case None => ()
            }
        }
        unquote(text)
    }

    private static func unquote(text: String): String {
        if (text.size >= 2) {
            let first = text[0]
            let last = text[Int64(text.size) - 1]
            if ((first == 0x22u8 || first == 0x27u8) && first == last) {
                return text[1..Int64(text.size) - 1]
            }
        }
        text
    }

    private static func typeMismatch(text: String, fieldType: FieldType): RuleException {
        RuleException(
            RuleErrorCode.TYPE_MISMATCH,
            "单元格值 ${text} 无法解析为 ${fieldType}"
        )
    }
}
