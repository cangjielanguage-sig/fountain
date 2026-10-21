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
import fountain::f_jit.base.Version

/**
 * X1：编译选项的版本口径。
 *
 * 旧实现由 `CompilePipeline` 硬编码 `M3_MAJOR`——选项里根本没有版本字段，
 * 调用方既不能选择、也不能在缓存层区分。本用例锁死「缺省即最新」与「显式可设」。
 */
@Test
public class CompileOptions_test {

    /** 缺省：版本取最新，严格浮点**开启**（÷0 当场失败）。 */
    @TestCase
    public func optionsDefaultToLatestVersion(): Unit {
        let o = CompileOptions(DummyDiagnosticsSink())
        @Assert(o.verMajor, Version.LATEST)
        @Assert(Version.LATEST, Version.M3_MAJOR)
        @Assert(o.strictFp, true)
    }

    /** 显式设置可读回（选项是可变配置，不是只读常量）。 */
    @TestCase
    public func versionIsSettable(): Unit {
        let o = CompileOptions(DummyDiagnosticsSink())
        o.verMajor = Version.M2_MAJOR
        @Assert(o.verMajor, Version.M2_MAJOR)
        o.strictFp = true
        @Assert(o.strictFp, true)
    }
}
