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
 * 分支回填护栏（`optimize-emit-fixup`）。
 *
 * 针对 `A64Emitter` 的两处改动：
 * 1. 标签表从线性扫改哈希索引 ⇒ **首个绑定优先** 的旧语义必须保留；
 * 2. `finishOrNull` / `finish` 从两遍扫改成一遍 ⇒ 回填位域与幂等性必须逐位一致。
 *
 * 这些用例在**改动前**也必须全绿（描述既有语义），否则说明护栏测的是新语义而非等价性。
 */
@Test
public class A64EmitterFixup_test {
    /** 小端 4 字节取字。 */
    private static func wordAt(code: Array<UInt8>, at: Int64): UInt32 {
        UInt32(code[at]) | (UInt32(code[at + 1]) << 8) | (UInt32(code[at + 2]) << 16) |
            (UInt32(code[at + 3]) << 24)
    }

    /** 300 条 `b`、每条目标前有 `k % 4` 个填充字：imm26 必须等于 `1 + k % 4`。 */
    @TestCase
    public func branchesResolveToExactOffsets(): Unit {
        let e = A64Emitter(false)
        var k = 0
        while (k < 300) {
            e.b('L${k}')
            var f = 0
            while (f < k % 4) {
                e.word(0)
                f = f + 1
            }
            e.bind('L${k}')
            k = k + 1
        }
        let code = e.finish()
        var at = 0
        k = 0
        while (k < 300) {
            let w = A64EmitterFixup_test.wordAt(code, at)
            // opcode B = 0x14000000，imm26 在低 26 位
            @Assert(w & 0xFC000000u32, 0x14000000u32)
            @Assert(w & 0x03FFFFFFu32, UInt32(1 + k % 4))
            at = at + 4 + 4 * (k % 4)
            k = k + 1
        }
        @Assert(Int64(code.size), at)
    }

    /** 同名二次 `bind` 不得改变先行目标（旧实现线性扫返回首个匹配）。 */
    @TestCase
    public func firstBindWins(): Unit {
        let e = A64Emitter(false)
        e.bind('X')
        e.word(0)
        e.bind('X')
        @Assert(e.labelOffset('X'), 0)
        @Assert(e.labelOffset('nope'), -1)
    }

    /** `b.cond`（kind 1）与 `cbz`（kind 2）的 imm19 位域必须各自正确，不得串位。 */
    @TestCase
    public func conditionalKindsUseImm19(): Unit {
        let e = A64Emitter(false)
        e.bCond(1, 'T') // at 0
        e.word(0)
        e.word(0)
        e.bind('T') // at 12 ⇒ delta 12 ⇒ imm19 = 3
        e.cbz(9, 'U') // at 12
        e.word(0)
        e.bind('U') // at 20 ⇒ delta 8 ⇒ imm19 = 2
        let code = e.finish()

        let cond = A64EmitterFixup_test.wordAt(code, 0)
        @Assert(cond & 0xFF00001Fu32, 0x54000001u32) // B.cond + cond=1
        @Assert((cond >> 5) & 0x7FFFFu32, 3u32)

        let cbz = A64EmitterFixup_test.wordAt(code, 12)
        @Assert(cbz & 0xFF00001Fu32, 0xB4000009u32) // CBZ X9
        @Assert((cbz >> 5) & 0x7FFFFu32, 2u32)
    }

    /** 回填幂等：`finishOrNull` 之后再 `finish`，字节逐位相同。 */
    @TestCase
    public func finishIsIdempotent(): Unit {
        let e = A64Emitter(false)
        e.b('A')
        e.word(0)
        e.bind('A')
        let first = match (e.finishOrNull()) {
            case Some(b) => b
            case None => Array<UInt8>()
        }
        let second = e.finish()
        @Assert(Int64(first.size), Int64(second.size))
        var i = 0
        while (i < Int64(first.size)) {
            @Assert(first[i], second[i])
            i = i + 1
        }
    }
}
