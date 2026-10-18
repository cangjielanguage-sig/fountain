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
 * P5.4 `BackendX86_64` 序言/出口字节序列（§12.3、§4 prologue）。
 *
 * 本机为 aarch64，机器码**不执行**，只做字节级对照；执行证据由 x86_64 CI 补齐
 * （计划约定：非原生架构条件跳过并计入「非原生跳过」）。
 */
@Test
public class X86Frame_test {

    @TestCase
    public func frameSizeIs16Aligned(): Unit {
        // 32（rbp/r15 保存 + 局部基址）+ 8×(nLocals + maxStack) + 8（转瞬实参槽）
        @Assert(BackendX86_64.frameSize(0, 0), 48)
        @Assert(BackendX86_64.frameSize(1, 0), 48)
        @Assert(BackendX86_64.frameSize(1, 1), 64)
        @Assert(BackendX86_64.frameSize(3, 2) % 16, 0)
    }

    /**
     * 转瞬实参槽必须真实存在：`TO_STR`/`IS_TYPE` 等模板在 `maxStack` 之外多压一格，
     * 帧不够时该格会被 helper 栈帧覆盖（见 `frameSize` 注释）。
     */
    @TestCase
    public func frameLeavesRoomForTransientHelperArg(): Unit {
        @Assert(BackendX86_64.frameSize(0, 1) >= 32 + 8 * (0 + 1) + 8, true)
        @Assert(BackendX86_64.frameSize(0, 1) % 16, 0)
    }

    @TestCase
    public func prologueMatchesFrozenSequence(): Unit {
        // fnId=42, nargs=1, nLocals=2, maxStack=1 ⇒ FRAME=64
        let got = BackendX86_64.emitPrologue(42u32, 1, 2, 1)
        let expected = 'F30F1EFA' + // endbr64
            '55' + // push rbp
            '4889E5' + // mov rbp,rsp
            '4C897DF8' + // mov [rbp-8],r15
            '4989FF' + // mov r15,rdi
            '41C74728' + '2A000000' + // mov dword [r15+40],42（ctx.fnId）
            '4881EC' + '40000000' + // sub rsp,64
            '488B4600' + '488985E0FFFFFF' + // arg0 → locals[0] ([rbp-32])
            '48C785D8FFFFFF00000000' // locals[1] 卫生填 0（[rbp-40]）
        @Assert(X86Frame_test.hex(got), expected)
    }

    @TestCase
    public func epilogueMatchesFrozenSequence(): Unit {
        @Assert(X86Frame_test.hex(BackendX86_64.emitEpilogue()),
            '4C8B7DF8' + '4889EC' + '5D' + 'C3')
    }

    private static func hex(bs: Array<UInt8>): String {
        var s = ''
        for (b in bs) {
            s = s + X86Frame_test.h2(b)
        }
        s
    }

    private static func h2(v: UInt8): String {
        X86Frame_test.nib(Int64(v >> 4)) + X86Frame_test.nib(Int64(v & 0x0Fu8))
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
