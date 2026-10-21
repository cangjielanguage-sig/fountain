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
import fountain::f_jit.base.*

/**
 * S1.11 `base` 包整体可见性检查（先写红）。
 *
 * 权威 = design-m1 §1.2（依赖图 DAG）、D2（共享契约下沉 + 可见性三档）、
 * §7.3（根包再导出清单）与 §8.7（跨包共享声明清单）：
 *
 * - **用户面清单（`public`，由根包 `public import` 再导出）**：`JitException`、
 *   `SourceCompileException`、`SourcePos`、`CallContext`、`SourceUnit`、`JitMode`、`LocalType`、
 *   `TypeToken`、`ErrCode`、`DiagnosticsSink`、`DiagnosticLevel`、`Version`
 *   （design §7.3 再导出清单逐项）。
 * - **`Engine` / `JitValue` 为 `protected`（模块级）**：**不随再导出对外可见**
 *   （design §7.3 括注、§8.7 D3/D6 结案）。
 *
 * **负向口径**：「用户面不可见」是**编译期**断言——本文件位于**本模块内**，`protected`
 * 在模块内必然可见，因此「跨模块不可见」无法用运行期用例表达；plan-m1 S1.11 亦明写该项为
 * **人工核对**（负向用例不可编译）。本文件因此只钉住两件**可测**的事：
 *
 * 1. 全部 `public` 声明从根包可见（再导出清单不缺项，缺任一项本文件即编译失败）；
 * 2. `Engine` / `JitValue` 在模块内可用——证明它们是 `protected` 而非 `internal`
 *    （若为 `internal`，根包将无法引用，本文件编译失败）。
 */
@Test
public class BaseVisibility_test {
    /** 用户面 `public` 声明从根包全部可见（再导出清单不缺项）。 */
    @TestCase
    public func publicDeclarationsAreVisibleFromRootPackage(): Unit {
        // 常量命名空间（design D3：线上码族用「命名空间类 + static const」）
        @Assert(LocalType.I64, 0u16)
        @Assert(TypeToken.LIST, 1u16)
        @Assert(ErrCode.OK, 0)
        @Assert(Version.MAJOR, 1u16)
        @Assert(Version.LATEST, Version.M3_MAJOR)
        // 公共值类型（spec「公共值类型」）
        @Assert(SourcePos(1, 2).line, 1)
        @Assert(JitMode.Auto == JitMode.Auto, true)
        @Assert(CallContext().deadline.isNone(), true)
        @Assert(SourceUnit(Array<UInt8>(), 0u32).entryFn, 0u32)
        // 两个异常（design D15：统一继承 f_base.BaseException）
        @Assert(JitException(ErrCode.NOT_IMPL, -1, 0, None, 'x').code, ErrCode.NOT_IMPL)
        @Assert(SourceCompileException('NotImpl', 0, 1, 1, 'x', 'y').kind, 'NotImpl')
        // 诊断接口：便捷重载默认转发 `Unspecified`，空实现不抛
        let probe = ProbeSink()
        probe.diag(DiagnosticLevel.Warn, '未分类')
        match (probe.lastLevel) {
            case Some(v) => @Assert(v, DiagnosticLevel.Warn)
            case None => @Fail('便捷重载应转发到主签名')
        }
        match (probe.lastCode) {
            case Some(v) => @Assert(v, DiagCode.Unspecified)
            case None => @Fail('便捷重载应以 Unspecified 码转发')
        }
        let dummy: DiagnosticsSink = DummyDiagnosticsSink()
        dummy.diag(DiagnosticLevel.Info, DiagCode.JitFallback, '降级')
    }

    /** `Engine` / `JitValue` 在模块内可见 ⇒ 它们是 `protected`（模块级）而不是 `internal`。 */
    @TestCase
    public func protectedDeclarationsAreVisibleInsideModule(): Unit {
        @Assert(Engine.Interp == Engine.Interp, true)
        @Assert(Engine.Interp == Engine.Jit, false)
        @Assert(JitValue.Int(7) == JitValue.Handle(7), false)
        @Assert(JitValue.`Unit` == JitValue.`Unit`, true)
    }
}

/** 可达性探针：把 `DiagnosticsSink` 两个入口各走一次，供上一条用例断言。 */
private class ProbeSink <: DiagnosticsSink {
    public var lastLevel: ?DiagnosticLevel = None
    public var lastCode: ?DiagCode = None

    public func diag(level: DiagnosticLevel, code: DiagCode, message: String): Unit {
        this.lastLevel = level
        this.lastCode = code
    }
}
