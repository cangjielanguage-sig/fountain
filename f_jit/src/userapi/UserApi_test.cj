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
package fountain::f_jit.userapi

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.*

/** S6.11 用户面冒烟：仅 `import fountain::f_jit.*` 即可完成 编译 → 调用 → 卸载。 */
@Test
public class UserApi_test {
    @TestCase
    public func minimalHostExample(): Unit {
        let c = Compiler(CompileOptions(DummyDiagnosticsSink()))
        let f: JitFunction = c.compile('{ n: Int64 => n + 1 }')
        @Assert(f.call<Int64>([41]), 42)
        @Assert(f.close(0), true)
        @Assert(f.isClosed(), true)
    }

    @TestCase
    public func contractErrorIsVisible(): Unit {
        let f = Compiler(CompileOptions(DummyDiagnosticsSink())).compile('{ => 1 }')
        try {
            let _ = f.call<Int64>([1])
            @Fail('未抛 19')
        } catch (e: JitException) {
            @Assert(e.code, ErrCode.CALL_CONTRACT)
        }
    }
}
