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
package fountain::f_jit.base

import std.unittest.*
import std.unittest.testmacro.*

/**
 * S1.7 `SourceUnit` 的失败用例（先写红）。
 *
 * 权威 = design-m1 §2.3.5：`raw: Array<UInt8>`（已加载 `.fbc` 容器字节，v0.18.25 起四段：
 * code / const / site / name，以 §11.6 为准）+ `entryFn: UInt32`（**期望**入口函数 id，
 * 须与容器头 `entryFn` 一致，否则加载期拒绝）。
 *
 * 「`entryFn` 与容器头不一致 ⇒ 拒绝」的路径在 S2.15 / S6.9 联测（plan-m1 S1.7 明写），
 * 本步只钉住**构造与字段读回**。
 */
@Test
public class SourceUnit_test {
    /** 构造与字段读回：容器字节与入口函数号原样可取。 */
    @TestCase
    public func fieldsRoundTrip(): Unit {
        let raw = [0x46u8, 0x42u8, 0x43u8, 0x31u8] // "FBC1"
        let unit = SourceUnit(raw, 7u32)
        @Assert(unit.raw.size, 4)
        @Assert(unit.raw[0], 0x46u8)
        @Assert(unit.raw[1], 0x42u8)
        @Assert(unit.raw[2], 0x43u8)
        @Assert(unit.raw[3], 0x31u8)
        @Assert(unit.entryFn, 7u32)
    }

    /** 入口函数号 0 是合法值（函数目录首个 fnId），不可被当成「未设置」。 */
    @TestCase
    public func entryFnZeroIsAValue(): Unit {
        let unit = SourceUnit(Array<UInt8>(), 0u32)
        @Assert(unit.raw.size, 0)
        @Assert(unit.entryFn, 0u32)
    }

    /** 同一份字节可以被多个单元持有（分发入口允许重复装载同一 `.fbc` 的不同入口）。 */
    @TestCase
    public func sameBytesMayBackSeveralUnits(): Unit {
        let raw = [1u8, 2u8, 3u8]
        let a = SourceUnit(raw, 1u32)
        let b = SourceUnit(raw, 2u32)
        @Assert(a.entryFn, 1u32)
        @Assert(b.entryFn, 2u32)
        @Assert(a.raw.size, b.raw.size)
        @Assert(a.raw[2], b.raw[2])
    }
}
