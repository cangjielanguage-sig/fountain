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
import fountain::f_jit.base.JitMode
import fountain::f_jit.runtime.HandleTable

/** 纯解释器形态（JitMode.Off）同样在 unload 时归还常量句柄。 */
@Test
public class ConstantReclaimFacade_test {
    @TestCase
    public func offModeReleasesConstantHandles(): Unit {
        HandleTable.resetForTest()
        HandleTable.initialCapacity = 128
        HandleTable.capacityLimit = 1048576
        let base = HandleTable.liveCount()
        var i = 0
        while (i < 10) {
            var o = CompileOptions(DummyDiagnosticsSink())
            o.jit = JitMode.Off
            let f = Compiler(o).compile('{ => "off-' + i.toString() + '" + "!" }')
            let _ = f.call<String>(Array<Any>())
            @Assert(f.close(0), true)
            i = i + 1
        }
        @Assert(HandleTable.liveCount(), base)
    }
}
