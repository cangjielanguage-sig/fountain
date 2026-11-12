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
package fountain::f_rule.rete

import fountain::f_rule.fact.ValueKey

/**
 * 有序索引的复合键 `(ValueKey, ownerId)`（`doc/04-rete-network.md` §7.1）。
 *
 * `ValueKey` 是全序，但同值多事实会互相覆盖，因此用 `ownerId`（`FactHandle.id`
 * 或 `Token.id`）兜底，保证跳表的键唯一。比较先按值、再按 id。
 */
public class RangeKey <: Comparable<RangeKey> & Hashable & ToString {
    public let key: ValueKey
    public let ownerId: Int64

    public init(key: ValueKey, ownerId: Int64) {
        this.key = key
        this.ownerId = ownerId
    }

    public func compare(other: RangeKey): Ordering {
        let byValue = key.compare(other.key)
        if (byValue != Ordering.EQ) {
            return byValue
        }
        if (ownerId == other.ownerId) {
            Ordering.EQ
        } else if (ownerId < other.ownerId) {
            Ordering.LT
        } else {
            Ordering.GT
        }
    }

    public operator func ==(other: RangeKey): Bool {
        this.key == other.key && this.ownerId == other.ownerId
    }

    public operator func !=(other: RangeKey): Bool {
        !(this == other)
    }

    @OverflowWrapping
    public func hashCode(): Int64 {
        key.hashCode() * 31 + ownerId
    }

    public func toString(): String {
        "(${key.toString()}, ${ownerId})"
    }
}
