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

import std.collection.{ArrayList, HashMap, ReadOnlySet}
import std.math.numeric.Decimal
import std.time.DateTime
import fountain::f_rule.exception.*

/**
 * 动态字典事实（`doc/02-fact-model.md` §4）。
 *
 * 字段值只允许 `String / Int64 / Float64 / Bool / DateTime / Decimal / Array<Any>`（及
 * 只读集合形态）；其余类型在**写入时**抛 `TYPE_MISMATCH`，不做隐式字符串化。
 * 不支持嵌套 `Fact`：需要关联查询时拆成多条事实 + join 约束。
 *
 * `FactBase.assert` 会自动 [freeze]；冻结后任何 `set` / `remove` 抛 `ILLEGAL_STATE`。
 */
public class DynamicFact <: Fact & IdentifiedFact {
    private let typeTag_: String
    private let values_: HashMap<String, Any>
    private let order_: ArrayList<String>
    private var frozen_: Bool
    private let identity_: Int64

    public init(typeTag: String) {
        this.typeTag_ = typeTag
        this.values_ = HashMap<String, Any>()
        this.order_ = ArrayList<String>()
        this.frozen_ = false
        this.identity_ = FactIdentity.next()
    }

    public prop identity: Int64 {
        get() {
            identity_
        }
    }

    /**
     * 批量构造；逐项校验，任一项非法立即抛 `TYPE_MISMATCH`。
     *
     * 字段顺序不稳定（`HashMap` 无序），`fields()` 只保证"包含哪些字段"。
     */
    public init(typeTag: String, values: HashMap<String, Any>) {
        this(typeTag)
        for ((name, value) in values) {
            set(name, value)
        }
    }

    public prop typeTag: String {
        get() {
            typeTag_
        }
    }

    public func get(field: String): ?Any {
        values_.get(field)
    }

    public func has(field: String): Bool {
        values_.contains(field)
    }

    /** 写入字段；冻结后抛 `ILLEGAL_STATE`，非法类型抛 `TYPE_MISMATCH`。 */
    public func set(field: String, value: Any): Unit {
        ensureMutable()
        DynamicFact.checkValue(field, value)
        if (!values_.contains(field)) {
            order_.add(field)
        }
        values_[field] = value
    }

    /** 删除字段；字段不存在时静默返回。冻结后抛 `ILLEGAL_STATE`。 */
    public func remove(field: String): Unit {
        ensureMutable()
        if (values_.contains(field)) {
            values_.remove(field)
            var i = 0
            while (i < order_.size) {
                if (order_[i] == field) {
                    order_.remove(at: i)
                    break
                }
                i += 1
            }
        }
    }

    /** 冻结：之后 `set` / `remove` 抛 `ILLEGAL_STATE`。幂等。 */
    public func freeze(): Unit {
        frozen_ = true
    }

    public prop frozen: Bool {
        get() {
            frozen_
        }
    }

    /** 当前字段名（声明顺序，批量构造时按写入顺序）。 */
    public func fields(): Array<String> {
        order_.toArray()
    }

    private func ensureMutable(): Unit {
        if (frozen_) {
            throw RuleException(
                RuleErrorCode.ILLEGAL_STATE,
                "DynamicFact(${typeTag_}) 已冻结，不能再修改字段"
            )
        }
    }

    /** 值类型白名单校验；列表元素递归校验。 */
    static func checkValue(field: String, value: Any): Unit {
        match (value) {
            case _: String => ()
            case _: Int64 => ()
            case _: Float64 => ()
            case _: Bool => ()
            case _: DateTime => ()
            case _: Decimal => ()
            case items: Array<Any> =>
                for (item in items) {
                    checkValue(field, item)
                }
            case items: ArrayList<Any> =>
                for (item in items) {
                    checkValue(field, item)
                }
            case items: ReadOnlySet<Any> =>
                for (item in items) {
                    checkValue(field, item)
                }
            case _ =>
                throw RuleException(
                    RuleErrorCode.TYPE_MISMATCH,
                    "DynamicFact 字段 ${field} 的值类型不受支持；允许 String/Int64/Float64/Bool/DateTime/Decimal/Array<Any>/Set<Any>"
                )
        }
    }
}
