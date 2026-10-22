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
import fountain::f_jit.base.DummyDiagnosticsSink
import fountain::f_jit.base.Version
import fountain::f_jit.bytecode.FbcReader
import fountain::f_jit.bytecode.Fingerprint
import fountain::f_jit.bytecode.LoadedUnit
import fountain::f_jit.runtime.SignatureTable
import fountain::f_jit.test.TCase

/**
 * M3 §13「格式零改动」：特化开关只影响运行期路径，**不改变产物**。
 *
 * 同一份源在 `SignatureTable.enabled` 的两种状态下编译，`.fbc` 逐字节一致；
 * 机器码仍只有 `call H63` 与 `CHECK_ERR`（特化不进入字节码，也不进 `.fbc`）。
 */
@Test
public class SpecializationFmt_test {
    @TestCase
    public func switchDoesNotChangeArtifact(): Unit {
        let src = '{ f: (Int64) -> Int64 => f(1) + f(2) }'
        SignatureTable.enabled = false
        let off = SpecializationFmt_test.bytesOf(src)
        SignatureTable.enabled = true
        let on = SpecializationFmt_test.bytesOf(src)
        let same = Fingerprint.bytecodeKey(off) == Fingerprint.bytecodeKey(on)
        @Assert(same, true)
        @Assert(TCase.hit('T56/format-zero-change', same), true)
        // 机器码层面：CALL_HOST 与其后的 CHECK_ERR 都在，未因开关增删指令
        let unit = SpecializationFmt_test.load(src)
        let dump = CodeDump.dump(LowererM2_test.entryBytes(unit))
        @Assert(dump.contains('CALL_HOST'), true)
        @Assert(dump.contains('CHECK_ERR'), true)
    }

    private static func bytesOf(src: String): Array<UInt8> {
        let sc = SourceCompiler(PredefinedSnapshot.empty(), DummyDiagnosticsSink(),
            verMajor: Version.M3_MAJOR)
        sc.compile(src).raw
    }

    private static func load(src: String): LoadedUnit {
        FbcReader.load(SpecializationFmt_test.bytesOf(src))
    }
}
