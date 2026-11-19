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
import std.collection.HashMap

/**
 * `X86Depth`（CFG 栈深度）单测：直链、条件汇合一致、汇合不一致、跳转越界。
 *
 * 字节序列均为手工构造（opcode 见规格 §5）：`14` = PUSH_BOOL、`19` = POP、
 * `70` = JMP、`71` = JZ、`7D` = RET_VOID。
 */
@Test
public class X86Depth_test {
    @TestCase
    public func straightLineDepths(): Unit {
        // PUSH_BOOL 1 ; PUSH_BOOL 0 ; POP ; RET_VOID
        let code: Array<UInt8> = [0x14u8, 0x01u8, 0x14u8, 0x00u8, 0x19u8, 0x7Du8]
        let delta = HashMap<Int64, Int64>()
        delta[0] = 1
        delta[2] = 1
        delta[4] = -1
        delta[5] = 0
        match (X86Depth.analyze(code, 0, 6, delta)) {
            case Some(m) =>
                @Assert(X86Depth_test.depthOf(m, 0), 0)
                @Assert(X86Depth_test.depthOf(m, 2), 1)
                @Assert(X86Depth_test.depthOf(m, 4), 2)
                @Assert(X86Depth_test.depthOf(m, 5), 1)
            case None => @Fail('直链不应被拒绝')
        }
    }

    @TestCase
    public func conditionalMergeIsConsistent(): Unit {
        // 0: PUSH_BOOL 1
        // 2: JZ → 10
        // 7: PUSH_BOOL 1
        // 9: POP
        // 10: RET_VOID
        let code: Array<UInt8> = [0x14u8, 0x01u8, 0x71u8, 0x03u8, 0x00u8, 0x00u8, 0x00u8,
            0x14u8, 0x01u8, 0x19u8, 0x7Du8]
        let delta = HashMap<Int64, Int64>()
        delta[0] = 1
        delta[2] = -1
        delta[7] = 1
        delta[9] = -1
        delta[10] = 0
        match (X86Depth.analyze(code, 0, 11, delta)) {
            case Some(m) =>
                // 汇合点：JZ 目标与 POP 之后都应是深度 0
                @Assert(X86Depth_test.depthOf(m, 10), 0)
            case None => @Fail('一致的条件汇合不应被拒绝')
        }
    }

    @TestCase
    public func inconsistentMergeIsRejected(): Unit {
        // 0: PUSH_BOOL 1 ; 2: JZ → 14（汇合深度 0）
        // 7: PUSH_BOOL 1 ; 9: JMP → 14（汇合深度 1）⇒ 不一致
        let code: Array<UInt8> = [0x14u8, 0x01u8, 0x71u8, 0x07u8, 0x00u8, 0x00u8, 0x00u8,
            0x14u8, 0x01u8, 0x70u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8, 0x7Du8]
        let delta = HashMap<Int64, Int64>()
        delta[0] = 1
        delta[2] = -1
        delta[7] = 1
        delta[9] = 0
        delta[14] = 0
        match (X86Depth.analyze(code, 0, 15, delta)) {
            case Some(_) => @Fail('汇合深度不一致时必须拒绝（退回解释器）')
            case None => ()
        }
    }

    @TestCase
    public func jumpOutOfRangeIsRejected(): Unit {
        // 0: JMP +127（越界）
        let code: Array<UInt8> = [0x70u8, 0x7Fu8, 0x00u8, 0x00u8, 0x00u8]
        let delta = HashMap<Int64, Int64>()
        delta[0] = 0
        match (X86Depth.analyze(code, 0, 5, delta)) {
            case Some(_) => @Fail('跳转越界必须拒绝')
            case None => ()
        }
    }

    @TestCase
    public func missingDeltaIsRejected(): Unit {
        // 指令未采集到增量（防御路径）
        let code: Array<UInt8> = [0x14u8, 0x01u8, 0x7Du8]
        let delta = HashMap<Int64, Int64>()
        match (X86Depth.analyze(code, 0, 3, delta)) {
            case Some(_) => @Fail('缺少栈增量必须拒绝')
            case None => ()
        }
    }

    private static func depthOf(m: HashMap<Int64, Int64>, off: Int64): Int64 {
        match (m.get(off)) {
            case Some(v) => v
            case None => -1
        }
    }
}
