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
package fountain::f_jit.compiler

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.base.*
import fountain::f_jit.bytecode.*

/**
 * S3.19 `BytecodeBuilder` 的失败用例（design-m1 §4.3.6、§7 校验 1/3/9/11）。
 *
 * 判据（先写红）：
 *
 * - ① 标签回填目标正确（`emitRel` 相对**下一条指令**）；
 * - ② `CALL_HELPER` 自动尾随 `CHECK_ERR`（`_NC` 不尾随、`_V` 尾随且不压值）；
 * - ③ `setSite` 只在可能失败点前发射、`SET_SITE` 立即数 = 自身偏移；
 * - ④ `finish` 的 `maxStack` / `flags`（含变更型调用 → `flags.bit0`）；
 * - ⑤ 栈深 tracking 的一致性（分支汇合影片必须同深、下越界即拒、未解析标签即拒）。
 *
 * **断言走 `CodeDump` 的文本**（design §4.3 实施注意：`*_test.cj` 不直接解析递归 AST 枚举；
 * 本文件虽不碰 AST，但统一走同一 Lib 侧 dump 面，避免将来有人把解码逻辑抄进测试文件）。
 */
@Test
public class Builder_test {

    // ==================================================================
    // 发射族
    // ==================================================================

    /** 无操作数指令：1 字节，`maxStack` 按其栈效应累加。 */
    @TestCase
    public func emitBytesAreWellFormed(): Unit {
        let b = Builder_test.newBuilder()
        b.emit(Op.NOP)
        @Assert(b.size, 1)
        @Assert(CodeDump.ops(b.bytes()), 'NOP')

        // u8 操作数
        let b2 = Builder_test.newBuilder()
        b2.emitU8(Op.PUSH_BOOL, 1u8)
        @Assert(CodeDump.hex(b2.bytes()), '1401')

        // u16 操作数（显式小端）
        let b3 = Builder_test.newBuilder()
        b3.emitU16(Op.LOADL, 0x0102u16)
        @Assert(CodeDump.hex(b3.bytes()), '200201')

        // i32 / i64 操作数
        let b4 = Builder_test.newBuilder()
        b4.emitI32(Op.PUSH_I32, -2)
        @Assert(CodeDump.hex(b4.bytes()), '11feffffff')
        let b5 = Builder_test.newBuilder()
        b5.emitI64(Op.PUSH_I64, 1)
        @Assert(CodeDump.hex(b5.bytes()), '120100000000000000')
    }

    /** 压缩形式之外的整数压栈：最短形式由降低阶段选择，本步只验字节编排。 */
    @TestCase
    public func stackTrackingComputesMaxStack(): Unit {
        let b = Builder_test.newBuilder()
        b.emitI32(Op.PUSH_I32, 1)
        b.emitI32(Op.PUSH_I32, 2)
        b.emit(Op.IADD)
        @Assert(b.maxStackSeen(), 2)
        let body = b.finish()
        @Assert(body.maxStack, 2)
        @Assert(CodeDump.ops(body.code), 'PUSH_I32 PUSH_I32 IADD')
    }

    /** 栈下越界 ⇒ 编译期拒绝（不得产出「深度为负」的非法单元）。 */
    @TestCase
    public func stackUnderflowIsRejected(): Unit {
        let b = Builder_test.newBuilder()
        var got = ''
        try {
            b.emit(Op.POP)
        } catch (e: SourceCompileException) {
            got = e.kind
        }
        @Assert(got, DiagKind.CODE_GEN)
    }

    // ==================================================================
    // 标签与回填
    // ==================================================================

    /** 前向跳转：回填目标 = `place` 处的偏移（`rel32` 相对**下一条指令**）。 */
    @TestCase
    public func forwardLabelResolvesToPlacedOffset(): Unit {
        let b = Builder_test.newBuilder()
        let end = b.newLabel()
        b.emitI32(Op.PUSH_I32, 1)
        b.emitRel(Op.JMP, end)
        @Assert(b.size, 10)
        b.place(end)
        b.ret()
        @Assert(CodeDump.dump(b.bytes()), '0000: PUSH_I32 1\n0005: JMP ->0010\n0010: RET')
    }

    /** `emitRel` 的编码口径：target = 本条偏移 + 条长 + offset（与 `InsnDecoder.rel32` 同款）。 */
    @TestCase
    public func relOperandIsRelativeToNextInstruction(): Unit {
        let b = Builder_test.newBuilder()
        let header = b.newLabel()
        b.place(header)
        b.emit(Op.NOP)
        b.emitRel(Op.LOOP_BACK, header)
        // 0000 NOP / 0001 LOOP_BACK(len 5) → 目标 0000 ⇒ offset = -6
        @Assert(relRawAt(b.bytes(), 1), -6)
    }

    /** 分支汇合：两条路径到同一标签时** operand 栈深必须相等**（§7 校验 3 的前端侧兑现）。 */
    @TestCase
    public func branchConvergenceRequiresEqualDepth(): Unit {
        let b = Builder_test.newBuilder()
        let otherwise = b.newLabel()
        let end = b.newLabel()
        b.emitI32(Op.PUSH_I32, 0)   // 条件值
        b.emitRel(Op.JZ, otherwise) // 跳转点深度 0
        b.emitI32(Op.PUSH_I32, 1)   // 值分支：深度 1
        b.emitRel(Op.JMP, end)      // 汇合时深度 1
        b.place(otherwise)
        b.emitI32(Op.PUSH_I32, 2)   // 另一条路径：深度 2 → 不等
        b.emitI32(Op.PUSH_I32, 3)
        var got = ''
        try {
            b.place(end)
        } catch (e: SourceCompileException) {
            got = e.kind
        }
        @Assert(got, DiagKind.CODE_GEN)
    }

    /** 未放置的标签在 `finish` 时必须是硬错误（不得静默填 0 造出跳到函数头的码）。 */
    @TestCase
    public func unresolvedLabelIsRejected(): Unit {
        let b = Builder_test.newBuilder()
        let ghost = b.newLabel()
        b.emitRel(Op.JMP, ghost)
        var got = ''
        try {
            b.finish()
        } catch (e: SourceCompileException) {
            got = e.kind
        }
        @Assert(got, DiagKind.CODE_GEN)
    }

    // ==================================================================
    // helper 调用与自动错误检查
    // ==================================================================

    /** `CALL_HELPER` 自动尾随 `CHECK_ERR`（I3），且 `CHECK_ERR` 跳向保单块。 */
    @TestCase
    public func callHelperTrailsCheckErr(): Unit {
        let b = Builder_test.newBuilder()
        b.emitI32(Op.PUSH_I32, 1)
        b.callHelper((1u16), 1u8)
        let body = b.finish()
        @Assert(CodeDump.ops(body.code), 'PUSH_I32 CALL_HELPER CHECK_ERR')
        // CHECK_ERR 的目标 = 收敛块（函数体末尾），错误槽已写 ⇒ fail-fast
        @Assert(relTargetAt(body.code, 9), 14)
    }

    /** `_NC` 变体**不**尾随检查（仅永不失败的纯 helper 允许）。 */
    @TestCase
    public func callHelperNoCheckDoesNotTrailCheckErr(): Unit {
        let b = Builder_test.newBuilder()
        b.emitI32(Op.PUSH_I32, 1)
        b.callHelperNoCheck((10u16), 1u8)
        @Assert(CodeDump.ops(b.bytes()), 'PUSH_I32 CALL_HELPER_NC')
    }

    /** `_V` 变体：返回值 Unit ⇒ **不压栈**，但仍自动尾随 `CHECK_ERR`。 */
    @TestCase
    public func callHelperVoidPushesNothingButStillChecked(): Unit {
        let b = Builder_test.newBuilder()
        b.emitI32(Op.PUSH_I32, 1)
        b.callHelperVoid(HelperCodec.MUTATION_MIN, 1u8)
        @Assert(CodeDump.ops(b.bytes()), 'PUSH_I32 CALL_HELPER_V CHECK_ERR')
        @Assert(b.depthNow(), 0)
    }

    // ==================================================================
    // 站点
    // ==================================================================

    /**
     * `setSite` 只信任调用点在「可能失败指令之前」的位置：`SET_SITE` 的立即数 = **自身偏移**
     * （汇编期再加上该函数在 code 段的 `codeOff`，§11.6）。
     */
    @TestCase
    public func setSiteImmediateIsOwnOffset(): Unit {
        let b = Builder_test.newBuilder()
        b.emit(Op.NOP)
        b.setSite(SourcePos(3, 7))
        b.emitI32(Op.PUSH_I32, 1)
        b.callHelper((1u16), 1u8)
        let body = b.finish()
        @Assert(CodeDump.dump(body.code), '0000: NOP\n0001: SET_SITE 1\n0006: PUSH_I32 1\n0011: CALL_HELPER 1,1\n0015: CHECK_ERR ->0020')
        @Assert(b.pendingSites().size, 1)
        @Assert(b.pendingSites()[0].relOff, 1)
        @Assert(b.pendingSites()[0].pos, SourcePos(3, 7))
    }

    // ==================================================================
    // finish：maxStack / flags
    // ==================================================================

    /** `flags.bit0`：函数体出现**变更型 helper** ⇒ 置位（§11.7、§7 校验 11）。 */
    @TestCase
    public func mutationHelperSetsFlagsBit0(): Unit {
        let b = Builder_test.newBuilder()
        b.emitI32(Op.PUSH_I32, 1)
        b.emitI32(Op.PUSH_I32, 2)
        b.callHelper(HelperCodec.MUTATION_MIN, 2u8)
        b.emit(Op.POP)
        @Assert(b.finish().flags & FuncFlags.MUTATION, FuncFlags.MUTATION)
        // `CALL_CLOSURE` 同样置位（§8.6「被调闭包体静态不可知」）
        let b2 = Builder_test.newBuilder()
        b2.emitI32(Op.PUSH_I32, 1)
        b2.emitU8(Op.CALL_CLOSURE, 0u8)
        @Assert(b2.finish().flags & FuncFlags.MUTATION, FuncFlags.MUTATION)
        // 纯读 helper 不置位
        let b3 = Builder_test.newBuilder()
        b3.emitI32(Op.PUSH_I32, 1)
        b3.callHelper((1u16), 1u8)
        @Assert(b3.finish().flags & FuncFlags.MUTATION, 0u16)
        // 单元私有 user helper 亦置位（§8.4「预定义 helper / user helper」）
        let b4 = Builder_test.newBuilder()
        b4.callHelper(HelperCodec.USER_BASE, 0u8)
        @Assert(b4.finish().flags & FuncFlags.MUTATION, FuncFlags.MUTATION)
    }

    /** `bail(code, pos)`：站点 + 无条件错误码（§5 失败块的字节码形态）。 */
    @TestCase
    public func bailEmitsSiteAndAbort(): Unit {
        let b = Builder_test.newBuilder()
        b.bail(19, SourcePos(2, 4))
        @Assert(CodeDump.dump(b.bytes()), '0000: SET_SITE 0\n0005: ABORT 19')
    }

    /** 局部槽分配：槽序连续且类型可回读（降低阶段的 `STOREL/LOADL` 约定）。 */
    @TestCase
    public func slotAllocationIsStable(): Unit {
        let b = Builder_test.newBuilder()
        @Assert(b.allocSlot(LocalType.I64), 0)
        @Assert(b.allocSlot(LocalType.STRING), 1)
        @Assert(b.slotCount(), 2)
        @Assert(b.slotType(1), LocalType.STRING)
    }

    // ==================================================================
    // 工具
    // ==================================================================

    private static func newBuilder(): BytecodeBuilder {
        BytecodeBuilder(0u32, ConstRegistry())
    }

    private static func relRawAt(code: Array<UInt8>, off: Int64): Int64 {
        var v: Int64 = 0
        for (i in 0..4) {
            v = v | (Int64(code[off + 1 + i]) << (8 * i))
        }
        // i32 符号还原
        if (v >= 0x80000000) {
            v - 0x100000000
        } else {
            v
        }
    }

    /** `rel32` 的绝对目标（口径同 `InsnDecoder.rel32`）。 */
    private static func relTargetAt(code: Array<UInt8>, off: Int64): Int64 {
        off + 5 + relRawAt(code, off)
    }
}
