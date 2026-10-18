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
        @Assert(X86Lower_test.hex(BackendX86_64.emitBail(3)), '41C70703000000' + '31C0' + 'E900000000')
    }

    @TestCase
    public func integerBinaryOps(): Unit {
        let tail = '4889442408' + '4883C408'
        @Assert(X86Lower_test.hex(BackendX86_64.emitIAdd()), '488B442408' + '48030424' + tail)
        @Assert(X86Lower_test.hex(BackendX86_64.emitISub()), '488B442408' + '482B0424' + tail)
        @Assert(X86Lower_test.hex(BackendX86_64.emitIMul()), '488B442408' + '480FAF0424' + tail)
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
            '4883F9FF' + '0F8500000000' + '48BA0000000000000080' + '4839D0' + '0F8500000000'
        let tail = '4899' + '48F7F9'
        @Assert(X86Lower_test.hex(BackendX86_64.emitIDiv()),
            head + tail + '4889442408' + '4883C408')
        @Assert(X86Lower_test.hex(BackendX86_64.emitIMod()),
            head + tail + '4889542408' + '4883C408')
    }

    @TestCase
    public func unaryAndPick(): Unit {
        @Assert(X86Lower_test.hex(BackendX86_64.emitINeg()), '488B0424' + '48F7D8' + '48890424')
        @Assert(X86Lower_test.hex(BackendX86_64.emitBNot()), '488B0424' + '48F7D0' + '48890424')
        // PICK 2 → push qword [rsp+16]
        @Assert(X86Lower_test.hex(BackendX86_64.emitPick(2)), 'FFB424' + '10000000')
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
