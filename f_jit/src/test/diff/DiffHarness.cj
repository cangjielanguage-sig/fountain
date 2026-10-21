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
import fountain::f_base.BaseException

/**
 * S0.2 差分测试 harness：**同一份单元、同一输入，在单次运行内跑完所有可用引擎并对拍四元组**。
 *
 * 四元组 = 结果 / 错误码 / 站点 / 报告文本（design D13、I7）。跨运行比对只作旁证——
 * 进程间状态差异会让判据失真，所以三引擎必须在同一进程内跑完并逐位对照。
 *
 * 用法（后续每步自动接入）：
 * ```
 * let session = DiffSession([InterpRunner(), AArch64Runner(), X86_64Runner()])
 * session.assertTripleEqual(DiffCase('T2/const-1+1', unit, args))
 * ```
 *
 * 非原生架构（本机为 Linux aarch64 ⇒ x86_64）由 `DiffRunner.isAvailable()` 声明不可用，
 * harness 记入「非原生跳过」统计而**不判失败**（证据由 CI 矩阵补齐）。
 */
public class DiffOutcome {
    /** 结果的文本化形态（与 `TO_STR` 同源，见 S4.12）。 */
    public let result: String
    /** 错误码：`0` 成功、`-1` DEOPT、`-2` INTERRUPT、`>0` 见 `ErrCode`。 */
    public let errCode: Int64
    /** 错误站点：无错误时为 `-1`。 */
    public let site: Int64
    /** 诊断/错误报告文本（见 S4.19）。 */
    public let report: String

    public init(result: String, errCode: Int64, site: Int64, report: String) {
        this.result = result
        this.errCode = errCode
        this.site = site
        this.report = report
    }
}

/** 一份待对拍的用例：三引擎共用**同一份** `.fbc` 字节与同一组入参。 */
public class DiffCase {
    /** 用例名（形如 `T2/const-1+1`），出现在失败信息里便于定位。 */
    public let id: String
    /** 同一个编译单元的 raw 字节（三引擎共用，保证「同一字节码」）。 */
    public let unit: Array<Byte>
    /** 入参（宿主侧封送前的原始形态）。 */
    public let args: Array<Any>

    public init(id: String, unit: Array<Byte>, args: Array<Any>) {
        this.id = id
        this.unit = unit
        this.args = args
    }
}

/** 引擎身份。与 `base.Engine`（执行期内部枚举）同名不同层：这是测试层的可见集合。 */
public enum DiffEngine {
    Interp | BackendX86_64 | BackendAArch64
    /** 引擎名，用于跳过/失败信息。 */
    public func name(): String {
        match (this) {
            case Interp => 'Interp'
            case BackendX86_64 => 'BackendX86_64'
            case BackendAArch64 => 'BackendAArch64'
        }
    }
}

/** 一个可执行引擎在差分层的接入契约。 */
public interface DiffRunner {
    /** 本 runner 对应哪个引擎。 */
    func engine(): DiffEngine
    /** 本机是否可给出证据（非原生架构 / 平台不支持 ⇒ false ⇒ 跳过而非失败）。 */
    func isAvailable(): Bool
    /** 跑一个用例并返回四元组。 */
    func run(c: DiffCase): DiffOutcome
}

/** 四元组对拍失败。继承 `BaseException`，与 f_jit 其它异常同源，便于统一捕获。 */
public class DiffMismatchException <: BaseException {
    public init(message: String) {
        super(message)
    }
}

/**
 * 逐位对拍两个四元组，返回**不一致项描述**（空 = 完全一致）。
 *
 * 四个维度分开报，避免「只在结果上不一致」被笼统的 `!=` 掩盖——定位时最想知道的正是
 * 到底是哪一维漂了（结果 / 错误码 / 站点 / 报告文本）。
 */
public func diffFour(a: DiffOutcome, b: DiffOutcome): Array<String> {
    let out = ArrayList<String>()
    if (a.result != b.result) {
        out.add('result: ${a.result} != ${b.result}')
    }
    if (a.errCode != b.errCode) {
        out.add('errCode: ${a.errCode} != ${b.errCode}')
    }
    if (a.site != b.site) {
        out.add('site: ${a.site} != ${b.site}')
    }
    if (a.report != b.report) {
        out.add('report: ${a.report} != ${b.report}')
    }
    out.toArray()
}

/** 三引擎（或更多）对拍：以第一个可用引擎的结果为基准，任一维不一致即抛出。 */
public func assertTripleEqual(caseId: String, outcomes: Array<DiffOutcome>): Unit {
    if (outcomes.size < 2) {
        throw DiffMismatchException('${caseId}: 可用引擎不足 2 个（只有 ${outcomes.size} 个），无法构成差分对拍')
    }
    let base = outcomes[0]
    var all = ArrayList<String>()
    for (i in 1..outcomes.size) {
        let who = outcomes[i]
        for (m in diffFour(base, who)) {
            all.add('${caseId}: 第 ${i} 个引擎与基准不一致 —— ${m}')
        }
    }
    if (!all.isEmpty()) {
        var msg = ''
        for (m in all) {
            msg = '${msg}${m}; '
        }
        throw DiffMismatchException(msg)
    }
}

/**
 * 一次差分运行：按注册顺序跑完所有可用引擎，统计「已跑 / 非原生跳过」。
 *
 * 跳过计数是硬需求——本机最小集是 `Interp × AArch64`，x86_64 的机器码断言必须被明确
 * 标记为「无证据」而不是「通过」，否则回归信号会被污染。
 */
public class DiffSession {
    private let runners: Array<DiffRunner>
    private var ranCount: Int64 = 0
    private var skippedCount: Int64 = 0
    private var skippedNames = ArrayList<String>()

    public init(runners: Array<DiffRunner>) {
        this.runners = runners
    }
    /** 已给出证据的引擎数。 */
    public func ran(): Int64 {
        ranCount
    }
    /** 因非原生 / 平台不支持而跳过的引擎数。 */
    public func skipped(): Int64 {
        skippedCount
    }
    /** 被跳过的引擎名（供报告文本断言）。 */
    public func skippedEngineNames(): Array<String> {
        skippedNames.toArray()
    }
    /** 跑完所有可用引擎，按注册顺序返回四元组（不可用的不出现在结果里）。 */
    public func runAll(c: DiffCase): Array<DiffOutcome> {
        let out = ArrayList<DiffOutcome>()
        for (r in runners) {
            if (r.isAvailable()) {
                out.add(r.run(c))
                ranCount += 1
            } else {
                skippedCount += 1
                skippedNames.add(r.engine().name())
            }
        }
        out.toArray()
    }
    /** 跑一遍并立即对拍四元组；不一致抛 `DiffMismatchException`。 */
    public func assertTripleEqual(c: DiffCase): Unit {
        assertTripleEqual(c.id, runAll(c))
    }
}

/**
 * S0.2 阶段的桩 runner：把「常量 1+1」这类用例的期望四元组直接返回。
 *
 * 真实引擎按硬顺序接入——`Interp`（S4.20，语义基准）先，两个后端（S5.4 / S5.9）后；
 * 在此之前差分层靠桩自证（对拍函数与跳过统计本身必须是对的）。
 */
public class StubRunner <: DiffRunner {
    private let which: DiffEngine
    private let outcome: DiffOutcome
    private let available: Bool

    public init(which: DiffEngine, outcome: DiffOutcome, available!: Bool = true) {
        this.which = which
        this.outcome = outcome
        this.available = available
    }
    public func engine(): DiffEngine {
        which
    }
    public func isAvailable(): Bool {
        available
    }
    public func run(_: DiffCase): DiffOutcome {
        outcome
    }
}

/** 常量成功四元组的便捷构造：结果 + 无错误（`errCode=0`、`site=-1`、空报告）。 */
public func okOutcome(result: String): DiffOutcome {
    DiffOutcome(result, 0, -1, '')
}
