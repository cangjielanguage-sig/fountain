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
import fountain::f_util.Fnv
import fountain::f_util.FnvVariant
import fountain::f_util.FnvWidth

/**
 * S3.22 兼容 / 回归金样：M1 规格 §8.0 四例的 `.fbc` 产物指纹。
 *
 * 指纹 = `FNV-1a-128(raw)` 的两个 64 位字（最高有效字在前）。任何降低 / 编码改动
 * 使产物字节漂移，这里都会以「预期 vs 实际」直接暴露；升级金样必须**显式改常量**并留痕。
 */
@Test
public class Golden_test {

    @TestCase
    public func factorialSourceFingerprint(): Unit {
        @Assert(Golden_test.fp('{ n: Int64 => if (n <= 1) { 1 } else { n * recursive(n - 1) } }'),
            '17209633820979854088,14618444704151044861')
    }

    @TestCase
    public func interpolationSourceFingerprint(): Unit {
        @Assert(Golden_test.fp('{ x: Int64 => "n=' + Golden_test.DOLLAR + '{x}!" }'),
            '1099484616839464533,2280572132443262047')
    }

    @TestCase
    public func containerMutationSourceFingerprint(): Unit {
        @Assert(Golden_test.fp('{ => let l = [1, 2]\n l[0] = 3\n l[0] }'), '8350298808289603878,5049052680830441467')
    }

    @TestCase
    public func emptyMapSourceFingerprint(): Unit {
        @Assert(Golden_test.fp('{ => let m: Map<String, Int64> = {}\n m["k"] = 1\n m["k"] }'),
            '8878802603600851396,11654796690826219422')
    }

    // ==================================================================

    private static const DOLLAR: String = '$'

    private static func fp(src: String): String {
        let sc = SourceCompiler(PredefinedSnapshot.empty(), DummyDiagnosticsSink())
        let raw = sc.compile(src).raw
        let w = Fnv.hash(FnvWidth.W128, FnvVariant.FNV1A, raw)
        '${w[0]},${w[1]}'
    }
}
