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
package fountain::f_jit.compiler

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.backend.JitExecutor
import fountain::f_jit.base.DummyDiagnosticsSink
import fountain::f_jit.bytecode.FbcReader
import fountain::f_jit.runtime.HandleTable

/** T14/T29：JIT 资产释放必须归还常量句柄，否则不同源码会累积路径 A 槽。 */
@Test
public class ConstantReclaim_test {
    @TestCase
    public func executorReleasesConstantHandles(): Unit {
        HandleTable.resetForTest()
        HandleTable.initialCapacity = 128
        HandleTable.capacityLimit = 1048576
        let base = HandleTable.liveCount()
        var i = 0
        while (i < 20) {
            let src = '{ => "const-' + i.toString() + '" + "!" }'
            let cu = SourceCompiler(PredefinedSnapshot.empty(), DummyDiagnosticsSink()).compile(src)
            let unit = FbcReader.load(cu.raw)
            match (JitExecutor.create(unit, cu.entryFn)) {
                case Some(ex) => ex.release()
                case None => @Fail('JIT 资产创建失败：${src}')
            }
            i = i + 1
        }
        @Assert(HandleTable.liveCount(), base)
    }
}
