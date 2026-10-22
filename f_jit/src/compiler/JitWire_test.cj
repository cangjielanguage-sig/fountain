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

/** S6.9：生产路径可真实建立 JIT 资产（不是只走解释器）。 */
@Test
public class JitWire_test {
    @TestCase
    public func createsExecutableAssets(): Unit {
        let cu = SourceCompiler(PredefinedSnapshot.empty(), DummyDiagnosticsSink()).compile(
            '{ n: Int64 => n * 2 + 1 }')
        let unit = FbcReader.load(cu.raw)
        match (JitExecutor.create(unit, cu.entryFn)) {
            case Some(ex) =>
                ex.release()
                ex.release() // 幂等
                @Assert(true, true)
            case None => @Fail('JIT 资产创建失败（生产路径仍只会退解释器）')
        }
    }
}
