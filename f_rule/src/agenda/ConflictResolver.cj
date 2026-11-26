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
package fountain::f_rule.agenda

import std.collection.ArrayList
import fountain::f_rule.rule.{ConflictKey, ConflictResolver, DefaultConflictResolver}

/** 按 `salience` 降序。 */
public class SalienceResolver <: ConflictResolver {
    public init() {}

    public func compare(left: ConflictKey, right: ConflictKey): Ordering {
        ConflictCompare.desc(left.salience, right.salience)
    }
}

/** 按条件数降序（更具体的规则优先）。 */
public class SpecificityResolver <: ConflictResolver {
    public init() {}

    public func compare(left: ConflictKey, right: ConflictKey): Ordering {
        ConflictCompare.desc(left.specificity, right.specificity)
    }
}

/** 按产生顺序升序（先到先执行）。 */
public class FifoResolver <: ConflictResolver {
    public init() {}

    public func compare(left: ConflictKey, right: ConflictKey): Ordering {
        ConflictCompare.asc(left.seq, right.seq)
    }
}

/** 按产生顺序降序（后到先执行）。 */
public class LifoResolver <: ConflictResolver {
    public init() {}

    public func compare(left: ConflictKey, right: ConflictKey): Ordering {
        ConflictCompare.desc(left.seq, right.seq)
    }
}

/** 按规则在规则集中的声明顺序升序。 */
public class RuleOrderResolver <: ConflictResolver {
    public init() {}

    public func compare(left: ConflictKey, right: ConflictKey): Ordering {
        ConflictCompare.asc(left.ruleOrder, right.ruleOrder)
    }
}

/** 按规则 id 字典序，保证跨进程可复现。 */
public class RuleIdResolver <: ConflictResolver {
    public init() {}

    public func compare(left: ConflictKey, right: ConflictKey): Ordering {
        ConflictCompare.asc(left.ruleId, right.ruleId)
    }
}

/**
 * 组合策略：依次比较，前一级给出非 `EQ` 即返回。
 *
 * 全部返回 `EQ` 时用 `seq → factSpace → ruleId` 兜底，保证任意两个异激活结果不为 `EQ`（A-04），
 * 堆顺序因此稳定、可复现。
 */
public class CompositeResolver <: ConflictResolver {
    private let resolvers_: Array<ConflictResolver>

    public init(resolvers: Array<ConflictResolver>) {
        let copy = ArrayList<ConflictResolver>()
        for (resolver in resolvers) {
            copy.add(resolver)
        }
        this.resolvers_ = copy.toArray()
    }

    public func compare(left: ConflictKey, right: ConflictKey): Ordering {
        for (resolver in resolvers_) {
            let result = resolver.compare(left, right)
            if (result != Ordering.EQ) {
                return result
            }
        }
        var result = ConflictCompare.asc(left.seq, right.seq)
        if (result != Ordering.EQ) {
            return result
        }
        result = ConflictCompare.asc(left.factSpace, right.factSpace)
        if (result != Ordering.EQ) {
            return result
        }
        ConflictCompare.asc(left.ruleId, right.ruleId)
    }
}

/** 预置策略工厂（`doc/05` §4.1）。 */
public class Resolvers {
    private init() {}

    public static func salience(): ConflictResolver {
        SalienceResolver()
    }

    public static func specificity(): ConflictResolver {
        SpecificityResolver()
    }

    public static func fifo(): ConflictResolver {
        FifoResolver()
    }

    public static func lifo(): ConflictResolver {
        LifoResolver()
    }

    public static func ruleOrder(): ConflictResolver {
        RuleOrderResolver()
    }

    public static func ruleId(): ConflictResolver {
        RuleIdResolver()
    }

    public static func composite(resolvers: Array<ConflictResolver>): ConflictResolver {
        CompositeResolver(resolvers)
    }

    /**
     * 默认链：`salience → specificity → ruleOrder → seq`。
     *
     * 复用 `rule.DefaultConflictResolver`：`RuleSet` 在构建期保存的默认策略就是它，
     * 议程与规则集必须用同一实现，否则同一批激活在两处排序可能不一致。
     */
    public static func defaultChain(): ConflictResolver {
        DefaultConflictResolver()
    }
}

class ConflictCompare {
    static func desc(left: Int64, right: Int64): Ordering {
        if (left == right) {
            Ordering.EQ
        } else if (left > right) {
            Ordering.LT
        } else {
            Ordering.GT
        }
    }

    static func asc(left: Int64, right: Int64): Ordering {
        if (left == right) {
            Ordering.EQ
        } else if (left < right) {
            Ordering.LT
        } else {
            Ordering.GT
        }
    }

    static func asc(left: String, right: String): Ordering {
        if (left == right) {
            Ordering.EQ
        } else if (left < right) {
            Ordering.LT
        } else {
            Ordering.GT
        }
    }
}
