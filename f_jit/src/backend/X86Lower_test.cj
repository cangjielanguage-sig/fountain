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
package fountain::f_jit.backend

import std.unittest.*
import std.unittest.testmacro.*

/** S5.5 第一片：0x00–0x3F 的常量/栈/局部 lowering（字节级）。 */
@Test
public class X86Lower_test {

    @TestCase
    public func miscAndStackOps(): Unit {
        @Assert(X86Lower_test.hex(BackendX86_64.emitNop()), '90')
        // push imm64：movabs rax, imm64; push rax
        @Assert(X86Lower_test.hex(BackendX86_64.emitPushI64(42)), '48B82A0000000000000050')
        // push [rsp]（DUP）
        @Assert(X86Lower_test.hex(BackendX86_64.emitDup()), 'FF3424')
        // add rsp,8（POP）
        @Assert(X86Lower_test.hex(BackendX86_64.emitPop()), '4883C408')
        // swap 顶两格
        @Assert(X86Lower_test.hex(BackendX86_64.emitSwap()),
            '488B0424' + '488B4C2408' + '48890C24' + '4889442408')
    }

    @TestCase
    public func localLoadStore(): Unit {
        // LOADL 1 → push [rbp-40]
        @Assert(X86Lower_test.hex(BackendX86_64.emitLoadL(1)), 'FFB5D8FFFFFF')
        // STOREL 1 → pop [rbp-40]
        @Assert(X86Lower_test.hex(BackendX86_64.emitStoreL(1)), '488F85D8FFFFFF')
    }

    @TestCase
    public func controlOps(): Unit {
        // SET_SITE 7 → mov dword [r15+8], 7
        @Assert(X86Lower_test.hex(BackendX86_64.emitSetSite(7)), '41C74F0807000000')
        // CHECK_ERR → cmp qword [r15],0; jne rel32（占位 0，回填由 P5.8）
        @Assert(X86Lower_test.hex(BackendX86_64.emitCheckErr()), '49833F000F8500000000')
        // BAIL 3 → mov dword [r15],3; xor eax,eax; jmp rel32
        @Assert(X86Lower_test.hex(BackendX86_64.emitBail(3)), '49C70703000000' + '31C0' + 'E900000000')
    }

    @TestCase
    public func integerBinaryOps(): Unit {
        let tail = '0F8000000000' + '4889442408' + '4883C408'
        @Assert(X86Lower_test.hex(BackendX86_64.emitIAdd()), '488B442408' + '48030424' + tail)
        @Assert(X86Lower_test.hex(BackendX86_64.emitISub()), '488B442408' + '482B0424' + tail)
        @Assert(X86Lower_test.hex(BackendX86_64.emitIMul()), '488B442408' + '480FAF0424' + tail)
        // IADD_WRAP 不发射 jo
        @Assert(X86Lower_test.hex(BackendX86_64.emitIAddWrap()),
            '488B442408' + '48030424' + '4889442408' + '4883C408')
    }

    @TestCase
    public func branches(): Unit {
        @Assert(X86Lower_test.hex(BackendX86_64.emitJmp()), 'E900000000')
        @Assert(X86Lower_test.hex(BackendX86_64.emitJz()), '0F8400000000')
        @Assert(X86Lower_test.hex(BackendX86_64.emitJnz()), '0F8500000000')
    }

    @TestCase
    public func bitAndCompareOps(): Unit {
        let tail = '4889442408' + '4883C408'
        @Assert(X86Lower_test.hex(BackendX86_64.emitBAnd()), '488B442408' + '48230424' + tail)
        @Assert(X86Lower_test.hex(BackendX86_64.emitBOr()), '488B442408' + '480B0424' + tail)
        @Assert(X86Lower_test.hex(BackendX86_64.emitBXor()), '488B442408' + '48330424' + tail)
        // EQ：cmp rax,[rsp]; sete al; movzx eax,al
        @Assert(X86Lower_test.hex(BackendX86_64.emitCmpEq()),
            '488B442408' + '483B0424' + '0F94C0' + '0FB6C0' + tail)
        @Assert(X86Lower_test.hex(BackendX86_64.emitCmpLt()),
            '488B442408' + '483B0424' + '0F9CC0' + '0FB6C0' + tail)
    }

    @TestCase
    public func shiftOps(): Unit {
        let head = '488B442408' + '488B0C24'
        let tail = '4889442408' + '4883C408'
        @Assert(X86Lower_test.hex(BackendX86_64.emitShl()), head + '48D3E0' + tail)
        @Assert(X86Lower_test.hex(BackendX86_64.emitShr()), head + '48D3F8' + tail)
        @Assert(X86Lower_test.hex(BackendX86_64.emitUShr()), head + '48D3E8' + tail)
    }

    @TestCase
    public func divModOps(): Unit {
        let head = '488B442408' + '488B0C24' + '4885C9' + '0F8400000000' +
            '4883F9FF'
        // IDIV：÷0→1；INT64_MIN/-1→3；商写回
        @Assert(X86Lower_test.hex(BackendX86_64.emitIDiv()),
            head + '0F8500000000' + '48BA0000000000000080' + '4839D0' + '0F8400000000' +
            '4899' + '48F7F9' + '4889442408' + '4883C408')
        // IMOD：÷0→2；除数 -1 直达零分支
        @Assert(X86Lower_test.hex(BackendX86_64.emitIMod()),
            head + '0F8400000000' +
            '4899' + '48F7F9' + '4889542408' + '4883C408' + 'E900000000' +
            '31D2' + '4889542408' + '4883C408')
    }

    @TestCase
    public func unaryAndPick(): Unit {
        @Assert(X86Lower_test.hex(BackendX86_64.emitINeg()),
            '488B0424' + '48F7D8' + '0F8000000000' + '48890424')
        @Assert(X86Lower_test.hex(BackendX86_64.emitBNot()), '488B0424' + '48F7D0' + '48890424')
        // PICK 2 → push qword [rsp+16]
        @Assert(X86Lower_test.hex(BackendX86_64.emitPick(2)), 'FFB424' + '10000000')
    }

    @TestCase
    public func constantVariants(): Unit {
        // PUSH_KH：mov rax,[imm64 常量镜像地址]; push rax
        @Assert(X86Lower_test.hex(BackendX86_64.emitPushKh(0x1000)),
            '48A1' + '0010000000000000' + '50')
        // PUSH_F64：movabs rax,bits; push rax（1.0 = 0x3FF0000000000000）
        @Assert(X86Lower_test.hex(BackendX86_64.emitPushF64(0x3FF0000000000000u64)),
            '48B8' + '000000000000F03F' + '50')
        // PUSH_UNIT：push 0
        @Assert(X86Lower_test.hex(BackendX86_64.emitPushUnit()), '6A00')
    }

    @TestCase
    public func remainingLowOpcodes(): Unit {
        @Assert(X86Lower_test.hex(BackendX86_64.emitPushBool(true)), '6A01')
        @Assert(X86Lower_test.hex(BackendX86_64.emitPushBool(false)), '6A00')
        @Assert(X86Lower_test.hex(BackendX86_64.emitPushNull()), '6A00')
        @Assert(X86Lower_test.hex(BackendX86_64.emitPushI8(7)), '48B8070000000000000050')
        @Assert(X86Lower_test.hex(BackendX86_64.emitPushI32(7)), '48B8070000000000000050')
        @Assert(X86Lower_test.hex(BackendX86_64.emitDup2()),
            '488B0424' + '488B4C2408' + '50' + '51')
        @Assert(X86Lower_test.hex(BackendX86_64.emitPop2()), '4883C410')
        @Assert(X86Lower_test.hex(BackendX86_64.emitLoadL0()), 'FFB5E0FFFFFF')
        @Assert(X86Lower_test.hex(BackendX86_64.emitLoadL3()), 'FFB5C8FFFFFF')
        @Assert(X86Lower_test.hex(BackendX86_64.emitIAddWrap()),
            '488B442408' + '48030424' + '4889442408' + '4883C408')
    }

    @TestCase
    public func integerCompareFamily(): Unit {
        let head = '488B442408' + '483B0424'
        let tail = '0FB6C0' + '4889442408' + '4883C408'
        @Assert(X86Lower_test.hex(BackendX86_64.emitCmpNe()), head + '0F95C0' + tail)
        @Assert(X86Lower_test.hex(BackendX86_64.emitCmpLe()), head + '0F9EC0' + tail)
        @Assert(X86Lower_test.hex(BackendX86_64.emitCmpGt()), head + '0F9FC0' + tail)
        @Assert(X86Lower_test.hex(BackendX86_64.emitCmpGe()), head + '0F9DC0' + tail)
    }

    @TestCase
    public func floatArithmetic(): Unit {
        let nanTail = '660F2EC0' + '0F8B00000000' + '48B8000000000000F87F' + '66480F6EC0'
        let store = 'F20F11442408' + '4883C408'
        // FADD/FMUL：movsd xmm0,[rsp]; op xmm0,[rsp+8]
        @Assert(X86Lower_test.hex(BackendX86_64.emitFAdd()),
            'F20F100424' + 'F20F58442408' + nanTail + store)
        @Assert(X86Lower_test.hex(BackendX86_64.emitFMul()),
            'F20F100424' + 'F20F59442408' + nanTail + store)
        // FSUB/FDIV：movsd xmm0,[rsp+8]; op xmm0,[rsp]
        @Assert(X86Lower_test.hex(BackendX86_64.emitFSub()),
            'F20F10442408' + 'F20F5C0424' + nanTail + store)
        @Assert(X86Lower_test.hex(BackendX86_64.emitFDiv()),
            'F20F10442408' + 'F20F5E0424' + nanTail + store)
    }

    @TestCase
    public func floatUnaryAndMinMax(): Unit {
        let nanTail = '660F2EC0' + '0F8B00000000' + '48B8000000000000F87F' + '66480F6EC0'
        // FNEG/FABS：符号域
        @Assert(X86Lower_test.hex(BackendX86_64.emitFNeg()),
            '48B80000000000000080' + '66480F6EC8' + '660F57C1' + nanTail + 'F20F110424')
        @Assert(X86Lower_test.hex(BackendX86_64.emitFAbs()),
            '48B8FFFFFFFFFFFFFF7F' + '66480F6EC8' + '660F54C1' + nanTail + 'F20F110424')
        @Assert(X86Lower_test.hex(BackendX86_64.emitFSqrt()),
            'F20F510424' + nanTail + 'F20F110424')
        // FMIN：双 NaN 自检 → CANON，否则 minsd
        let mmHead = 'F20F10442408' + 'F20F100C24' +
            '660F2EC0' + '0F8A00000000' + '660F2EC9' + '0F8A00000000'
        let mmTail = 'E900000000' + '48B8000000000000F87F' + '66480F6EC0' +
            'F20F11442408' + '4883C408'
        @Assert(X86Lower_test.hex(BackendX86_64.emitFMin()), mmHead + 'F20F5DC1' + mmTail)
        @Assert(X86Lower_test.hex(BackendX86_64.emitFMax()), mmHead + 'F20F5FC1' + mmTail)
        // FDIV_CHK
        @Assert(X86Lower_test.hex(BackendX86_64.emitFDivChk()),
            '660F57C9' + '660F2E0C24' + '0F8A00000000' + '0F8400000000' +
            X86Lower_test.hex(BackendX86_64.emitFDiv()))
    }

    @TestCase
    public func floatCompareFamily(): Unit {
        let head = 'F20F10442408' + 'F20F100C24' + '660F2EC1' + '0F9BC0'
        let tail = '20D0' + '0FB6C0' + '4889442408' + '4883C408'
        @Assert(X86Lower_test.hex(BackendX86_64.emitCmpEqF()), head + '0F94C2' + tail)
        @Assert(X86Lower_test.hex(BackendX86_64.emitCmpLtF()), head + '0F92C2' + tail)
        @Assert(X86Lower_test.hex(BackendX86_64.emitCmpGtF()), head + '0F97C2' + tail)
        @Assert(X86Lower_test.hex(BackendX86_64.emitCmpLeF()), head + '0F96C2' + tail)
        @Assert(X86Lower_test.hex(BackendX86_64.emitCmpGeF()), head + '0F93C2' + tail)
        @Assert(X86Lower_test.hex(BackendX86_64.emitCmpNeF()), head + '0F95C2' + tail)
    }

    @TestCase
    public func numericConversions(): Unit {
        @Assert(X86Lower_test.hex(BackendX86_64.emitToI64()),
            'F20F100424' + 'F2480F2CC0' + '48890424')
        @Assert(X86Lower_test.hex(BackendX86_64.emitToF64()),
            '488B0424' + 'F2480F2AC0' + 'F20F110424')
    }

    @TestCase
    public func toI64NanGuard(): Unit {
        @Assert(X86Lower_test.hex(BackendX86_64.emitToI64Checked()),
            'F20F100424' + '660F2EC0' + '0F8A00000000' + 'F2480F2CC0' + '48890424')
    }

    @TestCase
    public func toI64RangeGuard(): Unit {
        let head = 'F20F100424' + '660F2EC0' + '0F8A00000000' +
            '48B8000000000000E043' + '66480F6EC8' + '660F2EC1' + '0F8300000000' +
            '48B8000000000000E0C3' + '66480F6EC8' + '660F2EC1' + '0F8200000000'
        @Assert(X86Lower_test.hex(BackendX86_64.emitToI64RangeGuarded()),
            head + 'F2480F2CC0' + '48890424')
    }

    @TestCase
    public func callHelperTemplateA(): Unit {
        let got = BackendX86_64.emitCallHelper(0x1000, 2)
        let expected = '4C89FF' + '488D742408' + 'BA02000000' +
            '48B80010000000000000' + 'FFD0' +
            '4889842408000000' + '4883C408' +
            '49833F000F8500000000'
        @Assert(X86Lower_test.hex(got), expected)
    }

    @TestCase
    public func callFuncTemplateB(): Unit {
        let got = BackendX86_64.emitCallFunc(0x2000, 1u32, 0u32)
        let expected = '48B80020000000000000' + 'FF9008000000' +
            '41C7472800000000' + '49833F000F8500000000'
        @Assert(X86Lower_test.hex(got), expected)
    }

    @TestCase
    public func callClosureTemplateC(): Unit {
        let got = BackendX86_64.emitCallClosure(0x3000, 0x4000, 1, 0u32)
        // 骨架：H55 取 fnId → H57 取表 → 间接 call → 重写 fnId → CHECK_ERR
        @Assert(got.size > 80, true)
        @Assert(got[0], 0x4Cu8)
        @Assert(got[1], 0x89u8)
        @Assert(got[2], 0xFFu8)
        // 两个 helper 绝对地址分别烘焙在偏移 15 / 55
        @Assert(X86Lower_test.imm64(got, 15), 0x3000)
        @Assert(X86Lower_test.imm64(got, 55), 0x4000)
    }

    private static func imm64(bs: Array<UInt8>, off: Int64): Int64 {
        var v: Int64 = 0
        var k = 0
        while (k < 8) {
            v = v | (Int64(bs[off + k]) << (8 * k))
            k = k + 1
        }
        v
    }

    @TestCase
    public func guardNnz(): Unit {
        @Assert(X86Lower_test.hex(BackendX86_64.emitGuardNnz()),
            '488B0424' + '4885C0' + '0F8400000000')
    }

    @TestCase
    public func guardTag(): Unit {
        @Assert(X86Lower_test.hex(BackendX86_64.emitGuard(4)),
            '488B0424' + '4889C1' + '48C1E930' + '4881F904000000' + '0F8500000000')
    }

    @TestCase
    public func isType(): Unit {
        @Assert(X86Lower_test.hex(BackendX86_64.emitIsType(4)),
            '488B0424' + '4889C1' + '48C1E930' + '4881F904000000' +
            '0F94C0' + '0FB6C0' + '48890424')
    }

    @TestCase
    public func loadCap(): Unit {
        let got = BackendX86_64.emitLoadCap(0x5000, 2)
        @Assert(got.size > 30, true)
        // push locals[0]（闭包句柄）
        @Assert(X86Lower_test.hex(got[0..6]), 'FFB5E0FFFFFF')
    }

    @TestCase
    public func abort(): Unit {
        @Assert(X86Lower_test.hex(BackendX86_64.emitAbort()),
            '49C70763000000' + '31C0' + 'E900000000')
    }

    @TestCase
    public func throwOp(): Unit {
        @Assert(X86Lower_test.hex(BackendX86_64.emitThrow()),
            '488B0424' + '418907' + '31C0' + 'E900000000')
    }

    @TestCase
    public func breakpoint(): Unit {
        @Assert(X86Lower_test.hex(BackendX86_64.emitBreakpoint()), '90')
    }

    @TestCase
    public func trap(): Unit {
        @Assert(X86Lower_test.hex(BackendX86_64.emitTrap()), 'CC')
    }

    @TestCase
    public func checkErrNc(): Unit {
        @Assert(BackendX86_64.emitCheckErrNc().size, 0)
    }

    @TestCase
    public func stackGuard(): Unit {
        @Assert(X86Lower_test.hex(BackendX86_64.emitStackGuard(64, 128)),
            '4889E8' + '482D40000000' + '4829E0' + '483D80000000' + '0F8200000000')
    }

    @TestCase
    public func assertOp(): Unit {
        @Assert(X86Lower_test.hex(BackendX86_64.emitAssert(7)),
            '488B0424' + '4883C408' + '4885C0' + '0F8500000000' +
            '49C70707000000' + '31C0' + 'E900000000')
    }

    @TestCase
    public func toStringHelperRoute(): Unit {
        @Assert(X86Lower_test.hex(BackendX86_64.emitToStr(0x6000)),
            X86Lower_test.hex(BackendX86_64.emitCallHelper(0x6000, 1)))
    }

    @TestCase
    public func containerHelperRoutes(): Unit {
        @Assert(X86Lower_test.hex(BackendX86_64.emitListGet(0x7000)),
            X86Lower_test.hex(BackendX86_64.emitCallHelper(0x7000, 2)))
        @Assert(X86Lower_test.hex(BackendX86_64.emitListAdd(0x7001)),
            X86Lower_test.hex(BackendX86_64.emitCallHelper(0x7001, 2)))
        @Assert(X86Lower_test.hex(BackendX86_64.emitMapGet(0x7002)),
            X86Lower_test.hex(BackendX86_64.emitCallHelper(0x7002, 2)))
    }

    @TestCase
    public func regexHelperRoutes(): Unit {
        @Assert(X86Lower_test.hex(BackendX86_64.emitRegexIsMatch(0x8000)),
            X86Lower_test.hex(BackendX86_64.emitCallHelper(0x8000, 2)))
        @Assert(X86Lower_test.hex(BackendX86_64.emitRegexFind(0x8001)),
            X86Lower_test.hex(BackendX86_64.emitCallHelper(0x8001, 2)))
    }

    @TestCase
    public func regexReplaceRoutes(): Unit {
        @Assert(X86Lower_test.hex(BackendX86_64.emitRegexReplaceAll(0x8100)),
            X86Lower_test.hex(BackendX86_64.emitCallHelper(0x8100, 3)))
        @Assert(X86Lower_test.hex(BackendX86_64.emitRegexReplaceNth(0x8101)),
            X86Lower_test.hex(BackendX86_64.emitCallHelper(0x8101, 4)))
        @Assert(X86Lower_test.hex(BackendX86_64.emitRegexReplaceRange(0x8102)),
            X86Lower_test.hex(BackendX86_64.emitCallHelper(0x8102, 6)))
    }

    @TestCase
    public func stringHelperRoutes(): Unit {
        @Assert(X86Lower_test.hex(BackendX86_64.emitStrSub(0x8200)),
            X86Lower_test.hex(BackendX86_64.emitCallHelper(0x8200, 3)))
        @Assert(X86Lower_test.hex(BackendX86_64.emitStrReplace(0x8201)),
            X86Lower_test.hex(BackendX86_64.emitCallHelper(0x8201, 3)))
        @Assert(X86Lower_test.hex(BackendX86_64.emitStrRepeat(0x8202)),
            X86Lower_test.hex(BackendX86_64.emitCallHelper(0x8202, 2)))
    }

    @TestCase
    public func decimalHelperRoutes(): Unit {
        @Assert(X86Lower_test.hex(BackendX86_64.emitDecAdd(0x8300)),
            X86Lower_test.hex(BackendX86_64.emitCallHelper(0x8300, 2)))
        @Assert(X86Lower_test.hex(BackendX86_64.emitDecToI64(0x8301)),
            X86Lower_test.hex(BackendX86_64.emitCallHelper(0x8301, 1)))
    }

    @TestCase
    public func rangeHelperRoutes(): Unit {
        @Assert(X86Lower_test.hex(BackendX86_64.emitRangeNew(0x8400)),
            X86Lower_test.hex(BackendX86_64.emitCallHelper(0x8400, 4)))
        @Assert(X86Lower_test.hex(BackendX86_64.emitRangeContains(0x8401)),
            X86Lower_test.hex(BackendX86_64.emitCallHelper(0x8401, 2)))
    }

    @TestCase
    public func zeroArgHelper(): Unit {
        @Assert(X86Lower_test.hex(BackendX86_64.emitCallHelper0(0x8500)),
            '4C89FF' + '31F6' + '31D2' + '48B80085000000000000' + 'FFD0' + '50' +
            '49833F000F8500000000')
    }

    @TestCase
    public func mutationHelperRoutes(): Unit {
        @Assert(X86Lower_test.hex(BackendX86_64.emitMapPut(0x8600)),
            X86Lower_test.hex(BackendX86_64.emitCallHelper(0x8600, 3)))
        @Assert(X86Lower_test.hex(BackendX86_64.emitListInsert(0x8601)),
            X86Lower_test.hex(BackendX86_64.emitCallHelper(0x8601, 3)))
        @Assert(X86Lower_test.hex(BackendX86_64.emitListSet(0x8602)),
            X86Lower_test.hex(BackendX86_64.emitCallHelper(0x8602, 3)))
        @Assert(X86Lower_test.hex(BackendX86_64.emitListRemove(0x8603)),
            X86Lower_test.hex(BackendX86_64.emitCallHelper(0x8603, 2)))
        @Assert(X86Lower_test.hex(BackendX86_64.emitMapRemove(0x8604)),
            X86Lower_test.hex(BackendX86_64.emitCallHelper(0x8604, 2)))
    }

    @TestCase
    public func mapIterHelperRoutes(): Unit {
        @Assert(X86Lower_test.hex(BackendX86_64.emitMapIterBegin(0x8700)),
            X86Lower_test.hex(BackendX86_64.emitCallHelper(0x8700, 1)))
        @Assert(X86Lower_test.hex(BackendX86_64.emitMapIterStep(0x8701)),
            X86Lower_test.hex(BackendX86_64.emitCallHelper(0x8701, 2)))
    }

    @TestCase
    public func strToRegexRoute(): Unit {
        @Assert(X86Lower_test.hex(BackendX86_64.emitStrToRegex(0x8800)),
            X86Lower_test.hex(BackendX86_64.emitCallHelper(0x8800, 1)))
    }

    @TestCase
    public func castThroughH17(): Unit {
        let head = 'FF3424' + '48B80400000000000000' + '50' + '4C89FF' + '488D742408' +
            'BA02000000' + '48B80090000000000000' + 'FFD0' +
            '4889842408000000' + '4883C408' + '85C0' + '0F8400000000' +
            '58' + 'E900000000' + '58'
        @Assert(X86Lower_test.hex(BackendX86_64.emitCast(0x9000, 4, 0)),
            head + '49C70707000000' + '31C0' + 'E900000000')
        @Assert(X86Lower_test.hex(BackendX86_64.emitCast(0x9000, 4, 1)),
            head + '49C707FFFFFFFF' + '31C0' + 'E900000000')
    }

    @TestCase
    public func integerExtras(): Unit {
        @Assert(X86Lower_test.hex(BackendX86_64.emitIAbs()),
            '58' + '4885C0' + '0F8900000000' + '48F7D8' + '0F8000000000' + '50')
        @Assert(X86Lower_test.hex(BackendX86_64.emitIMin()),
            '488B0C24' + '488B442408' + '4883C408' + '483BC1' + '480F4DC1' + '48890424')
        @Assert(X86Lower_test.hex(BackendX86_64.emitIMax()),
            '488B0C24' + '488B442408' + '4883C408' + '483BC1' + '480F4CC1' + '48890424')
        @Assert(X86Lower_test.hex(BackendX86_64.emitIClz()),
            '488B0C24' + '48C7C040000000' + '4885C9' + '0F8400000000' +
            '480FBDC1' + '48353F000000' + '48890424')
        @Assert(X86Lower_test.hex(BackendX86_64.emitIPopcnt()),
            '488B0424' + '4889C1' + '48D1E9' + '48BA5555555555555555' +
            '4821D1' + '4829C8' + '4889C1' + '48BA3333333333333333' +
            '4821D0' + '4821D1' + '48C1E902' + '4801C8' +
            '4889C1' + '48C1E904' + '4801C8' + '48BA0F0F0F0F0F0F0F0F' +
            '4821D0' + '48BA0101010101010101' + '480FAFC2' + '48C1E838' + '48890424')
    }

    @TestCase
    public func booleanAndTriCompare(): Unit {
        @Assert(X86Lower_test.hex(BackendX86_64.emitNotB()), '4883342401')
        let binTail = '4889442408' + '4883C408'
        @Assert(X86Lower_test.hex(BackendX86_64.emitAndB()), '488B442408' + '48230424' + binTail)
        @Assert(X86Lower_test.hex(BackendX86_64.emitOrB()), '488B442408' + '480B0424' + binTail)
        @Assert(X86Lower_test.hex(BackendX86_64.emitXorB()), '488B442408' + '48330424' + binTail)
        @Assert(X86Lower_test.hex(BackendX86_64.emitCmpI()),
            '488B442408' + '488B0C24' + '4883C408' + '483BC1' +
            '0F9FC2' + '0F9CC0' + '0FB6C0' + '0FB6D2' + '29D0' + '4898' + '48890424')
        @Assert(X86Lower_test.hex(BackendX86_64.emitCmpStr(0x9100)),
            X86Lower_test.hex(BackendX86_64.emitCallHelper(0x9100, 2)))
        @Assert(X86Lower_test.hex(BackendX86_64.emitCmpDec(0x9101)),
            X86Lower_test.hex(BackendX86_64.emitCallHelper(0x9101, 2)))
    }

    @TestCase
    public func controlTransferAndGuards(): Unit {
        @Assert(X86Lower_test.hex(BackendX86_64.emitRet()),
            '488B0424' + 'E900000000')
        @Assert(X86Lower_test.hex(BackendX86_64.emitRetVoid()), '31C0' + 'E900000000')
        // CALL_HELPER_NC：去掉 10 字节 CHECK_ERR
        let nc = BackendX86_64.emitCallHelperNC(0x9200, 1)
        let full = BackendX86_64.emitCallHelper(0x9200, 1)
        @Assert(nc.size, full.size - 10)
        // CALL_HELPER_V：不压结果，收全部实参
        @Assert(X86Lower_test.hex(BackendX86_64.emitCallHelperV(0x9201, 2)),
            '4C89FF' + '488D742408' + 'BA02000000' + '48B80192000000000000' +
            'FFD0' + '4883C410' + '49833F000F8500000000')
        // LOOP_BACK：STACK_GUARD + H22 零参 + jmp
        @Assert(X86Lower_test.hex(BackendX86_64.emitLoopBack(0x9202, 64, 128)),
            X86Lower_test.hex(BackendX86_64.emitStackGuard(64, 128)) +
            '4C89FF' + '31F6' + '31D2' + '48B80292000000000000' + 'FFD0' +
            '49833F000F8500000000' + 'E900000000')
        // GUARD_TYPE mode0：压 tok + H19 双参
        @Assert(X86Lower_test.hex(BackendX86_64.emitGuardType(0x9203, 0x9204, 4, 0)),
            '48B80400000000000000' + '50' +
            X86Lower_test.hex(BackendX86_64.emitCallHelper(0x9204, 2)))
        // GUARD_TYPE mode1：H17 判定 + deopt(-1)
        let gt = X86Lower_test.hex(BackendX86_64.emitGuardType(0x9203, 0x9204, 4, 1))
        @Assert(gt, 'FF3424' + '48B80400000000000000' + '50' + '4C89FF' + '488D742408' +
            'BA02000000' + '48B80392000000000000' + 'FFD0' +
            '4889842408000000' + '4883C408' + '85C0' + '0F8400000000' +
            '58' + 'E900000000' + '58' + '49C707FFFFFFFF' + '31C0' + 'E900000000')
        // TYPE_OF：H18 单参
        @Assert(X86Lower_test.hex(BackendX86_64.emitTypeOf(0x9205)),
            X86Lower_test.hex(BackendX86_64.emitCallHelper(0x9205, 1)))
    }

    private static func hex(bs: Array<UInt8>): String {
        var s = ''
        for (b in bs) {
            s = s + X86Lower_test.nib(Int64(b >> 4)) + X86Lower_test.nib(Int64(b & 0x0Fu8))
        }
        s
    }

    private static func nib(v: Int64): String {
        match (v) {
            case 0 => '0'
            case 1 => '1'
            case 2 => '2'
            case 3 => '3'
            case 4 => '4'
            case 5 => '5'
            case 6 => '6'
            case 7 => '7'
            case 8 => '8'
            case 9 => '9'
            case 10 => 'A'
            case 11 => 'B'
            case 12 => 'C'
            case 13 => 'D'
            case 14 => 'E'
            case _ => 'F'
        }
    }
}
