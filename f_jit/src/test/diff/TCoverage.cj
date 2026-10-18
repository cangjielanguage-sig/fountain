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

/**
 * S0.3「T 编号 → 落点用例」映射表（数据来源：`f_jit/doc/plan-m1.md` §3，覆盖 M1 §13.2 全集）。
 *
 * 每一条都要能定位到**具体步骤 + 具体用例方法**：`steps` 是该编号的主要落点步骤，
 * `caseName` 是承载它的**真实测试方法名**（`f_jit/scripts/check_tmap.sh` 在 `*_test.cj`
 * 中逐个解析，改名或写错即判悬空）。空步骤或空用例名同样由 `diff_test` 空跑校验拦住。
 *
 * 范围外编号（T30–T41、T49）归属 M2/M3：`owner` 标注为 `M2/M3`、`inScope=false`，
 * **不计入本次完成判据**，但必须留在表里——否则「哪些编号还没做」这件事会随文档漂移而丢失。
 */
public class TMapping {
    /** 编号，形如 `T1`。 */
    public let id: String
    /** 主要落点步骤（plan-m1 §3）。 */
    public let steps: Array<String>
    /** 承载该编号的测试方法名（须能在 `*_test.cj` 中解析到）。 */
    public let caseName: String
    /** 归属里程碑：`M1`（本次范围）或 `M2/M3`（后续）。 */
    public let owner: String
    /** 是否计入本次完成判据。 */
    public let inScope: Bool

    public init(id: String, steps: Array<String>, caseName: String, owner: String, inScope: Bool) {
        this.id = id
        this.steps = steps
        this.caseName = caseName
        this.owner = owner
        this.inScope = inScope
    }
}

/** 本次范围内的编号：T1–T29、T42–T48、T50–T53。 */
public let T_MAP_IN_SCOPE: Array<TMapping> = [
    TMapping('T1', ['S2.13', 'S6.9', 'S7.1'], 't1GoldenUnitLoad', 'M1', true),
    TMapping('T2', ['S0.2', 'S5.11', 'S7.1'], 't2TripleEqualCore', 'M1', true),
    TMapping('T3', ['S2.2', 'S7.1'], 'littleEndianRoundTrip', 'M1', true),
    TMapping('T4', ['S5.1', 'S7.1'], 'pageAlignment', 'M1', true),
    TMapping('T5', ['S5.14', 'S7.1'], 'allFunctionEntriesStartWithBtiC', 'M1', true),
    TMapping('T6', ['S4.21', 'S6.4', 'S7.2'], 't6ErrorConsistency', 'M1', true),
    TMapping('T7', ['S5.3', 'S5.12', 'S7.2'], 'nonLinuxFallsBackWithDiagnostic', 'M1', true),
    TMapping('T8', ['S4.12', 'S7.2'], 't8NanTextualization', 'M1', true),
    TMapping('T9', ['S2.11', 'S2.14', 'S5.12', 'S7.2'], 'rejectUnknownFlagsAndNeedJit', 'M1', true),
    TMapping('T10', ['S4.3', 'S4.5', 'S7.3'], 't10WindowGrowth', 'M1', true),
    TMapping('T11', ['S4.12', 'S7.3'], 't11ToStrGolden', 'M1', true),
    TMapping('T12', ['S3.10', 'S3.11', 'S4.11', 'S7.3'], 't12MixedNumeric', 'M1', true),
    TMapping('T13', ['S3.9', 'S4.1', 'S7.3'], 't13TypedLocals', 'M1', true),
    TMapping('T14', ['S4.2', 'S4.5', 'S6.3', 'S7.3'], 'handlePinnedAndCleaned', 'M1', true),
    TMapping('T15', ['S6.3', 'S6.5', 'S6.6', 'S7.3'], 'returnsT', 'M1', true),
    TMapping('T16', ['S6.7', 'S7.4'], 'claimIsExclusive', 'M1', true),
    TMapping('T17', ['S6.7', 'S7.4'], 'concurrentPipelineRunsOnce', 'M1', true),
    TMapping('T18', ['S4.15', 'S7.4'], 't18ContainerMutation', 'M1', true),
    TMapping('T19', ['S4.22', 'S7.4'], 't19Iteration', 'M1', true),
    TMapping('T20', ['S2.8', 'S2.15', 'S4.16', 'S7.4'], 't20RegexInterop', 'M1', true),
    TMapping('T21', ['S3.14', 'S7.4'], 't21MultiAssign', 'M1', true),
    TMapping('T22', ['S3.7', 'S6.8', 'S7.5'], 't22SourceEntryRecursive', 'M1', true),
    TMapping('T23', ['S6.2', 'S6.8', 'S7.5'], 'registerQueryUnregister', 'M1', true),
    TMapping('T24', ['S3.5', 'S3.15', 'S7.5'], 't24Closures', 'M1', true),
    TMapping('T25', ['S3.15', 'S4.17', 'S7.5'], 'closureHelpers', 'M1', true),
    TMapping('T26', ['S3.6', 'S3.18', 'S4.16', 'S7.5'], 't20RegexInterop', 'M1', true),
    TMapping('T27', ['S4.1', 'S6.3', 'S7.5'], 'createFreePairIsBalanced', 'M1', true),
    TMapping('T28', ['S3.16', 'S7.5'], 't28TailRecursion', 'M1', true),
    TMapping('T29', ['S6.10', 'S7.5'], 'unloadThenCallIsRejected', 'M1', true),
    TMapping('T42', ['S3.3', 'S3.4', 'S7.6'], 't42StringForms', 'M1', true),
    TMapping('T43', ['S3.18', 'S4.13', 'S7.6'], 't43RepeatAndDateDiff', 'M1', true),
    TMapping('T44', ['S3.13', 'S7.6'], 't44IfDualUsage', 'M1', true),
    TMapping('T45', ['S3.13', 'S4.6', 'S7.6'], 't19Iteration', 'M1', true),
    TMapping('T46', ['S4.16', 'S7.6'], 't20RegexInterop', 'M1', true),
    TMapping('T47', ['S3.16', 'S7.6'], 't28TailRecursion', 'M1', true),
    TMapping('T48', ['S3.17', 'S7.6'], 't48EmptyContainers', 'M1', true),
    TMapping('T50', ['S1.9', 'S4.19', 'S7.6'], 't50SourcePosDiagnostics', 'M1', true),
    TMapping('T51', ['S3.17', 'S7.6'], 't48EmptyContainers', 'M1', true),
    TMapping('T52', ['S6.5', 'S7.6'], 't2TripleEqualCore', 'M1', true),
    TMapping('T53', ['S4.15', 'S7.6'], 't18ContainerMutation', 'M1', true)
]

/** 范围外编号：T30–T41、T49 归属 M2/M3，不计入本次完成判据。 */
public let T_MAP_OUT_OF_SCOPE: Array<TMapping> = [
    TMapping('T30', [], 'M2: 宿主闭包与宿主对象（LocalType 13/14）', 'M2/M3', false),
    TMapping('T31', [], 'M2: 宿主闭包调用通道', 'M2/M3', false),
    TMapping('T32', [], 'M2: 宿主对象访问', 'M2/M3', false),
    TMapping('T33', [], 'M2: 闭包与宿主互操作', 'M2/M3', false),
    TMapping('T34', [], 'M2: 逃逸与生命周期', 'M2/M3', false),
    TMapping('T35', [], 'M2: 注册契约扩展', 'M2/M3', false),
    TMapping('T36', [], 'M2: 类型系统扩展', 'M2/M3', false),
    TMapping('T37', [], 'M2: 错误通道扩展', 'M2/M3', false),
    TMapping('T38', [], 'M2: 调试与诊断扩展', 'M2/M3', false),
    TMapping('T39', [], 'M3: Any 与动态类型', 'M2/M3', false),
    TMapping('T40', [], 'M3: JSON 互操作', 'M2/M3', false),
    TMapping('T41', [], 'M3: 扩展 helper 族', 'M2/M3', false),
    TMapping('T49', [], 'M2/M3: 预留验收项', 'M2/M3', false)
]

/** 全量映射（范围内 + 范围外），供空跑校验遍历。 */
public func allTMappings(): Array<TMapping> {
    let out = ArrayList<TMapping>()
    for (m in T_MAP_IN_SCOPE) {
        out.add(m)
    }
    for (m in T_MAP_OUT_OF_SCOPE) {
        out.add(m)
    }
    out.toArray()
}
