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
package fountain::f_rule.fact

import std.collection.*
import std.math.numeric.BigInt
import std.math.numeric.Decimal
import std.time.DateTime
import fountain::f_rule.exception.*

/**
 * 值域。排序先比域、再比域内值（`doc/02-fact-model.md` §5）。
 *
 * 域的先后顺序是索引的**全序基础**，改名或调整顺序都会让跳表的相对顺序变化，
 * 因此这里用显式 `==`/`hashCode` 而不是依赖编译器默认行为。
 */
public enum ValueDomain <: ToString & Hashable & Equatable<ValueDomain> {
    | Number
    | Text
    | `Bool`
    | Time
    | List

    public func rank(): Int64 {
        match (this) {
            case Number => 0
            case Text => 1
            case `Bool` => 2
            case Time => 3
            case List => 4
        }
    }

    public func toString(): String {
        match (this) {
            case Number => "Number"
            case Text => "Text"
            case `Bool` => "Bool"
            case Time => "Time"
            case List => "List"
        }
    }

    public func hashCode(): Int64 {
        "fountain::f_rule.fact.ValueDomain.${this}".hashCode()
    }

    public operator func ==(other: ValueDomain): Bool {
        this.rank() == other.rank()
    }
}

/** 归一后的内部表示；不对外暴露，避免调用方依赖具体分支。 */
enum KeyValue {
    | IntNumber(Int64)
    | RealNumber(Float64)
    | DecimalNumber(Decimal)
    | TextValue(String)
    | BoolValue(Bool)
    | TimeValue(Int64)
    | ListValue(ArrayList<ValueKey>)
}

/**
 * 索引键：把任意受支持的字段值归一成一个可哈希、可全序比较的键。
 *
 * 关键契约（`doc/02-fact-model.md` §5）：
 *
 * - `Int64(1)` 与 `Float64(1.0)` **相等且同 hash**，否则 hash 索引与范围索引会给出不同答案；
 * - `DateTime` 归一为 Unix 纳秒，且**不属于数值域**（时间与同值整数不相等）；
 * - `Array` 保序、`Set` 去重后按值序归一；
 * - [compare] 是全序（数值 < 文本 < 布尔 < 时间 < 列表），索引层只依赖它定位；
 * - [strictCompare] 供 `Gt/Ge/Lt/Le/Between` 使用，跨域直接抛 `TYPE_MISMATCH`，不静默判 false。
 */
public class ValueKey <: Hashable & Comparable<ValueKey> {
    private let inner: KeyValue

    private init(inner: KeyValue) {
        this.inner = inner
    }

    /** 归一入口；不支持的类型抛 `RuleException(TYPE_MISMATCH)`。 */
    public static func of(value: Any): ValueKey {
        match (value) {
            case v: Int64 => ValueKey(KeyValue.IntNumber(v))
            case v: Int32 => ValueKey(KeyValue.IntNumber(Int64(v)))
            case v: Int16 => ValueKey(KeyValue.IntNumber(Int64(v)))
            case v: Int8 => ValueKey(KeyValue.IntNumber(Int64(v)))
            case v: Float64 => ValueKey(realNumber(v))
            case v: Float32 => ValueKey(realNumber(Float64(v)))
            case v: Decimal => ValueKey(decimalNumber(v))
            case v: String => ValueKey(KeyValue.TextValue(v))
            case v: Bool => ValueKey(KeyValue.BoolValue(v))
            case v: DateTime => ValueKey(KeyValue.TimeValue(v.toUnixTimeStamp().toNanoseconds()))
            case v: Array<Any> => ValueKey(KeyValue.ListValue(listOf(v)))
            case v: ArrayList<Any> => ValueKey(KeyValue.ListValue(listOf(v.toArray())))
            case v: Set<Any> =>
                let items = ArrayList<ValueKey>()
                for (element in v) {
                    items.add(ValueKey.of(element))
                }
                sortByValue(items)
                ValueKey(KeyValue.ListValue(dedup(items)))
            case v: ReadOnlySet<Any> =>
                let items = ArrayList<ValueKey>()
                for (element in v) {
                    items.add(ValueKey.of(element))
                }
                sortByValue(items)
                ValueKey(KeyValue.ListValue(dedup(items)))
            case _ =>
                throw RuleException(
                    RuleErrorCode.TYPE_MISMATCH,
                    "ValueKey 不支持的值类型（允许 String/整数/浮点/Decimal/Bool/DateTime/Array<Any>/Set<Any>）"
                )
        }
    }

    private static func realNumber(v: Float64): KeyValue {
        if (v.isNaN()) {
            return KeyValue.RealNumber(v)
        }
        // 只在安全范围内尝试收敛到整数，避免 Int64(inf) 的未定义行为。
        if (v >= -9.2e18 && v <= 9.2e18) {
            let asInt = Int64(v)
            if (Float64(asInt) == v) {
                return KeyValue.IntNumber(asInt)
            }
        }
        KeyValue.RealNumber(v)
    }

    private static func decimalNumber(v: Decimal): KeyValue {
        if (v.isInteger()) {
            let big = v.toBigInt()
            if (big >= BigInt(Int64.Min) && big <= BigInt(Int64.Max)) {
                return KeyValue.IntNumber(big.toInt64())
            }
        }
        KeyValue.DecimalNumber(v)
    }

    private static func listOf(values: Array<Any>): ArrayList<ValueKey> {
        let items = ArrayList<ValueKey>()
        for (value in values) {
            items.add(ValueKey.of(value))
        }
        items
    }

    private static func dedup(items: ArrayList<ValueKey>): ArrayList<ValueKey> {
        let out = ArrayList<ValueKey>()
        for (item in items) {
            if (out.isEmpty() || out[out.size - 1] != item) {
                out.add(item)
            }
        }
        out
    }

    /** 插入排序：列表通常很短，避免为 Set 归一引入排序算法依赖。 */
    private static func sortByValue(items: ArrayList<ValueKey>): Unit {
        var i = 1
        while (i < items.size) {
            let current = items[i]
            var j = i - 1
            while (j >= 0 && items[j].compare(current) == Ordering.GT) {
                items[j + 1] = items[j]
                j -= 1
            }
            items[j + 1] = current
            i += 1
        }
    }

    /** 值域，供算子与调试使用。 */
    public prop domain: ValueDomain {
        get() {
            match (inner) {
                case IntNumber(_) | RealNumber(_) | DecimalNumber(_) => ValueDomain.Number
                case TextValue(_) => ValueDomain.Text
                case BoolValue(_) => ValueDomain.`Bool`
                case TimeValue(_) => ValueDomain.Time
                case ListValue(_) => ValueDomain.List
            }
        }
    }

    /** 取回归一后的值（`Int64`/`Float64`/`Decimal`/`String`/`Bool`/`ArrayList<ValueKey>`）。 */
    public func unwrap(): Any {
        match (inner) {
            case IntNumber(v) => v
            case RealNumber(v) => v
            case DecimalNumber(v) => v
            case TextValue(v) => v
            case BoolValue(v) => v
            case TimeValue(v) => v
            case ListValue(v) => v
        }
    }

    /** 全序比较：跨域不抛错（索引定位依赖这一点）。 */
    public func compare(other: ValueKey): Ordering {
        let leftRank = domain.rank()
        let rightRank = other.domain.rank()
        if (leftRank != rightRank) {
            return if (leftRank < rightRank) {
                Ordering.LT
            } else {
                Ordering.GT
            }
        }
        match ((inner, other.inner)) {
            case (IntNumber(a), IntNumber(b)) => compareInt(a, b)
            case (RealNumber(a), RealNumber(b)) => compareReal(a, b)
            case (DecimalNumber(a), DecimalNumber(b)) => a.compare(b)
            case (IntNumber(a), RealNumber(b)) => compareReal(Float64(a), b)
            case (RealNumber(a), IntNumber(b)) => compareReal(a, Float64(b))
            case (IntNumber(a), DecimalNumber(b)) => Decimal(a).compare(b)
            case (DecimalNumber(a), IntNumber(b)) => a.compare(Decimal(b))
            case (RealNumber(a), DecimalNumber(b)) => Decimal(a).compare(b)
            case (DecimalNumber(a), RealNumber(b)) => a.compare(Decimal(b))
            case (TextValue(a), TextValue(b)) => compareText(a, b)
            case (BoolValue(a), BoolValue(b)) => if (a == b) { Ordering.EQ } else if (a) { Ordering.GT } else { Ordering.LT }
            case (TimeValue(a), TimeValue(b)) => compareInt(a, b)
            case (ListValue(a), ListValue(b)) => compareList(a, b)
            case _ => Ordering.EQ
        }
    }

    /**
     * 排序算子专用的严格比较：域不同即 `TYPE_MISMATCH`。
     *
     * 数值域内部允许 `Int64`/`Float64`/`Decimal` 互比（文档 §5 唯一允许的隐式提升）。
     */
    public func strictCompare(other: ValueKey): Ordering {
        if (domain != other.domain) {
            throw RuleException(
                RuleErrorCode.TYPE_MISMATCH,
                "跨域比较不支持: ${domain} vs ${other.domain}"
            )
        }
        compare(other)
    }

    public operator func ==(other: ValueKey): Bool {
        compare(other) == Ordering.EQ
    }

    public operator func !=(other: ValueKey): Bool {
        !(this == other)
    }

    public operator func <(other: ValueKey): Bool {
        compare(other) == Ordering.LT
    }

    public operator func >(other: ValueKey): Bool {
        compare(other) == Ordering.GT
    }

    public operator func <=(other: ValueKey): Bool {
        compare(other) != Ordering.GT
    }

    public operator func >=(other: ValueKey): Bool {
        compare(other) != Ordering.LT
    }

    public func hashCode(): Int64 {
        match (inner) {
            // 数值统一按规范浮点哈希：保证 Int64(1) 与 Float64(1.0) 同 hash。
            case IntNumber(v) => Float64(v).hashCode()
            case RealNumber(v) => v.hashCode()
            case DecimalNumber(v) => v.toFloat64().hashCode()
            case TextValue(v) => v.hashCode()
            case BoolValue(v) => v.hashCode()
            case TimeValue(v) => v.hashCode()
            case ListValue(v) =>
                var h: Int64 = 17
                for (item in v) {
                    h = h ^ item.hashCode()
                }
                h
        }
    }

    /**
     * 完整可复现的文本编码（含列表元素），供节点签名等需要区分"同长度不同内容"的场合。
     *
     * [toString] 对列表只输出长度，不能作为签名键。
     */
    public func encode(): String {
        match (inner) {
            case IntNumber(v) => "i:${v}"
            case RealNumber(v) => "r:${v}"
            case DecimalNumber(v) => "d:${v}"
            case TextValue(v) => "s:${ValueKey.escape(v)}"
            case BoolValue(v) => "b:${v}"
            case TimeValue(v) => "t:${v}"
            case ListValue(v) =>
                var out = "l:["
                for (item in v) {
                    out = out + item.encode() + ","
                }
                out + "]"
        }
    }

    /** 文本值里的分隔符转义，避免 `a,b` 与 `[a, b]` 撞码。 */
    private static func escape(text: String): String {
        text.replace("\\", "\\\\").replace(",", "\\,").replace("[", "\\[").replace("]", "\\]")
    }

    public func toString(): String {
        match (inner) {
            case IntNumber(v) => "${v}"
            case RealNumber(v) => "${v}"
            case DecimalNumber(v) => "${v}"
            case TextValue(v) => "\"${v}\""
            case BoolValue(v) => "${v}"
            case TimeValue(v) => "time(${v})"
            case ListValue(v) => "list(${v.size})"
        }
    }

    private static func compareInt(a: Int64, b: Int64): Ordering {
        if (a == b) {
            Ordering.EQ
        } else if (a < b) {
            Ordering.LT
        } else {
            Ordering.GT
        }
    }

    private static func compareReal(a: Float64, b: Float64): Ordering {
        if (a.isNaN() || b.isNaN()) {
            // NaN 参与全序：NaN 视为小于任何非 NaN，两个 NaN 相等。
            if (a.isNaN() && b.isNaN()) {
                return Ordering.EQ
            }
            return if (a.isNaN()) {
                Ordering.LT
            } else {
                Ordering.GT
            }
        }
        if (a == b) {
            Ordering.EQ
        } else if (a < b) {
            Ordering.LT
        } else {
            Ordering.GT
        }
    }

    private static func compareText(a: String, b: String): Ordering {
        if (a == b) {
            Ordering.EQ
        } else if (a < b) {
            Ordering.LT
        } else {
            Ordering.GT
        }
    }

    private static func compareList(a: ArrayList<ValueKey>, b: ArrayList<ValueKey>): Ordering {
        let n = if (a.size < b.size) {
            a.size
        } else {
            b.size
        }
        var i = 0
        while (i < n) {
            let result = a[i].compare(b[i])
            if (result != Ordering.EQ) {
                return result
            }
            i += 1
        }
        compareInt(Int64(a.size), Int64(b.size))
    }
}
