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
 * S2.3 `DecodedInsn` + `InsnDecoder` 的失败用例（先写红）。
 *
 * 权威 = `doc/jit-bytecode-m1.md` §10.2（操作数编码种类）、§10.3（定长指令表）、
 * §10.1（`rel` 为相对**下一条指令**的有符号 32 位偏移）。
 */
@Test
public class InsnDecoder_test {
    /** 按 fmt 解码各类指令并推进游标：op / size / operands 长度三者互证。 */
    @TestCase
    public func decodeByFormat(): Unit {
        let w = ByteWriter()
        w.wU8(0x7Cu8) // OP_RET，len 1
        w.wU8(0x20u8) // OP_LOADL u16
        w.wU16(0x0005u16)
        w.wU8(0x03u8) // OP_SET_SITE i32
        w.wI32(77i32)
        w.wU8(0x75u8) // OP_CALL_HELPER u16 u8
        w.wU16(0x0102u16)
        w.wU8(0x03u8)
        w.wU8(0x12u8) // OP_PUSH_I64 i64
        w.wI64(-42i64)
        let code = w.take()

        var off = 0
        let ret = InsnDecoder.decode(code, off)
        @Assert(ret.op, 0x7Cu8)
        @Assert(ret.size, 1)
        @Assert(ret.operands.size, 0)
        off = off + ret.size

        let loadl = InsnDecoder.decode(code, off)
        @Assert(loadl.op, 0x20u8)
        @Assert(loadl.size, 3)
        @Assert(InsnDecoder.u16(loadl, 0), 5u16)
        off = off + loadl.size

        let site = InsnDecoder.decode(code, off)
        @Assert(site.op, 0x03u8)
        @Assert(site.size, 5)
        @Assert(InsnDecoder.i32(site, 0), 77i32)
        off = off + site.size

        let call = InsnDecoder.decode(code, off)
        @Assert(call.op, 0x75u8)
        @Assert(call.size, 4)
        @Assert(InsnDecoder.u16(call, 0), 0x0102u16)
        @Assert(InsnDecoder.u8(call, 2), 0x03u8)
        off = off + call.size

        let push = InsnDecoder.decode(code, off)
        @Assert(push.op, 0x12u8)
        @Assert(push.size, 9)
        @Assert(InsnDecoder.i64(push, 0), -42i64)
        off = off + push.size

        @Assert(off, code.size)
    }

    /** `rel32` 目标 = 本指令之后的第一条指令位置 + 偏移（§10.1）。 */
    @TestCase
    public func rel32TargetIsNextInsnPlusOffset(): Unit {
        // 布局：off 0 = OP_JMP rel32(5)；下一条指令位置 = 5 ⇒ 目标 5+5 = 10（正好是 RET）
        let w = ByteWriter()
        w.wU8(0x70u8) // OP_JMP @0
        w.wI32(5i32)
        w.wU8(0x71u8) // OP_JZ @5
        w.wI32(-5i32)
        w.wU8(0x7Cu8) // OP_RET @10
        let code = w.take()

        let jmp = InsnDecoder.decode(code, 0)
        @Assert(jmp.size, 5)
        @Assert(InsnDecoder.rel32(jmp, 0), 10) // (0+5) + 5

        let jz = InsnDecoder.decode(code, 5)
        @Assert(jz.op, 0x71u8)
        @Assert(jz.size, 5)
        @Assert(InsnDecoder.rel32(jz, 5), 5) // (5+5) + (-5)

        let ret = InsnDecoder.decode(code, 10)
        @Assert(ret.op, 0x7Cu8)
    }

    /** 负偏移同样以「下一条指令位置」为基准。 */
    @TestCase
    public func rel32HandlesNegativeOffset(): Unit {
        let w = ByteWriter()
        w.wU8(0x70u8)
        w.wI32(-5i32)
        let code = w.take()
        let jmp = InsnDecoder.decode(code, 0)
        @Assert(InsnDecoder.rel32(jmp, 0), 0) // (0+5) + (-5)
    }

    /** RSVD / FORBID 编码在解码阶段被语义拒绝，不进入执行（§10.1「发射即 ERR_NOT_IMPL」）。 */
    @TestCase
    public func reservedAndForbiddenAreRejectedAtDecode(): Unit {
        var rejected = 0
        // 0x08 未分配（RSVD）
        try {
            InsnDecoder.decode([0x08u8], 0)
        } catch (e: JitException) {
            @Assert(e.code, ErrCode.NOT_IMPL)
            rejected = rejected + 1
        }
        // 0xA9 OP_DT_NEW（FORBID，M2 启用）
        try {
            InsnDecoder.decode([0xA9u8], 0)
        } catch (e: JitException) {
            @Assert(e.code, ErrCode.NOT_IMPL)
            rejected = rejected + 1
        }
        // 0xAA OP_DUR_NEW（FORBID）
        try {
            InsnDecoder.decode([0xAAu8], 0)
        } catch (e: JitException) {
            rejected = rejected + 1
        }
        // 0xC0 预留区（RSVD）
        try {
            InsnDecoder.decode([0xC0u8], 0)
        } catch (e: JitException) {
            rejected = rejected + 1
        }
        // 0xFF
        try {
            InsnDecoder.decode([0xFFu8], 0)
        } catch (e: JitException) {
            rejected = rejected + 1
        }
        @Assert(rejected, 5)
        // 对照组：合法编码不被拒绝
        @Assert(InsnDecoder.decode([0x7Cu8], 0).op, 0x7Cu8)
    }

    /** 操作数不足（码流被截断）时解码拒绝，不越界访问。 */
    @TestCase
    public func truncatedOperandStreamIsRejected(): Unit {
        var rejected = 0
        try {
            InsnDecoder.decode([0x12u8, 0x01u8, 0x02u8], 0) // PUSH_I64 缺 6 字节
        } catch (e: JitException) {
            rejected = rejected + 1
        }
        try {
            InsnDecoder.decode([0x20u8], 0) // LOADL 缺 2 字节
        } catch (e: JitException) {
            rejected = rejected + 1
        }
        @Assert(rejected, 2)
    }

    /** 操作数读取越界（下标超出该指令实际操作数长度）时拒绝。 */
    @TestCase
    public func operandIndexOutOfRangeIsRejected(): Unit {
        let insn = InsnDecoder.decode([0x20u8, 0x01u8, 0x00u8], 0)
        @Assert(InsnDecoder.u16(insn, 0), 1u16)
        var rejected = false
        try {
            InsnDecoder.u16(insn, 1)
        } catch (e: JitException) {
            rejected = true
        }
        @Assert(rejected, true)
    }
}
