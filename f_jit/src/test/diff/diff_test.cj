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
package fountain::f_jit.test.diff

import std.collection.ArrayList
import std.collection.HashSet
import std.unittest.*
import std.unittest.testmacro.*

/**
 * S0.2 / S0.3 的自证：harness 自身与 T 映射表本身的正确性。
 *
 * 差分层只承载**跨引擎一致性断言**，不放单层语义断言（design D14）——所以这里验的是
 * 「对拍函数与跳过统计是否可靠」，而不是任何指令语义。真实引擎按硬顺序接入后，
 * 同一套 harness 直接复用（Interp 先，S5.4 / S5.9 的两个后端后）。
 */
@Test
public class Diff_test {
    /** 「常量 1+1」：三引擎给出完全相同的四元组 ⇒ 对拍通过（harness 自证）。 */
    @TestCase
    public func harnessSelfProvesWithConstOnePlusOne(): Unit {
        let c = DiffCase('T2/const-1+1', [], [])
        let session = DiffSession([
            StubRunner(DiffEngine.Interp, okOutcome('2')),
            StubRunner(DiffEngine.BackendX86_64, okOutcome('2')),
            StubRunner(DiffEngine.BackendAArch64, okOutcome('2'))
        ])
        session.assertTripleEqual(c)
        @Assert(session.ran(), 3)
        @Assert(session.skipped(), 0)
    }

    /** 四元组逐位对拍：四个维度各自都能被单独抓出来（不互相掩盖）。 */
    @TestCase
    public func diffFourCatchesEachDimension(): Unit {
        let base = DiffOutcome('2', 0, -1, '')
        @Assert(diffFour(base, DiffOutcome('2', 0, -1, '')).size, 0)
        @Assert(diffFour(base, DiffOutcome('3', 0, -1, '')).size, 1)
        @Assert(diffFour(base, DiffOutcome('2', 10, -1, '')).size, 1)
        @Assert(diffFour(base, DiffOutcome('2', 0, 7, '')).size, 1)
        @Assert(diffFour(base, DiffOutcome('2', 0, -1, 'boom')).size, 1)
        @Assert(diffFour(base, DiffOutcome('3', 10, 7, 'boom')).size, 4)
    }

    /** 任一维不一致 ⇒ `assertTripleEqual` 抛出，且失败信息点出用例与维度。 */
    @TestCase
    public func assertTripleEqualThrowsOnMismatch(): Unit {
        let outcomes = [okOutcome('2'), okOutcome('2'), DiffOutcome('2', 10, -1, '')]
        var caught = ''
        try {
            assertTripleEqual('T2/const-1+1', outcomes)
        } catch (e: DiffMismatchException) {
            caught = e.message
        }
        @Assert(caught.contains('T2/const-1+1'), true)
        @Assert(caught.contains('errCode'), true)
    }

    /** 可用引擎不足 2 个 ⇒ 无法构成对拍，必须报错而不是「通过」。 */
    @TestCase
    public func assertTripleEqualRejectsSingleEngine(): Unit {
        var caught = ''
        try {
            assertTripleEqual('T2/only-one', [okOutcome('2')])
        } catch (e: DiffMismatchException) {
            caught = e.message
        }
        @Assert(caught.contains('无法构成差分对拍'), true)
    }

    /** 非原生架构 ⇒ 跳过并计入「非原生跳过」，**不判失败**（本机 x86_64 就是这条路径）。 */
    @TestCase
    public func unavailableEngineIsSkippedNotFailed(): Unit {
        let c = DiffCase('T2/const-1+1', [], [])
        let session = DiffSession([
            StubRunner(DiffEngine.Interp, okOutcome('2')),
            StubRunner(DiffEngine.BackendX86_64, okOutcome('2'), available: false),
            StubRunner(DiffEngine.BackendAArch64, okOutcome('2'))
        ])
        session.assertTripleEqual(c)
        @Assert(session.ran(), 2)
        @Assert(session.skipped(), 1)
        @Assert(session.skippedEngineNames(), ['BackendX86_64'])
    }

    /** 引擎名可用于跳过/失败报告文本。 */
    @TestCase
    public func engineNamesAreStable(): Unit {
        @Assert(DiffEngine.Interp.name(), 'Interp')
        @Assert(DiffEngine.BackendX86_64.name(), 'BackendX86_64')
        @Assert(DiffEngine.BackendAArch64.name(), 'BackendAArch64')
    }

    /** T 映射空跑校验：每项都能定位到具体步骤 + 用例名，无悬空项。 */
    @TestCase
    public func tMappingHasNoDanglingEntries(): Unit {
        let seen = HashSet<String>()
        for (m in T_MAP_IN_SCOPE) {
            if (m.steps.isEmpty()) {
                @Fail('${m.id} 没有落点步骤（悬空项）')
            }
            if (m.caseName.isEmpty()) {
                @Fail('${m.id} 没有用例名（悬空项）')
            }
            if (m.owner != 'M1' || !m.inScope) {
                @Fail('${m.id} 归属标注错误：owner=${m.owner}, inScope=${m.inScope}')
            }
            if (!seen.add(m.id)) {
                @Fail('${m.id} 重复登记')
            }
        }
    }

    /** T 映射覆盖 M1 §13.2 全集：T1–T29、T42–T48、T50–T53，共 40 项。 */
    @TestCase
    public func tMappingCoversFullM1Scope(): Unit {
        @Assert(T_MAP_IN_SCOPE.size, 40)
        let expected = [
            'T1', 'T2', 'T3', 'T4', 'T5', 'T6', 'T7', 'T8', 'T9', 'T10',
            'T11', 'T12', 'T13', 'T14', 'T15', 'T16', 'T17', 'T18', 'T19', 'T20',
            'T21', 'T22', 'T23', 'T24', 'T25', 'T26', 'T27', 'T28', 'T29',
            'T42', 'T43', 'T44', 'T45', 'T46', 'T47', 'T48',
            'T50', 'T51', 'T52', 'T53'
        ]
        let got = ArrayList<String>()
        for (m in T_MAP_IN_SCOPE) {
            got.add(m.id)
        }
        @Assert(got.toArray(), expected)
    }

    /** 范围外编号（T30–T41、T49）明确标注归属 M2/M3，且不计入本次完成判据。 */
    @TestCase
    public func outOfScopeIdsAreAttributedToLaterMilestones(): Unit {
        @Assert(T_MAP_OUT_OF_SCOPE.size, 13)
        let seen = HashSet<String>()
        for (m in T_MAP_OUT_OF_SCOPE) {
            @Assert(m.inScope, false)
            @Assert(m.owner, 'M2/M3')
            if (m.caseName.isEmpty()) {
                @Fail('${m.id} 缺少归属说明')
            }
            if (!seen.add(m.id)) {
                @Fail('${m.id} 重复登记')
            }
        }
        let expected = [
            'T30', 'T31', 'T32', 'T33', 'T34', 'T35', 'T36', 'T37', 'T38',
            'T39', 'T40', 'T41', 'T49'
        ]
        let got = ArrayList<String>()
        for (m in T_MAP_OUT_OF_SCOPE) {
            got.add(m.id)
        }
        @Assert(got.toArray(), expected)
    }

    /** 全量表 = 范围内 + 范围外，合计 53 项。 */
    @TestCase
    public func allTMappingsIsTheUnion(): Unit {
        @Assert(allTMappings().size, 53)
    }
}
