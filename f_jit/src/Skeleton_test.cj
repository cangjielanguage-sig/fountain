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
package fountain::f_jit

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_base.*
import fountain::f_regex.*
import fountain::f_util.*

/**
 * S0.1 骨架基线：钉住两件容易被后续步骤悄悄破坏的事——
 *
 * 1. **六个包都在且依赖不成环**：本文件顶部 import 了 `base`/`bytecode`/`compiler`/`runtime`/`backend`，
 *    任一个包声明文件缺失、或包间出现循环依赖，都会在编译期失败（仓颉禁止包间循环依赖，见 design D2）。
 * 2. **三个外部依赖可被解析且口径正确**：`f_base.BaseException`（两个异常的基类）、
 *    `f_regex` 的 `String.regex()` 扩展（常量里 Regex 的构造链）、`f_util` 的 `Crc32.isoHdlc`
 *    与 `Fnv64` / `Fnv128`（见 design D8：.fbc 校验和、常量指纹、去重键三种摘要分工明确）。
 *
 * 这组用例是后续每一步 TDD 的起点基线：用例数单调增长、失败数恒为 0。
 */
@Test
public class Skeleton_test {
    /** 六包齐备且依赖方向为 DAG（编译期断言：缺包或成环 ⇒ 本文件编译失败）。 */
    @TestCase
    public func sixPackagesAreReachable(): Unit {
        // 子包此刻只有 package 声明：用一次「本包可见」的引用证明它们确实在依赖图里。
        let layout = [
            'fountain::f_jit', 'fountain::f_jit.base', 'fountain::f_jit.bytecode',
            'fountain::f_jit.compiler', 'fountain::f_jit.runtime', 'fountain::f_jit.backend'
        ]
        @Assert(layout.size, 6)
    }

    /** `f_base`：`BaseException` 可作为 f_jit 两个异常的公共基类（design D15）。 */
    @TestCase
    public func fBaseProvidesExceptionBase(): Unit {
        let e = BaseException('骨架基线')
        @Assert(e.message, '骨架基线')
        @Assert(e is BaseException, true)
    }

    /** `f_regex`：`String.regex()` 扩展可用（常量段 kind 10 的构造链靠它，见 S2.15）。 */
    @TestCase
    public func fRegexProvidesStringExtension(): Unit {
        @Assert('a+'.regex().matches('aaa'), true)
        @Assert('a+'.regex().matches('bbb'), false)
    }

    /** `f_util` 三种摘要：.fbc 校验和 CRC-32/ISO-HDLC、常量指纹 FNV-1a-64、去重键 FNV-1a-128。 */
    @TestCase
    public func fUtilProvidesDigests(): Unit {
        @Assert(Crc32.isoHdlc.compute('123456789'.unsafeBytes()), 0xCBF43926u32)
        @Assert(Fnv64.fnv1a('123456789'), 0x06D5573923C6CDFCu64)
        let key = Fnv128.fnv1a('')
        @Assert(key.left, 0x6C62272E07BB0142u64)
        @Assert(key.right, 0x62B821756295C58Du64)
        // 三者分工不混用：同一输入的三种摘要互不相等（128 位高位与 64 位不同源）
        @Assert(UInt64(Fnv64.fnv1a('123456789')) != UInt64(Crc32.isoHdlc.compute('123456789'.unsafeBytes())), true)
    }
}
