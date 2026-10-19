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
 * S3.20 `Assembler` 的 §7 校验 1–11 拒绝面（plan-m1 §7、design-m1 §4.3.7）。
 *
 * 每个用例只钉一条校验，且用**字节流事实**构造（不经过降低阶段的语法路径）：
 * 降低阶段的合法输入由 `Pipeline_test` 覆盖；本文件专测「产物不合规时汇编期必须拒绝」。
 */
@Test
public class Assembler_test {

    /** 校验 1：`CALL_HELPER` 后没有 `CHECK_ERR` ⇒ 拒绝。 */
    @TestCase
    public func missingCheckErrIsRejected(): Unit {
        let sess = Assembler_test.newSess()
        let b = BytecodeBuilder(0u32, sess.consts)
        b.emitI32(Op.PUSH_I32, 1)
        b.emitU16U8(Op.CALL_HELPER, 1u16, 1u8) // 绕过 callHelper 的自动尾随
        Assembler_test.add(sess, 0u32, 0, LocalType.I64, [LocalType.I64], b.finish())
        @Assert(Assembler_test.assembleKind(sess), DiagKind.CODE_GEN)
    }

    /** 校验 2：`0xA9`（M2 时间构造）在发射阶段即 `NotImpl`。 */
    @TestCase
    public func forbidOpcodeIsNotImpl(): Unit {
        let b = BytecodeBuilder(0u32, ConstRegistry())
        var got = ''
        try {
            b.emit(0xA9u8)
        } catch (e: SourceCompileException) {
            got = e.kind
        }
        @Assert(got, DiagKind.NOT_IMPL)
    }

    /** 校验 2：`0xC0–0xFF` 预留区同样 `NotImpl`。 */
    @TestCase
    public func reservedOpcodeIsNotImpl(): Unit {
        let b = BytecodeBuilder(0u32, ConstRegistry())
        var got = ''
        try {
            b.emit(0xC0u8)
        } catch (e: SourceCompileException) {
            got = e.kind
        }
        @Assert(got, DiagKind.NOT_IMPL)
    }

    /** 校验 4：`PUSH_KH` 索引必须在冻结后的常量表内。 */
    @TestCase
    public func pushKhOutOfRangeIsRejected(): Unit {
        let sess = Assembler_test.newSess()
        let b = BytecodeBuilder(0u32, sess.consts)
        b.emitU16(Op.PUSH_KH, 0u16) // 常量表为空
        Assembler_test.add(sess, 0u32, 0, LocalType.I64, [LocalType.I64], b.finish())
        @Assert(Assembler_test.assembleKind(sess), DiagKind.CODE_GEN)
    }

    /** 校验 5：`LOADL i` 的 `i` 必须小于 `nLocals`。 */
    @TestCase
    public func loadlOutOfRangeIsRejected(): Unit {
        let sess = Assembler_test.newSess()
        let b = BytecodeBuilder(0u32, sess.consts)
        b.emitU16(Op.LOADL, 5u16)
        Assembler_test.add(sess, 0u32, 0, LocalType.I64, [LocalType.I64], b.finish())
        @Assert(Assembler_test.assembleKind(sess), DiagKind.CODE_GEN)
    }

    /** 校验 5：`STOREL i` 的越界同样拒绝。 */
    @TestCase
    public func storelOutOfRangeIsRejected(): Unit {
        let sess = Assembler_test.newSess()
        let b = BytecodeBuilder(0u32, sess.consts)
        b.emitI32(Op.PUSH_I32, 1)
        b.emitU16(Op.STOREL, 3u16)
        Assembler_test.add(sess, 0u32, 0, LocalType.I64, [LocalType.I64], b.finish())
        @Assert(Assembler_test.assembleKind(sess), DiagKind.CODE_GEN)
    }

    /** 校验 7：`CALL_FUNC fid` 必须在该单元的目录内。 */
    @TestCase
    public func callFuncUnknownFidIsRejected(): Unit {
        let sess = Assembler_test.newSess()
        let b = BytecodeBuilder(0u32, sess.consts)
        b.callFunc(9u16, 0u8)
        Assembler_test.add(sess, 0u32, 0, LocalType.I64, [], b.finish())
        @Assert(Assembler_test.assembleKind(sess), DiagKind.CODE_GEN)
    }

    /** 校验 7：`argc` 必须等于目标函数的 `nargs`。 */
    @TestCase
    public func callFuncArgcMismatchIsRejected(): Unit {
        let sess = Assembler_test.newSess()
        let caller = BytecodeBuilder(0u32, sess.consts)
        caller.emitI32(Op.PUSH_I32, 1)
        caller.callFunc(1u16, 1u8)
        Assembler_test.add(sess, 0u32, 0, LocalType.I64, [], caller.finish())
        let callee = BytecodeBuilder(1u32, sess.consts)
        callee.ret()
        Assembler_test.add(sess, 1u32, 2, LocalType.I64, [LocalType.I64, LocalType.I64],
            callee.finish())
        @Assert(Assembler_test.assembleKind(sess), DiagKind.CODE_GEN)
    }

    /** 校验 8：M2 专属指令（`CALL_HOST` / `HW_OPEN` / `HW_CLOSE`）在 M1 一律 `NotImpl`。 */
    @TestCase
    public func m2OnlyOpsAreNotImpl(): Unit {
        let s1 = Assembler_test.newSess()
        let b1 = BytecodeBuilder(0u32, s1.consts)
        let hs = b1.allocSlot(LocalType.HOST_CLOSURE)
        b1.emitU16(Op.LOADL, UInt16(hs))
        b1.emitU8(Op.CALL_HOST, 0u8)
        Assembler_test.add(s1, 0u32, 0, LocalType.I64, [LocalType.HOST_CLOSURE], b1.finish())
        @Assert(Assembler_test.assembleKind(s1), DiagKind.NOT_IMPL)

        let s2 = Assembler_test.newSess()
        let b2 = BytecodeBuilder(0u32, s2.consts)
        b2.emitU16(Op.HW_OPEN, 0u16)
        Assembler_test.add(s2, 0u32, 0, LocalType.I64, [], b2.finish())
        @Assert(Assembler_test.assembleKind(s2), DiagKind.NOT_IMPL)

        let s3 = Assembler_test.newSess()
        let b3 = BytecodeBuilder(0u32, s3.consts)
        b3.emit(Op.HW_CLOSE)
        Assembler_test.add(s3, 0u32, 0, LocalType.I64, [], b3.finish())
        @Assert(Assembler_test.assembleKind(s3), DiagKind.NOT_IMPL)
    }

    /**
     * Q2.4：v2 规则集下 `CALL_HOST argc` 合法，产物为 verMajor 2 / verMinor 0，
     * 且 `[h_fn, a1]` 布局（`LOADL` 句柄 + 1 个实参）通过加载期复核。
     */
    @TestCase
    public func callHostV2AcceptedWithLayout(): Unit {
        let sess = Assembler_test.newSess(verMajor: 2u16)
        let b = BytecodeBuilder(0u32, sess.consts)
        let hs = b.allocSlot(LocalType.HOST_CLOSURE)
        b.emitI32(Op.PUSH_I32, 7)
        b.emitU16(Op.LOADL, UInt16(hs))
        b.emitU8(Op.CALL_HOST, 1u8)
        b.ret()
        Assembler_test.add(sess, 0u32, 0, LocalType.I64, [LocalType.HOST_CLOSURE], b.finish())
        let raw = Assembler(sess).assemble()
        let u = FbcReader.load(raw)
        @Assert(u.header.verMajor, 2u16)
        @Assert(u.header.verMinor, 0u16)
        @Assert(u.rules.verMajor, 2u16)
    }

    /** Q2.4：v1 规则集下 `CALL_HOST` 仍为 `NotImpl`（同字节流，仅规则集不同）。 */
    @TestCase
    public func callHostV1IsNotImpl(): Unit {
        let sess = Assembler_test.newSess()
        let b = BytecodeBuilder(0u32, sess.consts)
        let hs = b.allocSlot(LocalType.HOST_CLOSURE)
        b.emitU16(Op.LOADL, UInt16(hs))
        b.emitU8(Op.CALL_HOST, 0u8)
        b.ret()
        Assembler_test.add(sess, 0u32, 0, LocalType.I64, [LocalType.HOST_CLOSURE], b.finish())
        @Assert(Assembler_test.assembleKind(sess), DiagKind.NOT_IMPL)
    }

    /** Q2.4：`argc` 与栈上实参个数不符（栈下越界）⇒ 汇编期拒绝。 */
    @TestCase
    public func callHostArgcMismatchIsRejected(): Unit {
        let sess = Assembler_test.newSess(verMajor: 2u16)
        // LOADL 0（h_fn）→ CALL_HOST 1（缺一个实参）→ RET
        let w = ByteWriter()
        w.wU8(Op.LOADL)
        w.wU16(0u16)
        w.wU8(Op.CALL_HOST)
        w.wU8(1u8)
        w.wU8(Op.RET)
        Assembler_test.add(sess, 0u32, 0, LocalType.I64, [LocalType.HOST_CLOSURE],
            FuncBody(w.take(), 2, 0u16))
        @Assert(Assembler_test.assembleKind(sess), DiagKind.CODE_GEN)
    }

    /** Q2.4：`CALL_HOST` 前一条压栈的必须是 13 型句柄（栈底非句柄 ⇒ 拒绝）。 */
    @TestCase
    public func callHostNonHandleBaseIsRejected(): Unit {
        let sess = Assembler_test.newSess(verMajor: 2u16)
        // LOADL 0（I64 局部）→ CALL_HOST 0 → RET：句柄位置是值型槽
        let w = ByteWriter()
        w.wU8(Op.LOADL)
        w.wU16(0u16)
        w.wU8(Op.CALL_HOST)
        w.wU8(0u8)
        w.wU8(Op.RET)
        Assembler_test.add(sess, 0u32, 0, LocalType.I64, [LocalType.I64],
            FuncBody(w.take(), 1, 0u16))
        @Assert(Assembler_test.assembleKind(sess), DiagKind.CODE_GEN)
    }

    /** 校验 9：局部类型表的值必须在 0–12（M1 合法集）。 */
    @TestCase
    public func invalidLocalTypeIsRejected(): Unit {
        let sess = Assembler_test.newSess()
        let b = BytecodeBuilder(0u32, sess.consts)
        b.ret()
        Assembler_test.add(sess, 0u32, 0, LocalType.I64, [200u16], b.finish())
        @Assert(Assembler_test.assembleKind(sess), DiagKind.CODE_GEN)
    }

    /** 校验 11：变更型函数禁用 `DEC_TO_I64 mode=1`（deopt 源）。 */
    @TestCase
    public func mutationFunctionRejectsDecToI64Deopt(): Unit {
        let sess = Assembler_test.newSess()
        let b = BytecodeBuilder(0u32, sess.consts)
        b.callHelper(HelperCodec.MUTATION_MIN, 0u8)
        b.emitU8(Op.DEC_TO_I64, 1u8)
        Assembler_test.add(sess, 0u32, 0, LocalType.I64, [], b.finish())
        @Assert(Assembler_test.assembleKind(sess), DiagKind.NOT_IMPL)
    }

    /** 校验 11：变更型函数同样禁用 `TO_I64 mode=1`。 */
    @TestCase
    public func mutationFunctionRejectsToI64Deopt(): Unit {
        let sess = Assembler_test.newSess()
        let b = BytecodeBuilder(0u32, sess.consts)
        b.callHelper(HelperCodec.MUTATION_MIN, 0u8)
        b.emitU8(Op.TO_I64, 1u8)
        Assembler_test.add(sess, 0u32, 0, LocalType.I64, [], b.finish())
        @Assert(Assembler_test.assembleKind(sess), DiagKind.NOT_IMPL)
    }

    // ==================================================================
    // 工具
    // ==================================================================

    private static func newSess(verMajor!: UInt16 = Version.MAJOR): CompileSession {
        CompileSession('', PredefinedSnapshot.empty(), DummyDiagnosticsSink(), verMajor: verMajor)
    }

    private static func add(sess: CompileSession, fid: UInt32, nargs: Int64, ret: UInt16,
        types: Array<UInt16>, body: FuncBody): Unit {
        let lt = LocalTypes(types.size)
        for (i in 0..types.size) {
            lt.set(i, UInt8(types[i]))
        }
        sess.addFunc(LoweredFunc(fid, nargs, ret, lt, body, Array<PendingSite>()))
    }

    private static func assembleKind(sess: CompileSession): String {
        var got = ''
        try {
            let _ = Assembler(sess).assemble()
        } catch (e: SourceCompileException) {
            got = e.kind
        }
        got
    }
}
