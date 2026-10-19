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
package fountain::f_jit.bytecode

import fountain::f_jit.base.LocalType
import fountain::f_jit.base.Version

/** `CALL_HOST`（0x79）—— M2 起合法（m2 §2）；M1 规则集不得出现。 */
internal const OP_CALL_HOST: UInt8 = 0x79u8

/** `CALL_HELPER` 家族：hid ≥ `USER_BASE` 即单元私有预定义函数（成员访问/构造的物化形态）。 */
internal const OP_CALL_HELPER: UInt8 = 0x75u8
internal const OP_CALL_HELPER_NC: UInt8 = 0x76u8
internal const OP_CALL_HELPER_V: UInt8 = 0x77u8
internal const HELPER_USER_BASE: UInt16 = 0x0100u16

/**
 * `.fbc` 加载校验规则集 —— design-m2 D12、spec「版本兼容矩阵与规则集分派」。
 *
 * 加载器不写死单一合法集，而是按单元 `verMajor` 取一份规则集：合法 LocalType 上限、
 * 可接受的 `verMinor` 区间、是否已实现。v1 / v2 为已实现规则集；v3 仅**登记**合法集
 * （0–19），本实现不启用 M3 语义，因此 `implemented = false`。
 */
public class FbcRuleSet {
    /** 本规则集对应的主版本。 */
    public let verMajor: UInt16

    /** 可接受的最小 `verMinor`。 */
    public let minVerMinor: UInt16

    /** 可接受的最大 `verMinor`（含）。 */
    public let maxVerMinor: UInt16

    /** 该版本允许的最大 LocalType 码（v1=12、v2=14、v3 登记 19）。 */
    public let maxLocalType: UInt16

    /** 规则集是否已实现；仅登记的规则集（v3）为 `false`，加载器遇之按 18 拒绝。 */
    public let implemented: Bool

    public init(
        verMajor: UInt16,
        minVerMinor: UInt16,
        maxVerMinor: UInt16,
        maxLocalType: UInt16,
        implemented: Bool
    ) {
        this.verMajor = verMajor
        this.minVerMinor = minVerMinor
        this.maxVerMinor = maxVerMinor
        this.maxLocalType = maxLocalType
        this.implemented = implemented
    }

    /**
     * LocalType 码是否落在本规则集的**登记合法集**内（不含「已实现」开关）。
     *
     * 与 `LocalType.isLegal` 同源：v1 0–12、v2 0–14、v3 0–19。该方法是边界判定的唯一事实
     * 来源（`LocalTypes.validate` 与规则集自检共用）；加载器是否启用由 `isLocalTypeLegal`
     * 额外叠加 `implemented`。
     */
    public func isLocalTypeInLegalSet(code: UInt16): Bool {
        LocalType.isLegal(code, this.verMajor)
    }

    /**
     * LocalType 码是否落在本规则集的合法集内（仅登记的规则集一律判假）。
     *
     * 边界判定与 `isLocalTypeInLegalSet` **同源**，本类只叠加「该版本规则集是否已实现」这一
     * 加载期开关，避免两处各写一份常量比较而漂移。
     */
    public func isLocalTypeLegal(code: UInt16): Bool {
        this.implemented && this.isLocalTypeInLegalSet(code)
    }

    /**
     * 该 opcode 是否为本规则集接受的指令（design-m2 D12「合法指令集」）。
     *
     * 唯一版本差异是 `CALL_HOST`：v1 只在汇编期预留（M1 从不产出，加载期亦不接受），
     * M2 起重定义为 `u8 argc` 并合法；v3 的登记面包含 M2 指令集。
     */
    public func isInstructionLegal(op: UInt8): Bool {
        if (op == OP_CALL_HOST) {
            this.verMajor >= Version.M2_MAJOR
        } else {
            true
        }
    }

    /**
     * 该 LocalType 码是否要求**类注册表**（design-m2 D12「14 槽注册表依赖校验」）。
     *
     * 只有 14（不透明宿主对象）依赖宿主类注册表；13（HostClosure）与 M3 的 JSON 内建码
     * 16–19 **零注册**。v1 的 14 本就不合法，故不构成依赖面。
     */
    public func isRegistryDependent(code: UInt16): Bool {
        this.verMajor >= Version.M2_MAJOR && code == LocalType.HOST_OBJECT
    }

    /** `verMinor` 是否落在本规则集的接受区间内（仅登记的规则集一律判假）。 */
    public func isVerMinorSupported(minor: UInt16): Bool {
        this.implemented && minor >= this.minVerMinor && minor <= this.maxVerMinor
    }
}

/**
 * 规则集注册表 —— 按 `verMajor` 取加载校验规则集（design-m2 D12）。
 *
 * 登记项与 `Version.supportedMajors()` 的区别：注册表含 v3（仅登记合法集边界），
 * `supportedMajors()` 只列**已实现**的加载版本（v1/v2）。
 */
public class FbcRuleRegistry {
    /** M1 规则集：LocalType 0–12、`verMinor ∈ [0, 14]`。 */
    public static let V1: FbcRuleSet = FbcRuleSet(
        Version.M1_MAJOR,
        0u16,
        Version.MINOR,
        LocalType.CLOSURE,
        true)

    /** M2 规则集：LocalType 0–14、`verMinor = 0`。 */
    public static let V2: FbcRuleSet = FbcRuleSet(
        Version.M2_MAJOR,
        Version.M2_MINOR,
        Version.M2_MINOR,
        14u16,
        true)

    /** M3 规则集：仅登记 LocalType 0–19（15=Any、16–19=JSON），不实现语义。 */
    public static let V3: FbcRuleSet = FbcRuleSet(Version.M3_MAJOR, 0u16, 0u16, 19u16, false)

    /** 按主版本取规则集；未登记的主版本返回 `None`。 */
    public static func get(major: UInt16): ?FbcRuleSet {
        if (major == Version.M1_MAJOR) {
            Some(V1)
        } else if (major == Version.M2_MAJOR) {
            Some(V2)
        } else if (major == Version.M3_MAJOR) {
            Some(V3)
        } else {
            None
        }
    }
}
