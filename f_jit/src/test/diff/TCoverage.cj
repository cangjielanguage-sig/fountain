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
    TMapping('T52', ['S6.5', 'S7.6'], 't52TwoFormsSameBehavior', 'M1', true),
    TMapping('T53', ['S4.15', 'S7.6'], 't18ContainerMutation', 'M1', true)
]

/** 范围外编号：T30–T41、T49 归属 M2/M3，不计入本次完成判据。 */
/**
 * M2 的 T 编号（14 个，m2 §10 测试矩阵）：T30–T36、T49、T54、T55、T57–T60。
 *
 * 与 `T_MAP_IN_SCOPE`（M1）同构——`inScope=true` 表示它们是 **M2 的完成判据**；
 * `check_tmap.sh` 对两张表做同一套强校验（用例存在 + 用例体以可执行语句引用标签）。
 * 单独成表而不并入 M1：编号跨里程碑不连续（T37–T41 属 M3），合并会让「谁还没做」失真。
 */
public let T_MAP_M2: Array<TMapping> = [
    // 验签与 Marshal：失败面全 19（site=-1）、一次缓存、禁高阶双拒、同名冲突编译错误
    TMapping('T30', ['Q4.1', 'Q4.2', 'Q5.10', 'Q6.1'], 'callForAcceptsHostClosureArgument',
        'M2', true),
    // CALL_HOST 语义：值型/引用型返回、21 + cause、重入、内层错误不污染外层
    TMapping('T31', ['Q3.5', 'Q4.5', 'Q4.6', 'Q6.2'], 't31CallHostValueAndReference', 'M2', true),
    // 与既有机制交互：flags.bit0 + deopt 禁令、GC 并发、取消边界
    TMapping('T32', ['Q4.5', 'Q6.3'], 't32GcDuringHostCall', 'M2', true),
    // 三引擎差分：确定性宿主闭包 × 全参数类型，结果/错误码/site 逐位一致
    TMapping('T33', ['Q6.3'], 't33HostCallValueIsTripleEqual', 'M2', true),
    // 宿主对象通道：同一对象身份往返、null/型别不符 → 19
    TMapping('T34', ['Q5.9', 'Q6.4'], 't34HostObjectRoundtripKeepsIdentity', 'M2', true),
    // 成员访问：包装模式 + 字段读写 × 全类型、宿主可见性
    TMapping('T35', ['Q5.7', 'Q6.5'], 't35FieldTypeMatrixAndDefense', 'M2', true),
    // 成员访问糖：降级等价、嵌套链、求值顺序、拒绝集全部编译错误
    TMapping('T36', ['Q5.5', 'Q5.6', 'Q6.5'], 't36RejectSetIsCompileErrors', 'M2', true),
    // 逃逸闭包回桥：白名单/提升/共享计数/close、包装器调用 ≡ 直接 CALL_CLOSURE
    TMapping('T49', ['Q5.6', 'Q5.11', 'Q6.6'], 'closureUnboxPromotesGroup', 'M2', true),
    // 字节码侧构造：全参数组合、重载解析、每次求值新实例、窗口账目
    TMapping('T54', ['Q5.3', 'Q6.7'], 'manualRegistrationIsEndToEnd', 'M2', true),
    // 反射自动注册：自动 ≡ 手工、成员全枚举、三类跳过 + diagnostics
    TMapping('T55', ['Q5.2', 'Q5.3', 'Q5.4', 'Q6.7'], 'autoMatchesManualDescriptor', 'M2', true),
    // 源入口实参：含子类实例、同一对象身份、多参混排
    TMapping('T57', ['Q5.9', 'Q5.12', 'Q6.7'], 't57ArgumentFlowsAllChannels', 'M2', true),
    // 槽 14 链内传参：跨 CALL_FUNC 深度 3、链内返回、嵌套捕获快照
    TMapping('T58', ['Q5.12', 'Q6.7'], 'chainDepthThreeKeeps14', 'M2', true),
    // HostClosure 签名含 14：验签、R=14 登记 1 槽、重入
    TMapping('T59', ['Q5.12', 'Q6.7'], 'hostClosureParam14', 'M2', true),
    // 宿主异常专用码：三面 → 21、cause 完整栈、并发失败互不串扰
    TMapping('T60', ['Q4.6', 'Q6.2'], 't60ThreeFacesMapTo21', 'M2', true)
]

public let T_MAP_OUT_OF_SCOPE: Array<TMapping> = [
    TMapping('T37', [], 'M2: 错误通道扩展', 'M2/M3', false),
    TMapping('T38', [], 'M2: 调试与诊断扩展', 'M2/M3', false),
    TMapping('T39', [], 'M3: Any 与动态类型', 'M2/M3', false),
    TMapping('T40', [], 'M3: JSON 互操作', 'M2/M3', false),
    TMapping('T41', [], 'M3: 扩展 helper 族', 'M2/M3', false)
]

/** 全量映射（范围内 + 范围外），供空跑校验遍历。 */
public func allTMappings(): Array<TMapping> {
    let out = ArrayList<TMapping>()
    for (m in T_MAP_IN_SCOPE) {
        out.add(m)
    }
    for (m in T_MAP_M2) {
        out.add(m)
    }
    for (m in T_MAP_OUT_OF_SCOPE) {
        out.add(m)
    }
    out.toArray()
}
