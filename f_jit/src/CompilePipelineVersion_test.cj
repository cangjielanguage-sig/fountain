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
import fountain::f_jit.base.DummyDiagnosticsSink
import fountain::f_jit.base.SourceCompileException
import fountain::f_jit.base.Version

/**
 * X1：版本选项贯穿编译管线与缓存键。
 *
 * 关键断言是**缓存不串版本**：同一份源码先用最新版本编译成功，再用 M2 编译必须仍然失败。
 * 若缓存键不含版本，第二次会直接命中第一次的产物而不报错——这正是「硬编码版本」的隐性后果。
 */
@Test
public class CompilePipelineVersion_test {

    private static const ANY_SRC: String = '{ => let a: Any = 7\n (a as Int64) + 1 }'

    /** M2 版本编不了 `Any`（LocalType 15 不在 0–14 合法集内）。 */
    @TestCase
    public func m2VersionRejectsAnySource(): Unit {
        let opts = CompileOptions(DummyDiagnosticsSink())
        opts.verMajor = Version.M2_MAJOR
        let c = Compiler(opts)
        var threw = false
        try {
            let _ = c.compile(CompilePipelineVersion_test.ANY_SRC)
        } catch (e: SourceCompileException) {
            threw = true
        }
        @Assert(threw, true)
    }

    /** 缺省（最新版本）编得了 `Any`，且运行结果正确。 */
    @TestCase
    public func latestVersionAcceptsAnySource(): Unit {
        let c = Compiler(CompileOptions(DummyDiagnosticsSink()))
        let f = c.compile(CompilePipelineVersion_test.ANY_SRC)
        @Assert(f.call<Int64>(Array<Any>()), 8)
    }

    /**
     * 缓存键含版本：最新版本先编译（产物入缓存）后，M2 仍必须报错。
     *
     * 若键不含版本，M2 会命中缓存直接返回，`threw` 恒 false。
     */
    @TestCase
    public func versionIsPartOfCacheKey(): Unit {
        let c3 = Compiler(CompileOptions(DummyDiagnosticsSink()))
        @Assert(c3.compile(CompilePipelineVersion_test.ANY_SRC).call<Int64>(Array<Any>()), 8)

        let opts2 = CompileOptions(DummyDiagnosticsSink())
        opts2.verMajor = Version.M2_MAJOR
        let c2 = Compiler(opts2)
        var threw = false
        try {
            let _ = c2.compile(CompilePipelineVersion_test.ANY_SRC)
        } catch (e: SourceCompileException) {
            threw = true
        }
        @Assert(threw, true)
    }
}
