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

/**
 * AArch64 编码器测试：期望字全部来自 `as`/`objdump` 实测。
 */
@Test
public class A64Emitter_test {
    @TestCase
    public func frameSequence(): Unit {
        let e = A64Emitter()
        e.btiC()
        e.prologue()
        e.epilogue()
        // 序言尾 4 条 = FPCR 保存/置 DN；出口头 2 条 = 恢复
        @Assert(A64Emitter_test.hex(e.finish()),
            '5F2403D5' + 'FD7BBFA9' + 'FD030091' + 'B3831FF8' + 'B4031FF8' +
            '09443BD5' + 'A9831EF8' + '290167B2' + '09441BD5' +
            'A9835EF8' + '09441BD5' +
            'B4035FF8' + 'B3835FF8' + 'BF030091' + 'FD7BC1A8' + 'C0035FD6')
    }

    @TestCase
    public func popcntAndTableLoad(): Unit {
        let e = A64Emitter()
        e.fmovDFromX(8, 9) // 2801679E
        e.cntBytes(8, 8) // 0859200E
        e.addvB(8, 8) // 08B9310E
        e.fmovXFromD(9, 8) // 0901669E
        e.ldrReg(10, 12, 9) // ldr x10,[x12,x9,lsl #3] = 8A7969F8
        @Assert(A64Emitter_test.hex(e.finish()), '2801679E' + '0859200E' + '08B9310E' + '0901669E' + '8A7969F8')
    }

    @TestCase
    public func conditionalBranchRangeBoundary(): Unit {
        // 界内：delta/4 = 262143 → Some
        let ok = A64Emitter()
        ok.bCond(A64Cond.EQ, 'far')
        var i = 0
        while (i < 262142) {
            ok.nop()
            i = i + 1
        }
        ok.bind('far')
        @Assert(ok.finishOrNull().isSome(), true)
        // 越界：delta/4 = 262145 → None
        let bad = A64Emitter()
        bad.bCond(A64Cond.EQ, 'far')
        i = 0
        while (i < 262144) {
            bad.nop()
            i = i + 1
        }
        bad.bind('far')
        @Assert(bad.finishOrNull().isNone(), true)
    }

    @TestCase
    public func immediatesAndRegisters(): Unit {
        let e = A64Emitter()
        e.movImm64(0, 0x1234)
        e.movImm64(0, 0x123456789ABCDEF0)
        e.movReg(1, 0)
        @Assert(A64Emitter_test.hex(e.finish()),
            '804682D2' + '00DE9BD2' + '8057B3F2' + '00CFCAF2' + '8046E2F2' + 'E10300AA')
    }

    @TestCase
    public func memoryAndArithmetic(): Unit {
        let e = A64Emitter()
        e.strOff(0, 31, 0)
        e.ldrOff(1, 31, 8)
        e.strOff(0, 29, -32)
        e.ldrOff(1, 29, -32)
        e.addReg(0, 1, 2)
        e.subReg(0, 1, 2)
        e.addsReg(0, 1, 2)
        e.subsReg(0, 1, 2)
        e.mul(0, 1, 2)
        e.sdiv(0, 1, 2)
        e.msub(0, 1, 2, 3)
        e.clz(0, 1)
        @Assert(A64Emitter_test.hex(e.finish()),
            'E00300F9' + 'E10740F9' + 'A0031EF8' + 'A1035EF8' +
            '2000028B' + '200002CB' + '200002AB' + '200002EB' +
            '207C029B' + '200CC29A' + '208C029B' + '2010C0DA')
    }

    @TestCase
    public func compareAndSelect(): Unit {
        let e = A64Emitter()
        e.cmpReg(1, 2)
        e.cmpImm(1, 7)
        e.cset(0, A64Cond.EQ)
        e.cset(0, A64Cond.LT)
        e.cset(0, A64Cond.GE)
        e.csel(0, 1, 2, A64Cond.LT)
        let bs = e.finish()
        @Assert(A64Emitter_test.wordAt(bs, 0), 0xEB02003F)
        @Assert(A64Emitter_test.wordAt(bs, 4), 0xF1001C3F)
        @Assert(A64Emitter_test.wordAt(bs, 8), 0x9A9F17E0)
        @Assert(A64Emitter_test.wordAt(bs, 12), 0x9A9FA7E0)
        @Assert(A64Emitter_test.wordAt(bs, 16), 0x9A9FB7E0)
        @Assert(A64Emitter_test.wordAt(bs, 20), 0x9A82B020)
    }

    @TestCase
    public func floatingPointEncodings(): Unit {
        let e = A64Emitter()
        e.fmovDFromX(0, 0)
        e.fmovXFromD(0, 0)
        e.ldrD(0, 31, 0)
        e.strD(0, 31, 0)
        e.fadd(0, 1, 2)
        e.fsub(0, 1, 2)
        e.fmul(0, 1, 2)
        e.fdiv(0, 1, 2)
        e.fneg(0, 1)
        e.fabs(0, 1)
        e.fsqrt(0, 1)
        e.fmin(0, 1, 2)
        e.fmax(0, 1, 2)
        e.fcmp(1, 2)
        @Assert(A64Emitter_test.hex(e.finish()),
            '0000679E' + '0000669E' + 'E00340FD' + 'E00300FD' +
            '2028621E' + '2038621E' + '2008621E' + '2018621E' +
            '2040611E' + '20C0601E' + '20C0611E' + '2058621E' + '2048621E' + '2020621E')
    }

    @TestCase
    public func roundingAndConversion(): Unit {
        let e = A64Emitter()
        e.frintm(0, 1)
        e.frintp(0, 1)
        e.frintz(0, 1)
        e.frintn(0, 1)
        e.scvtf(0, 0)
        e.fcvtzs(0, 0)
        @Assert(A64Emitter_test.hex(e.finish()),
            '2040651E' + '20C0641E' + '20C0651E' + '2040641E' + '0000629E' + '0000789E')
    }

    @TestCase
    public func branchRelocation(): Unit {
        // 后向：b 在 4，目标 0 → delta -4 → imm26 = 0x3FFFFFF
        let back = A64Emitter()
        back.bind('t')
        back.nop()
        back.b('t')
        @Assert(A64Emitter_test.hex(back.finish()), '1F2003D5' + 'FFFFFF17')
        // 前向：b 在 0，目标 8 → imm26 = 2
        let fwd = A64Emitter()
        fwd.b('x')
        fwd.nop()
        fwd.bind('x')
        @Assert(A64Emitter_test.hex(fwd.finish()), '02000014' + '1F2003D5')
        // b.eq：目标 8，at 0 → imm19 = 2 → 0x54000040
        let cond = A64Emitter()
        cond.bCond(A64Cond.EQ, 'y')
        cond.nop()
        cond.bind('y')
        @Assert(A64Emitter_test.hex(cond.finish()), '40000054' + '1F2003D5')
        // cbnz x0 目标 8 → 0xB5000040
        let cnz = A64Emitter()
        cnz.cbnz(0, 'z')
        cnz.nop()
        cnz.bind('z')
        @Assert(A64Emitter_test.hex(cnz.finish()), '400000B5' + '1F2003D5')
    }

    @TestCase
    public func callAndTrap(): Unit {
        let e = A64Emitter()
        e.blr(10)
        e.brk()
        @Assert(A64Emitter_test.hex(e.finish()), '40013FD6' + '000020D4')
    }

    private static func wordAt(bs: Array<UInt8>, off: Int64): UInt32 {
        var w = 0u32
        var k = 0
        while (k < 4) {
            w = w | (UInt32(bs[off + k]) << (8 * UInt32(k)))
            k = k + 1
        }
        w
    }

    private static func hex(bs: Array<UInt8>): String {
        var s = ''
        for (b in bs) {
            s = s + A64Emitter_test.h2(b)
        }
        s
    }

    private static func h2(v: UInt8): String {
        A64Emitter_test.nib(Int64(v >> 4)) + A64Emitter_test.nib(Int64(v & 0x0Fu8))
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
