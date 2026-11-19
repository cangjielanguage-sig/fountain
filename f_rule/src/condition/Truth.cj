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
package fountain::f_rule.condition

import std.collection.{ArrayList, ReadOnlySet}
import fountain::f_regex.*
import fountain::f_rule.exception.*
import fountain::f_rule.fact.ValueKey

/**
 * 三值逻辑（`doc/03-condition-expression.md` §2.1）。
 *
 * 与 SQL 一致：字段缺失不是 `False` 而是 `Unknown`；`Not Unknown` 仍是 `Unknown`；
 * 规则匹配只接受 [True]，因此 `Unknown` 与 `False` 等价（都不产生激活）。
 */
public enum Truth <: ToString & Equatable<Truth> {
    | True
    | False
    | Unknown

    public func and(other: Truth): Truth {
        match (this) {
            case False => Truth.False
            case True => other
            case Unknown =>
                match (other) {
                    case False => Truth.False
                    case _ => Truth.Unknown
                }
        }
    }

    public func or(other: Truth): Truth {
        match (this) {
            case True => Truth.True
            case False => other
            case Unknown =>
                match (other) {
                    case True => Truth.True
                    case _ => Truth.Unknown
                }
        }
    }

    public func not(): Truth {
        match (this) {
            case True => Truth.False
            case False => Truth.True
            case Unknown => Truth.Unknown
        }
    }

    /** 只有 `True` 产生激活。 */
    public func isTrue(): Bool {
        match (this) {
            case True => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case True => "True"
            case False => "False"
            case Unknown => "Unknown"
        }
    }

    public operator func ==(other: Truth): Bool {
        this.toString() == other.toString()
    }

    public operator func !=(other: Truth): Bool {
        !(this == other)
    }
}

/**
 * 算子求值器（`doc/03-condition-expression.md` §2）。
 *
 * 入参是**已解析**的左右值：`None` 表示字段缺失，由本层决定它是 `Unknown` 还是
 * 被 `IsNull/NotNull` 命中。跨域排序抛 `TYPE_MISMATCH`（设计 D4：索引层只定位，
 * 语义由算子层把关）。
 */
public class OperatorEvaluator {
    private init() {}

    public static func apply(op: Operator, left: ?Any, right: ?Any): Truth {
        match (op) {
            case IsNull => return if (left.isNone()) {
                Truth.True
            } else {
                Truth.False
            }
            case NotNull => return if (left.isSome()) {
                Truth.True
            } else {
                Truth.False
            }
            case _ => ()
        }
        let leftValue = match (left) {
            case Some(v) => v
            case None => return Truth.Unknown
        }
        let rightValue = match (right) {
            case Some(v) => v
            case None => return Truth.Unknown
        }

        match (op) {
            case Eq => bool(equalValues(leftValue, rightValue))
            case Ne => bool(!equalValues(leftValue, rightValue))
            case Gt => compare(leftValue, rightValue, { o => o == Ordering.GT })
            case Ge => compare(leftValue, rightValue, { o => o != Ordering.LT })
            case Lt => compare(leftValue, rightValue, { o => o == Ordering.LT })
            case Le => compare(leftValue, rightValue, { o => o != Ordering.GT })
            case Contains => contains(leftValue, rightValue)
            case StartsWith => stringPair(leftValue, rightValue, { s, prefix => s.startsWith(prefix) })
            case EndsWith => stringPair(leftValue, rightValue, { s, suffix => s.endsWith(suffix) })
            case In => membership(leftValue, rightValue, true)
            case NotIn => membership(leftValue, rightValue, false)
            case Matches => matches(leftValue, rightValue)
            case Between => between(leftValue, rightValue)
            case IsNull | NotNull => Truth.Unknown
        }
    }

    /**
     * 等值判定。
     *
     * 同类型基本值直比，省掉两次 `ValueKey` 归一分配；跨类型（`Int64` vs `Float64`、
     * 时间、列表）仍走 `ValueKey`，保证 `Int64(1) == Float64(1.0)` 等契约不变。
     */
    private static func equalValues(left: Any, right: Any): Bool {
        match ((left, right)) {
            case (a: Int64, b: Int64) => a == b
            case (a: String, b: String) => a == b
            case (a: Bool, b: Bool) => a == b
            case _ => ValueKey.of(left) == ValueKey.of(right)
        }
    }

    private static func bool(value: Bool): Truth {
        if (value) {
            Truth.True
        } else {
            Truth.False
        }
    }

    /** 排序比较；同类型基本值直比，跨类型仍由 `ValueKey.strictCompare` 抛 `TYPE_MISMATCH`。 */
    private static func compare(left: Any, right: Any, test: (Ordering) -> Bool): Truth {
        let ordering = match ((left, right)) {
            case (a: Int64, b: Int64) => orderingOf(a, b)
            case (a: String, b: String) => orderingOf(a, b)
            case _ => ValueKey.of(left).strictCompare(ValueKey.of(right))
        }
        bool(test(ordering))
    }

    private static func orderingOf(left: Int64, right: Int64): Ordering {
        if (left == right) {
            Ordering.EQ
        } else if (left < right) {
            Ordering.LT
        } else {
            Ordering.GT
        }
    }

    private static func orderingOf(left: String, right: String): Ordering {
        if (left == right) {
            Ordering.EQ
        } else if (left < right) {
            Ordering.LT
        } else {
            Ordering.GT
        }
    }

    private static func stringPair(left: Any, right: Any, test: (String, String) -> Bool): Truth {
        match ((left, right)) {
            case (leftText: String, rightText: String) => bool(test(leftText, rightText))
            case _ => throw RuleException(
                RuleErrorCode.TYPE_MISMATCH,
                "算子要求左右都是字符串"
            )
        }
    }

    private static func contains(left: Any, right: Any): Truth {
        match (left) {
            case text: String =>
                match (right) {
                    case part: String => bool(text.contains(part))
                    case _ => throw RuleException(RuleErrorCode.TYPE_MISMATCH, "字符串包含要求右值是字符串")
                }
            case _ =>
                match (elements(left)) {
                    case Some(items) => bool(containsElement(items, right))
                    case None => throw RuleException(
                        RuleErrorCode.TYPE_MISMATCH,
                        "Contains 的左值必须是字符串或集合"
                    )
                }
        }
    }

    private static func membership(left: Any, right: Any, positive: Bool): Truth {
        let items = match (elements(right)) {
            case Some(found) => found
            case None => throw RuleException(
                RuleErrorCode.TYPE_MISMATCH,
                "In/NotIn 的右值必须是集合"
            )
        }
        // C-02：空集合恒为 false；NotIn 取反后恒为 true
        let found = containsElement(items, left)
        bool(if (positive) { found } else { !found })
    }

    private static func matches(left: Any, right: Any): Truth {
        match ((left, right)) {
            case (text: String, pattern: String) =>
                try {
                    bool(pattern.regex().matches(text))
                } catch (e: Exception) {
                    throw RuleException(RuleErrorCode.TYPE_MISMATCH, "正则表达式非法: ${pattern}", e)
                }
            case _ => throw RuleException(RuleErrorCode.TYPE_MISMATCH, "Matches 要求左右都是字符串")
        }
    }

    private static func between(left: Any, right: Any): Truth {
        let items = match (elements(right)) {
            case Some(found) => found
            case None => throw RuleException(
                RuleErrorCode.TYPE_MISMATCH,
                "Between 的右值必须是二元集合"
            )
        }
        if (items.size != 2) {
            throw RuleException(RuleErrorCode.TYPE_MISMATCH, "Between 的右值必须恰好两个元素")
        }
        let target = ValueKey.of(left)
        let low = ValueKey.of(items[0])
        let high = ValueKey.of(items[1])
        let geLow = target.strictCompare(low) != Ordering.LT
        let leHigh = target.strictCompare(high) != Ordering.GT
        bool(geLow && leHigh)
    }

    private static func containsElement(items: Array<Any>, target: Any): Bool {
        let key = ValueKey.of(target)
        for (item in items) {
            if (ValueKey.of(item) == key) {
                return true
            }
        }
        false
    }

    /** 统一把 `Array` / `ArrayList` / 只读集合转成数组；非集合返回 None。 */
    static func elements(value: Any): ?Array<Any> {
        match (value) {
            case items: Array<Any> => Some(items)
            case items: ArrayList<Any> => Some(items.toArray())
            case items: ReadOnlySet<Any> => Some(items.toArray())
            case _ => None
        }
    }
}
