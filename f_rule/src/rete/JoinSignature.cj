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

import std.collection.ArrayList
import fountain::f_rule.condition.JoinConstraint

/**
 * beta 节点共享键（`doc/04-rete-network.md` §4.2）。
 *
 * 要求左侧路径完全一致：`(左 memory 引用, 右 alpha memory id, 归一化 join 约束)`。
 * 约束在入签名前排序，保证相同集合产生相同签名（`NetworkBuilder` 负责）。
 */
public class JoinSignature <: Hashable & Equatable<JoinSignature> & ToString {
    public let leftRef: String
    public let rightAlphaId: Int64
    public let joinKeys: Array<String>
    private let key_: String

    public init(leftSource: BetaLeft, rightAlphaId: Int64, joins: Array<JoinConstraint>) {
        this.leftRef = leftSource.toString()
        this.rightAlphaId = rightAlphaId
        this.joinKeys = JoinSignature.sortJoins(joins)
        var built = "${leftRef}\u{0001}${rightAlphaId}\u{0001}"
        for (item in joinKeys) {
            built = built + item + "\u{0002}"
        }
        this.key_ = built
    }

    public func key(): String {
        key_
    }

    /** 排序后的连接约束文本；相等签名必须得到相同顺序。 */
    public static func sortJoins(joins: Array<JoinConstraint>): Array<String> {
        let keys = ArrayList<String>()
        for (join in joins) {
            keys.add(JoinSignature.joinKey(join))
        }
        var i = 1
        while (i < keys.size) {
            let current = keys[i]
            var j = i - 1
            while (j >= 0 && keys[j] > current) {
                keys[j + 1] = keys[j]
                j -= 1
            }
            keys[j + 1] = current
            i += 1
        }
        keys.toArray()
    }

    public static func joinKey(join: JoinConstraint): String {
        "${join.leftBinding}.${join.leftField} ${join.op} ${join.rightBinding}.${join.rightField}"
    }

    public operator func ==(other: JoinSignature): Bool {
        this.key_ == other.key_
    }

    public operator func !=(other: JoinSignature): Bool {
        !(this == other)
    }

    public func hashCode(): Int64 {
        key_.hashCode()
    }

    public func toString(): String {
        key_
    }
}
