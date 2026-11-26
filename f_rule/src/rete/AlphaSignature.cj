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

import fountain::f_rule.condition.{Constraint, Operand}
import fountain::f_rule.fact.ValueKey

/**
 * alpha 节点共享键（`doc/04-rete-network.md` §4.1）。
 *
 * 归一化为 `(typeTag, field, op, 归一值, 右字段)`；类型只做类型过滤时为全空签名。
 * 用字符串 `key` 做判等与哈希：`?ValueKey` 无法直接参与 `HashMap` 键，
 * 且调试时日志可直接输出可读的签名。
 *
 * 约束在入签名前由 `NetworkBuilder` 排序，保证相同约束集合产生相同签名。
 */
public class AlphaSignature <: Hashable & Equatable<AlphaSignature> & ToString {
    public let typeTag: String
    public let field: String
    public let opName: String
    public let value: ?ValueKey
    public let rightField: ?String
    public let negated: Bool
    /** 父路径签名；alpha 网络是树，路径不同的节点即使末约束相同也不共享 memory。 */
    public let parentKey: String
    private let key_: String

    public init(typeTag: String, field!: String = "", opName!: String = "", value!: ?ValueKey = None,
        rightField!: ?String = None, negated!: Bool = false, parentKey!: String = "") {
        this.typeTag = typeTag
        this.field = field
        this.opName = opName
        this.value = value
        this.rightField = rightField
        this.negated = negated
        this.parentKey = parentKey
        this.key_ = AlphaSignature.buildKey(parentKey, typeTag, field, opName, value, rightField, negated)
    }

    /** 只按 `typeTag` 过滤的类型节点签名。 */
    public static func typeOnly(typeTag: String): AlphaSignature {
        AlphaSignature(typeTag)
    }

    /** 由单事实约束构造签名；`Bind` 右值在构建期已被校验器拒绝。 */
    public static func fromConstraint(typeTag: String, constraint: Constraint,
        parentKey!: String = ""): AlphaSignature {
        let value = match (constraint.right) {
            case Operand.Const(raw) => AlphaSignature.valueOf(raw)
            case _ => Option<ValueKey>.None
        }
        let rightField = match (constraint.right) {
            case Operand.Field(name) => Some(name)
            case _ => Option<String>.None
        }
        AlphaSignature(typeTag, field: constraint.field, opName: constraint.op.toString(),
            value: value, rightField: rightField, negated: constraint.negated, parentKey: parentKey)
    }

    /** 不支持归一的常量退化为 None（测试闭包仍按原约束求值，语义不受影响）。 */
    private static func valueOf(raw: Any): ?ValueKey {
        try {
            Some(ValueKey.of(raw))
        } catch (e: Exception) {
            None
        }
    }

    public func key(): String {
        key_
    }

    public operator func ==(other: AlphaSignature): Bool {
        this.key_ == other.key_
    }

    public operator func !=(other: AlphaSignature): Bool {
        !(this == other)
    }

    public func hashCode(): Int64 {
        key_.hashCode()
    }

    public func toString(): String {
        key_
    }

    private static func buildKey(parentKey: String, typeTag: String, field: String, opName: String,
        value: ?ValueKey, rightField: ?String, negated: Bool): String {
        let valueText = match (value) {
            case Some(found) => found.encode()
            case None => "-"
        }
        let rightText = match (rightField) {
            case Some(found) => found
            case None => "-"
        }
        "${parentKey}\u{0002}${typeTag}\u{0001}${field}\u{0001}${opName}\u{0001}${valueText}\u{0001}${rightText}\u{0001}${negated}"
    }
}
