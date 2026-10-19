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

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.base.*

/**
 * S2.6 `LocalTypes` 的失败用例（先写红）。
 *
 * 权威 = `doc/jit-bytecode-m1.md` §11.7「局部类型表」：每槽 1 字节，覆盖全部 `nLocals` 槽；
 * `13–255 保留（加载器拒绝）`；值型 0–3 存原始 cell、句柄型 4–12 存句柄 ID。
 * 合法集**按单元 `verMajor` 分派**（v1:0–12、v2:0–14、v3:0–19，design-m1 §2.3.8）。
 */
@Test
public class LocalTypes_test {
    /** 槽读写与越界拒绝；`size` = 构造时给定的槽数。 */
    @TestCase
    public func slotReadWriteAndOutOfRange(): Unit {
        let t = LocalTypes(4)
        @Assert(t.size, 4)
        for (i in 0..4) {
            @Assert(t.get(i), 0u8) // 默认 0 = Int64
        }
        t.set(0, UInt8(LocalType.STRING))
        t.set(3, UInt8(LocalType.CLOSURE))
        @Assert(t.get(0), UInt8(LocalType.STRING))
        @Assert(t.get(3), UInt8(LocalType.CLOSURE))

        var rejected = 0
        try {
            t.get(-1)
        } catch (ex: JitException) {
            rejected = rejected + 1
        }
        try {
            t.get(4)
        } catch (ex: JitException) {
            rejected = rejected + 1
        }
        try {
            t.set(9, UInt8(LocalType.I64))
        } catch (ex: JitException) {
            rejected = rejected + 1
        }
        @Assert(rejected, 3)
    }

    /** 每槽 1 字节：序列化长度 = `nLocals`，且逐字节往返。 */
    @TestCase
    public func oneBytePerSlot(): Unit {
        let t = LocalTypes(3)
        t.set(0, UInt8(LocalType.I64))
        t.set(1, UInt8(LocalType.DECIMAL))
        t.set(2, UInt8(LocalType.LIST))
        let w = ByteWriter()
        t.write(w)
        let bs = w.take()
        @Assert(bs.size, 3)
        @Assert(bs[0], 0u8)
        @Assert(bs[1], 5u8)
        @Assert(bs[2], 10u8)

        let back = LocalTypes.read(bs)
        @Assert(back.size, 3)
        @Assert(back.get(1), UInt8(LocalType.DECIMAL))
        @Assert(back.get(2), UInt8(LocalType.LIST))
    }

    /** 长度 ≠ `nLocals` ⇒ 拒绝（加载器校验「恰 `nLocals` 字节」，§11.7）。 */
    @TestCase
    public func wrongLengthIsRejected(): Unit {
        let dir = FuncDir()
        dir.add(FuncEntry(0u32, 30u32, 8u32, 30u32,
            0u16, 5u16, 1u16, LocalType.I64, 0u16))
        let t = LocalTypes(4) // 目录说 5，实际 4
        var rejected = false
        try {
            t.validate(dir, 0u32)
        } catch (ex: JitException) {
            @Assert(ex.code, ErrCode.NOT_IMPL)
            rejected = true
        }
        @Assert(rejected, true)
    }

    /** 类型值非法 ⇒ 拒绝，且**按 verMajor 分派**（v1 拒 13+；v2 放行 13/14；v3 放行 15–19）。 */
    @TestCase
    public func illegalTypeValuesRejectedByVerMajor(): Unit {
        let dir = FuncDir()
        dir.add(FuncEntry(0u32, 30u32, 8u32, 30u32,
            0u16, 1u16, 1u16, LocalType.I64, 0u16))

        // v1：13 拒绝、12 放行
        let v1bad = LocalTypes(1)
        v1bad.set(0, 13u8)
        var r1 = false
        try {
            v1bad.validate(dir, 0u32, 1u16)
        } catch (ex: JitException) {
            r1 = true
        }
        @Assert(r1, true)

        let v1ok = LocalTypes(1)
        v1ok.set(0, 12u8)
        v1ok.validate(dir, 0u32, 1u16)

        // v2：13 / 14 放行，15 拒绝
        for (code in 13..15) {
            let v2 = LocalTypes(1)
            v2.set(0, UInt8(code))
            v2.validate(dir, 0u32, 2u16)
        }
        let v2bad = LocalTypes(1)
        v2bad.set(0, 15u8)
        var r2 = false
        try {
            v2bad.validate(dir, 0u32, 2u16)
        } catch (ex: JitException) {
            r2 = true
        }
        @Assert(r2, true)

        // v3：15–19 放行，20 拒绝
        for (code in 15..20) {
            let v3 = LocalTypes(1)
            v3.set(0, UInt8(code))
            v3.validate(dir, 0u32, 3u16)
        }
        let v3bad = LocalTypes(1)
        v3bad.set(0, 20u8)
        var r3 = false
        try {
            v3bad.validate(dir, 0u32, 3u16)
        } catch (ex: JitException) {
            r3 = true
        }
        @Assert(r3, true)

        // 255 在任何主版本都拒绝
        let vmax = LocalTypes(1)
        vmax.set(0, 255u8)
        var r4 = false
        try {
            vmax.validate(dir, 0u32, 3u16)
        } catch (ex: JitException) {
            r4 = true
        }
        @Assert(r4, true)
    }

    /** 规则集参数化校验（Q2.3）：与加载器取用同一规则集对象，逐码对齐全 0–255 边界。 */
    @TestCase
    public func validateAgainstSharedRuleSet(): Unit {
        let dir = FuncDir()
        dir.add(FuncEntry(0u32, 30u32, 8u32, 30u32,
            0u16, 1u16, 1u16, LocalType.I64, 0u16))
        for (rules in [FbcRuleRegistry.V1, FbcRuleRegistry.V2, FbcRuleRegistry.V3]) {
            for (c in 0..256) {
                let t = LocalTypes(1)
                t.set(0, UInt8(c))
                var ok = true
                try {
                    t.validate(dir, 0u32, rules)
                } catch (_: JitException) {
                    ok = false
                }
                @Assert(ok, rules.isLocalTypeInLegalSet(UInt16(c)))
            }
        }
    }

    /** `isHandleSlot(4..14) = true`、值型 0–3 为 false（§11.7 + M2 §2 的 13/14）。 */
    @TestCase
    public func isHandleSlotSplitsAtFour(): Unit {
        let t = LocalTypes(16)
        for (i in 0..16) {
            t.set(i, UInt8(i))
        }
        for (i in 0..4) {
            @Assert(t.isHandleSlot(i), false)
        }
        for (i in 4..15) {
            @Assert(t.isHandleSlot(i), true)
        }
        // 15（M3 登记位）不是句柄型
        @Assert(t.isHandleSlot(15), false)
        // 越界槽不为句柄（且不抛）
        @Assert(t.isHandleSlot(16), false)
    }

    /**
     * 规则集与 `LocalType.isLegal` 的合法集边界**同源**：对已实现的 v1/v2 规则集，
     * 逐码（0–255）判定必须与 `LocalType.isLegal(code, verMajor)` 完全一致。
     * v3 仅登记（`implemented=false`）⇒ 规则集一律拒绝，这是加载期开关而非边界差异。
     */
    @TestCase
    public func ruleSetBoundaryMatchesLocalTypeIsLegal(): Unit {
        for ((rs, major) in [(FbcRuleRegistry.V1, 1u16), (FbcRuleRegistry.V2, 2u16)]) {
            for (code in 0..256) {
                @Assert(rs.isLocalTypeLegal(UInt16(code)), LocalType.isLegal(UInt16(code), major))
            }
        }
        let v3 = FbcRuleRegistry.V3
        @Assert(v3.isLocalTypeLegal(16u16), false)
        @Assert(v3.isLocalTypeLegal(19u16), false)
    }
}
