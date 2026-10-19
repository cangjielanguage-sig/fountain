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

/**
 * S2.1 `OpInfo` 的失败用例（先写红）。
 *
 * 权威 = `doc/jit-bytecode-m1.md` §10.3 的 opcode 常量表（全量 256 项显式列出）与 §10.2
 * 的操作数编码种类表（`-`/`u8`/`i8`/`u16`/`i32`/`rel32`/`i64`/`u16 u8`）。
 * 类别码语义见 §10.1：RSVD（未分配槽 + 0xC0–FF）在 M1 中发射即 `ERR_NOT_IMPL`，
 * FORBID（0xA9–AA 时间构造，M2 启用）同样发射即报错。
 */
@Test
public class OpInfo_test {
    /** 表规模 256 且自洽：`table[i].code == i`（§10.3「全量 256 项显式列出」）。 */
    @TestCase
    public func tableIs256AndSelfIndexed(): Unit {
        let t = OpInfo.OPCODE_TABLE
        @Assert(t.size, 256)
        for (i in 0..256) {
            @Assert(Int64(t[i].code), Int64(i))
        }
    }

    /** 禁区与保留区：0xA9/0xAA = CAT_FORBID；0xC0–0xFF 全 RSVD（§10.1、§10.3）。 */
    @TestCase
    public func forbiddenAndReservedRegions(): Unit {
        let t = OpInfo.OPCODE_TABLE
        @Assert(t[0xA9].cat, OpInfo.CAT_FORBID)
        @Assert(t[0xAA].cat, OpInfo.CAT_FORBID)
        @Assert(t[0xA9].name, 'OP_DT_NEW')
        @Assert(t[0xAA].name, 'OP_DUR_NEW')
        for (i in 0xC0..0x100) {
            @Assert(t[i].cat, OpInfo.CAT_RSVD)
            @Assert(t[i].name, 'OP_RSVD')
        }
        // 禁区之外的 A 区段已随 v0.5/v0.18 启用，归入 BOX（§10.1 末句）
        @Assert(t[0xA0].cat, OpInfo.CAT_BOX)
        @Assert(t[0xAF].cat, OpInfo.CAT_BOX)
    }

    /** 已分配代表项与 §10.3 逐条核对（任务书点名的四条 + 若干跨段抽查）。 */
    @TestCase
    public func representativeEntriesMatchSpec(): Unit {
        let t = OpInfo.OPCODE_TABLE
        // SET_SITE = 0x03，i32 操作数，总长 5，MISC
        @Assert(t[0x03].name, 'OP_SET_SITE')
        @Assert(t[0x03].fmt, 'i32')
        @Assert(t[0x03].len, 5)
        @Assert(t[0x03].cat, OpInfo.CAT_MISC)
        // CALL_HELPER = 0x75，"u16 u8"，总长 4，CALL
        @Assert(t[0x75].name, 'OP_CALL_HELPER')
        @Assert(t[0x75].fmt, 'u16 u8')
        @Assert(t[0x75].len, 4)
        @Assert(t[0x75].cat, OpInfo.CAT_CALL)
        // CALL_CLOSURE = 0x7F，u8，总长 2，CALL
        @Assert(t[0x7F].name, 'OP_CALL_CLOSURE')
        @Assert(t[0x7F].fmt, 'u8')
        @Assert(t[0x7F].len, 2)
        @Assert(t[0x7F].cat, OpInfo.CAT_CALL)
        // MAP_ITER_STEP = 0xBE，u8，总长 2，BOX
        @Assert(t[0xBE].name, 'OP_MAP_ITER_STEP')
        @Assert(t[0xBE].fmt, 'u8')
        @Assert(t[0xBE].len, 2)
        @Assert(t[0xBE].cat, OpInfo.CAT_BOX)
        // 跨段抽查：PUSH_I64 / LOADL / IADD / TO_STR / RET
        @Assert(t[0x12].name, 'OP_PUSH_I64')
        @Assert(t[0x12].len, 9)
        @Assert(t[0x20].name, 'OP_LOADL')
        @Assert(t[0x20].len, 3)
        @Assert(t[0x30].name, 'OP_IADD')
        @Assert(t[0x30].len, 1)
        @Assert(t[0xB7].name, 'OP_TO_STR')
        @Assert(t[0xB7].len, 2)
        @Assert(t[0x7C].name, 'OP_RET')
        @Assert(t[0x7C].cat, OpInfo.CAT_CALL)
    }

    /** `len == 1 + Σ operandSize(fmt)`（§10.3 一致性校验第 2 条）。 */
    @TestCase
    public func lengthConsistentWithOperandFormat(): Unit {
        @Assert(OpInfo.selfCheckOk(), true)
        let t = OpInfo.OPCODE_TABLE
        for (i in 0..256) {
            let e = t[i]
            @Assert(e.len, 1 + OpInfo.operandSize(e.fmt))
            // 未分配槽一律 1 字节、无操作数（§10.3「未分配槽统一 OP_RSVD」）
            if (e.cat == OpInfo.CAT_RSVD || e.cat == OpInfo.CAT_FORBID) {
                @Assert(e.fmt, '-')
                @Assert(e.len, 1)
            }
        }
    }

    /** 类别码 0–11 连续且与 §10.2 注释一致；`name` 与 `fmt` 恒非空。 */
    @TestCase
    public func categoryCodesAndTextFields(): Unit {
        @Assert(OpInfo.CAT_MISC, 0u8)
        @Assert(OpInfo.CAT_CONST, 1u8)
        @Assert(OpInfo.CAT_LOCAL, 2u8)
        @Assert(OpInfo.CAT_I64, 3u8)
        @Assert(OpInfo.CAT_F64, 4u8)
        @Assert(OpInfo.CAT_CMP, 5u8)
        @Assert(OpInfo.CAT_CTRL, 6u8)
        @Assert(OpInfo.CAT_CALL, 7u8)
        @Assert(OpInfo.CAT_TYPE, 8u8)
        @Assert(OpInfo.CAT_BOX, 9u8)
        @Assert(OpInfo.CAT_FORBID, 10u8)
        @Assert(OpInfo.CAT_RSVD, 11u8)
        for (i in 0..256) {
            @Assert(OpInfo.OPCODE_TABLE[i].name.isEmpty(), false)
            @Assert(OpInfo.OPCODE_TABLE[i].fmt.isEmpty(), false)
        }
    }
}
