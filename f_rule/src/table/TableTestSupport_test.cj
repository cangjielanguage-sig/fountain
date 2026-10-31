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

import fountain::f_jit.*
import fountain::f_jit.macros.*
import fountain::f_rule.condition.ExpressionMode
import fountain::f_rule.fact.{FactSchema, FactSpace, FactSpaceRegistry, FieldType}
import fountain::f_rule.rule.{DefaultConflictResolver, Rule, RuleSet}

/** 决策表测试宿主：订单。 */
@JitBind
public class TableOrder {
    public var id: String
    public var level: Int64
    public var amount: Int64

    public init(id: String, level: Int64, amount: Int64) {
        this.id = id
        this.level = level
        this.amount = amount
    }
}

public func tableOrderSchema(): FactSchema<TableOrder> {
    FactSchema<TableOrder>("Order")
        .field("id", FieldType.Text, { o => o.id })
        .field("level", FieldType.Number, { o => o.level })
        .field("amount", FieldType.Number, { o => o.amount })
}

/** 决策表测试宿主：优惠券（用于多类型空间）。 */
public class TableCoupon {
    public var code: String

    public init(code: String) {
        this.code = code
    }
}

public func tableCouponSchema(): FactSchema<TableCoupon> {
    FactSchema<TableCoupon>("Coupon")
        .field("code", FieldType.Text, { c => c.code })
}

/** 决策表测试宿主：用户。 */
public class TableUser {
    public var level: Int64
    public var vip: Bool

    public init(level: Int64, vip: Bool) {
        this.level = level
        this.vip = vip
    }
}

public func tableUserSchema(): FactSchema<TableUser> {
    FactSchema<TableUser>("User")
        .field("level", FieldType.Number, { u => u.level })
        .field("vip", FieldType.`Bool`, { u => u.vip })
}

/**
 * 构造只含注册表的最小 `RuleSet`。
 *
 * 表包不能 import 根包（根包会 import 表包形成循环），因此测试直接拼 `RuleSet`，
 * 不走 `RuleSetBuilder`。
 */
public func tableRuleSet(space: String, register: (FactSpace) -> Unit): RuleSet {
    let registry = FactSpaceRegistry()
    let target = registry.declare(space)
    register(target)
    registry.freeze()
    RuleSet("pricing", "v1", Array<Rule>(), registry,
        ExpressionMode.JitPreferred, DefaultConflictResolver())
}
