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
import fountain::f_jit.base.ErrCode
import fountain::f_jit.base.Version
import fountain::f_jit.test.diff.DiffCase
import fountain::f_jit.test.diff.DiffOutcome
import fountain::f_jit.test.diff.InterpRunner

/**
 * A5.1（P1-7）：常量 Map 的 `Float64` / `Decimal` 键在运行期必须命中。
 *
 * 只测**常量键**路径（`PUSH_KH` 的 Map 常量 → 加载期 `ConstMapKey`），因为运行期
 * `MAP_PUT` 的键与查找键走同一个 `canonKeyOf`，不同路径不会漂移。
 */
@Test
public class A5MapKey_test {

    /** `Map<Float64, Int64>` 的常量键：同值（同位模式）命中、异值报 5。 */
    @TestCase
    public func p1_7_constMapFloatKeysHit(): Unit {
        let hit = A5MapKey_test.run('{ => let m: Map<Float64, Int64> = {1.5f64: 7}\n m[1.5f64] }')
        @Assert(hit.errCode, 0)
        @Assert(hit.result, '7')
        let miss = A5MapKey_test.run('{ => let m: Map<Float64, Int64> = {1.5f64: 7}\n m[2.5f64] }')
        @Assert(miss.errCode, ErrCode.KEY_MISSING)
    }

    /** `Map<Decimal, Int64>`：`1.5` 与 `1.50` 同值同键（规范化去尾零）。 */
    @TestCase
    public func p1_7_constMapDecimalKeysHit(): Unit {
        let hit = A5MapKey_test.run('{ => let m: Map<Decimal, Int64> = {1.5: 7}\n m[1.5] }')
        @Assert(hit.errCode, 0)
        @Assert(hit.result, '7')
        let same = A5MapKey_test.run('{ => let m: Map<Decimal, Int64> = {1.5: 7}\n m[1.50] }')
        @Assert(same.errCode, 0)
        @Assert(same.result, '7')
        let miss = A5MapKey_test.run('{ => let m: Map<Decimal, Int64> = {1.5: 7}\n m[1.6] }')
        @Assert(miss.errCode, ErrCode.KEY_MISSING)
    }

    /** 既有键型（Int64 / String）不受影响。 */
    @TestCase
    public func p1_7_existingKeyKindsUnchanged(): Unit {
        @Assert(A5MapKey_test.run('{ => let m: Map<Int64, Int64> = {1: 7}\n m[1] }').result, '7')
        @Assert(A5MapKey_test.run('{ => let m: Map<String, Int64> = {"a": 7}\n m["a"] }').result,
            '7')
    }

    private static func run(src: String): DiffOutcome {
        let sc = SourceCompiler(PredefinedSnapshot.empty(), DummyDiagnosticsSink(),
            verMajor: Version.M3_MAJOR)
        InterpRunner().run(DiffCase('A5/map-key', sc.compile(src).raw, Array<Any>()))
    }
}
