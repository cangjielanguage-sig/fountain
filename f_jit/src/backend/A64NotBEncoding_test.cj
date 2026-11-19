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
import fountain::f_jit.base.LocalType
import fountain::f_jit.bytecode.ConstRegistry
import fountain::f_jit.bytecode.FbcHeader
import fountain::f_jit.bytecode.FbcRuleRegistry
import fountain::f_jit.bytecode.FbcRuleSet
import fountain::f_jit.bytecode.FuncDir
import fountain::f_jit.bytecode.FuncEntry
import fountain::f_jit.bytecode.LoadedUnit
import fountain::f_jit.bytecode.LocalTypes
import fountain::f_jit.bytecode.NameTable
import fountain::f_jit.bytecode.SiteTable

/**
 * `NOT_B` 的 AArch64 编码断言（fix-jit-unary-not §4.3 / N1.2）。
 *
 * 这是一层**结构断言**（design §4.5）：只用于把失败定位到「后端原语」这一层，
 * 不单独作为验收判据——验收看 `UnaryNotDiff_test` 的语义用例。
 *
 * 红态是本文件的断言红（报到错误字 `0xD2400009`），不是编译红。
 */
@Test
public class A64NotBEncoding_test {
    /** `LDUR/STR` 锚点：`ldr x9,[x20]` —— `NOT_B` 序列的第一条。 */
    private static const LDR_X9_X20: UInt32 = 0xF9400289
    /** `str x9,[x20]` —— `NOT_B` 序列的最后一条。 */
    private static const STR_X9_X20: UInt32 = 0xF9000289
    /** 正确编码：`EOR X9, X9, #1`（`Rn = Rd = 9`）。 */
    private static const EOR_X9_X9_1: UInt32 = 0xD2400129
    /** 缺陷编码：`EOR X9, X0, #1`（`Rn = 0`，即根因）。 */
    private static const EOR_X9_X0_1: UInt32 = 0xD2400009

    /**
     * `PUSH_BOOL 1; NOT_B; RET` 的最小单元 → `A64Compiler.compileFunction` 的产物里
     * 定位 `0x5E` 的三条字：`ldr x9,[x20]` / `eor ?` / `str x9,[x20]`。
     *
     * 断言 `Rn == Rd == 9`，并断言产物中不出现 `0xD2400009`。
     */
    @TestCase
    public func notBLowersToEorWithRnAndRdEqualNine(): Unit {
        let unit = A64NotBEncoding_test.minimalUnit()
        let code = match (A64Compiler.compileFunction(unit, unit.dir.at(0))) {
            case Some(b) => b
            case None =>
                @Fail('PUSH_BOOL; NOT_B; RET 的最小单元编译失败（不应降级）')
                return
        }
        let words = A64NotBEncoding_test.wordsOf(code)
        let at = A64NotBEncoding_test.findTriplet(words)
        if (at < 0) {
            @Fail('产物里找不到 ldr x9,[x20] + str x9,[x20] 的 NOT_B 三字序列')
            return
        }
        // 断言按 hex 文本比对：失败信息里直接读到 `0xD2400009 != 0xD2400129`
        @Assert(A64NotBEncoding_test.hex32(words[at]),
            A64NotBEncoding_test.hex32(A64NotBEncoding_test.LDR_X9_X20))
        @Assert(A64NotBEncoding_test.hex32(words[at + 1]),
            A64NotBEncoding_test.hex32(A64NotBEncoding_test.EOR_X9_X9_1))
        @Assert(A64NotBEncoding_test.hex32(words[at + 2]),
            A64NotBEncoding_test.hex32(A64NotBEncoding_test.STR_X9_X20))
        // 位域解码：Rn = bits 9-5、Rd = bits 4-0，二者都必须是 x9
        @Assert((words[at + 1] >> 5) & 0x1Fu32, 9u32)
        @Assert(words[at + 1] & 0x1Fu32, 9u32)
        // 缺陷字在产物中不得出现
        @Assert(A64NotBEncoding_test.countOf(words, A64NotBEncoding_test.EOR_X9_X0_1), 0)
    }

    /**
     * `A64Emitter.eorImm1` 的编码（N2.1）：`Rn`/`Rd` 各自落在 `9–5` / `4–0` 位域。
     *
     * `eorImm1(9, 9)` → `29 01 40 D2`；`eorImm1(9, 0)` → `09 00 40 D2`。
     * 后一条是**反向固定位域**：若把 `Rn`/`Rd` 又写反，两条会互换成对方的值。
     */
    @TestCase
    public func eorImm1PutsRnAndRdInTheirOwnFields(): Unit {
        @Assert(A64NotBEncoding_test.hexBytes(A64NotBEncoding_test.emitEor(9, 9)), '290140D2')
        @Assert(A64NotBEncoding_test.hexBytes(A64NotBEncoding_test.emitEor(9, 0)), '090040D2')
    }

    private static func emitEor(rd: Int64, rn: Int64): Array<UInt8> {
        let e = A64Emitter()
        e.eorImm1(rd, rn)
        e.finish()
    }

    /**
     * 手工装配的最小单元：函数体恰好 `PUSH_BOOL 1 (0x14 0x01) / NOT_B (0x5E) / RET (0x7C)`。
     *
     * 不在测试里走 `SourceCompiler`：`fountain::f_jit.compiler` 依赖本包，
     * 反向往返会构成包级循环依赖。
     */
    private static func minimalUnit(): LoadedUnit {
        let code: Array<UInt8> = [0x14u8, 0x01u8, 0x5Eu8, 0x7Cu8]
        let dir = FuncDir()
        dir.add(FuncEntry(0u32, 0u32, UInt32(code.size), 0u32, 0u16, 0u16, 1u16,
            LocalType.BOOL, 0u16))
        let rules = FbcRuleRegistry.V3
        let header = FbcHeader(0x46424331u32, rules.verMajor, 0u16, 0u32, 0u32,
            UInt32(code.size), 0u32, 0u32, 0u32, 0u32, 0u32)
        LoadedUnit(header, code, ConstRegistry(), SiteTable(), NameTable(), dir,
            [LocalTypes(0)], rules)
    }

    private static func wordsOf(code: Array<UInt8>): Array<UInt32> {
        let n = code.size / 4
        let out = Array<UInt32>(n, repeat: 0u32)
        var i = 0
        while (i < n) {
            let at = i * 4
            out[i] = UInt32(code[at]) | (UInt32(code[at + 1]) << 8) |
                (UInt32(code[at + 2]) << 16) | (UInt32(code[at + 3]) << 24)
            i = i + 1
        }
        out
    }

    /** 找 `ldr x9,[x20]` 且其后第二条为 `str x9,[x20]` 的下标；找不到返回 -1。 */
    private static func findTriplet(words: Array<UInt32>): Int64 {
        var i = 0
        while (i + 2 < words.size) {
            if (words[i] == A64NotBEncoding_test.LDR_X9_X20 &&
                words[i + 2] == A64NotBEncoding_test.STR_X9_X20) {
                return i
            }
            i = i + 1
        }
        -1
    }

    private static func countOf(words: Array<UInt32>, w: UInt32): Int64 {
        var hits = 0
        for (x in words) {
            if (x == w) {
                hits = hits + 1
            }
        }
        hits
    }

    /** 32 位字 → `0xXXXXXXXX`（大写十六进制），供断言消息直接可读。 */
    private static func hex32(v: UInt32): String {
        let digits = ['0', '1', '2', '3', '4', '5', '6', '7',
            '8', '9', 'A', 'B', 'C', 'D', 'E', 'F']
        var s = '0x'
        var shift = 28
        while (shift >= 0) {
            let d = Int64((v >> UInt32(shift)) & 0xFu32)
            s = s + digits[d]
            shift = shift - 4
        }
        s
    }

    /** 字节序列 → 大写十六进制（与 `A64Emitter_test.hex` 同口径）。 */
    private static func hexBytes(bs: Array<UInt8>): String {
        let digits = ['0', '1', '2', '3', '4', '5', '6', '7',
            '8', '9', 'A', 'B', 'C', 'D', 'E', 'F']
        var s = ''
        for (b in bs) {
            s = s + digits[Int64(b >> 4u8)] + digits[Int64(b & 0x0Fu8)]
        }
        s
    }
}
