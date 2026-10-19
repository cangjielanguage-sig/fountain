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
package fountain::fdbm.sql

import std.collection.ArrayList
import std.convert.*
import fountain::f_data.{Data, DataBool, DataNone, DataReal, DataString}

/** 某列的范围约束：`None` 表示该侧无界；闭开由 `loInclusive` / `hiInclusive` 表示。 */
protected class PartitionRange {
    public let lo: ?Int64
    public let loInclusive: Bool
    public let hi: ?Int64
    public let hiInclusive: Bool

    public init(lo: ?Int64, loInclusive: Bool, hi: ?Int64, hiInclusive: Bool) {
        this.lo = lo
        this.loInclusive = loInclusive
        this.hi = hi
        this.hiInclusive = hiInclusive
    }

    /** 是否为空区间（`lo > hi`，或同值时有一侧开）。 */
    public func isEmpty(): Bool {
        match (lo) {
            case Some(low) =>
                match (hi) {
                    case Some(high) =>
                        if (low > high) {
                            return true
                        }
                        if (low == high && !(loInclusive && hiInclusive)) {
                            return true
                        }
                        false
                    case None => false
                }
            case None => false
        }
    }
}

/**
 * 分库键抽取（设计 §8.2）：
 *
 * - `extract`：只处理 `AND` 连接的**等值 / IN**；`OR` / `NOT` 保守地返回空（交给路由器按 `Unroutable`）；
 * - `extractRange`：`AND` 连接的 `>`/`>=`/`<`/`<=`，各边界取最紧；`OR`/`NOT`/非字面量 → `None`。
 */
protected struct PartitionKeyExtractor {

    /** 某列的字面量集合（等值/IN）。 */
    public static func extract(expression: ?SqlExpression, table: ?String, column: String): Array<String> {
        let context = ExtractContext(table, column)
        match (expression) {
            case Some(value) =>
                if (!context.collect(value)) {
                    return Array<String>()
                }
            case None => ()
        }
        context.values.toArray()
    }

    /** 某列的范围约束；不可判定（OR/NOT/非整数字面量）→ `None`。 */
    public static func extractRange(expression: ?SqlExpression, table: ?String,
        column: String): ?PartitionRange {
        let context = RangeContext(table, column)
        let result = match (expression) {
            case Some(value) => context.collect(value)
            case None => RangeResult(false)
        }
        if (!result.determinable) {
            return None<PartitionRange>
        }
        Some(PartitionRange(result.lo, result.loInclusive, result.hi, result.hiInclusive))
    }

    /** 列是否命中目标（表限定名可为别名/表名；无限定视为命中）。 */
    public static func matches(expression: SqlExpression, table: ?String, column: String): Bool {
        match (expression) {
            case c: ColumnExpression =>
                if (c.column != column) {
                    return false
                }
                match (c.table) {
                    case Some(qualifier) =>
                        match (table) {
                            case Some(name) => qualifier == name
                            case None => false
                        }
                    case None => true
                }
            case _ => false
        }
    }

    /** 字面量 → 路由字符串；NULL 或无法表达 → `None`。 */
    public static func literalString(expression: SqlExpression): ?String {
        match (expression) {
            case l: LiteralExpression =>
                match (l.data) {
                    case s: DataString => Some(s.data)
                    case d: DataReal => Some(d.data.toString())
                    case b: DataBool => Some(b.data.toString())
                    case _: DataNone => None<String>
                    case other => Some(other.toString())
                }
            case _ => None<String>
        }
    }

    /** 字面量 → Int64（无损）；小数/越界/非数字 → `None`。 */
    public static func literalInt64(expression: SqlExpression): ?Int64 {
        match (expression) {
            case l: LiteralExpression =>
                let text = match (l.data) {
                    case s: DataString => s.data
                    case d: DataReal => d.data.toString()
                    case _ => return None<Int64>
                }
                Int64.tryParse(text.trimAscii())
            case _ => None<Int64>
        }
    }
}

/** `extract` 的遍历状态。 */
class ExtractContext {
    private let table: ?String
    private let column: String
    let values = ArrayList<String>()

    init(table: ?String, column: String) {
        this.table = table
        this.column = column
    }

    /** @return `false` 表示遇到 OR/NOT（不可安全收敛）。 */
    func collect(expression: SqlExpression): Bool {
        match (expression) {
            case b: BinaryExpression =>
                if (b.op == BinaryOp.And) {
                    return collect(b.left) && collect(b.right)
                }
                if (b.op == BinaryOp.Or) {
                    return false
                }
                if (b.op == BinaryOp.Eq) {
                    collectEquality(b.left, b.right)
                    collectEquality(b.right, b.left)
                }
                true
            case i: InExpression =>
                if (i.negated) {
                    return true
                }
                if (!PartitionKeyExtractor.matches(i.operand, table, column)) {
                    return true
                }
                for (value in i.values) {
                    match (PartitionKeyExtractor.literalString(value)) {
                        case Some(text) => values.add(text)
                        case None => return false
                    }
                }
                true
            case _: NotExpression => false
            case _ => true
        }
    }

    private func collectEquality(columnSide: SqlExpression, valueSide: SqlExpression): Unit {
        if (PartitionKeyExtractor.matches(columnSide, table, column)) {
            match (PartitionKeyExtractor.literalString(valueSide)) {
                case Some(text) => values.add(text)
                case None => ()
            }
        }
    }
}

/** `extractRange` 的遍历状态（可变累积）。 */
class RangeResult {
    var determinable: Bool = true
    var lo: ?Int64 = None
    var loInclusive: Bool = true
    var hi: ?Int64 = None
    var hiInclusive: Bool = true

    init(determinable: Bool) {
        this.determinable = determinable
    }

    func tightenLower(value: Int64, inclusive: Bool): Unit {
        match (lo) {
            case Some(current) =>
                if (value > current) {
                    lo = Some(value)
                    loInclusive = inclusive
                } else if (value == current) {
                    loInclusive = loInclusive && inclusive
                }
            case None =>
                lo = Some(value)
                loInclusive = inclusive
        }
    }

    func tightenUpper(value: Int64, inclusive: Bool): Unit {
        match (hi) {
            case Some(current) =>
                if (value < current) {
                    hi = Some(value)
                    hiInclusive = inclusive
                } else if (value == current) {
                    hiInclusive = hiInclusive && inclusive
                }
            case None =>
                hi = Some(value)
                hiInclusive = inclusive
        }
    }

    func merge(other: RangeResult): Unit {
        if (!other.determinable) {
            determinable = false
            return
        }
        match (other.lo) {
            case Some(value) => tightenLower(value, other.loInclusive)
            case None => ()
        }
        match (other.hi) {
            case Some(value) => tightenUpper(value, other.hiInclusive)
            case None => ()
        }
    }
}

class RangeContext {
    private let table: ?String
    private let column: String

    init(table: ?String, column: String) {
        this.table = table
        this.column = column
    }

    func collect(expression: SqlExpression): RangeResult {
        match (expression) {
            case b: BinaryExpression =>
                if (b.op == BinaryOp.And) {
                    let left = collect(b.left)
                    let right = collect(b.right)
                    left.merge(right)
                    return left
                }
                if (b.op == BinaryOp.Or) {
                    return RangeResult(false)
                }
                if (b.op == BinaryOp.Gt || b.op == BinaryOp.Gte ||
                    b.op == BinaryOp.Lt || b.op == BinaryOp.Lte) {
                    return comparison(b)
                }
                RangeResult(true) // 其他 AND 条件（`!=` / LIKE / 等值）忽略
            case _: NotExpression => RangeResult(false)
            case _: InExpression => RangeResult(true)
            case _ => RangeResult(true)
        }
    }

    /** 归一操作数顺序后收紧一侧边界；非本列 / 非整数字面量 → 不可判定。 */
    private func comparison(binary: BinaryExpression): RangeResult {
        let result = RangeResult(true)
        var columnSide = binary.left
        var valueSide = binary.right
        var op = binary.op
        if (!PartitionKeyExtractor.matches(columnSide, table, column)) {
            if (PartitionKeyExtractor.matches(valueSide, table, column)) {
                // `100 < id` ≡ `id > 100`
                columnSide = binary.right
                valueSide = binary.left
                op = reverse(op)
            } else {
                return result
            }
        }
        let value = match (PartitionKeyExtractor.literalInt64(valueSide)) {
            case Some(number) => number
            case None => return RangeResult(false)
        }
        match (op) {
            case BinaryOp.Gt => result.tightenLower(if (value == Int64.Max) { value } else { value + 1 },
                true)
            case BinaryOp.Gte => result.tightenLower(value, true)
            case BinaryOp.Lt => result.tightenUpper(if (value == Int64.Min) { value } else { value - 1 },
                true)
            case BinaryOp.Lte => result.tightenUpper(value, true)
            case _ => ()
        }
        result
    }

    private static func reverse(op: BinaryOp): BinaryOp {
        match (op) {
            case BinaryOp.Gt => BinaryOp.Lt
            case BinaryOp.Gte => BinaryOp.Lte
            case BinaryOp.Lt => BinaryOp.Gt
            case BinaryOp.Lte => BinaryOp.Gte
            case other => other
        }
    }
}
