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
import fountain::f_jit.base.*

/**
 * S3.8 名字解析 + S3.9 明确赋值与空安全的失败用例（design-m1 §4.3.3 / §4.3.4、§7 校验 10）。
 *
 * 判据：① 解析顺序 `recursive` → 注册表 → 未注册错误；② 未注册诊断含**名字 / 位置 / 已注册清单**；
 * ③ 读未赋值、循环出口、分支汇合、`PUSH_NULL` 直存句柄型槽、捕获未赋值**全部在编译期被拒**。
 */
@Test
public class Semantics_test {

    // ==================================================================
    // S3.8 名字解析
    // ==================================================================

    /** `recursive` 优先于注册表（即便注册了同名函数，自递归关键字也先命中）。 */
    @TestCase
    public func recursiveWinsOverRegistry(): Unit {
        let snap = Semantics_test.snapshot(['double'], [[LocalType.I64]], [LocalType.I64])
        let r = NameResolver(snap, '{ x: Int64 => recursive(x) }')
        let got = r.resolve('recursive', SourcePos(1, 15))
        match (got) {
            case ResolvedCall.Recursive => @Assert(true, true)
            case ResolvedCall.UserHelper(_) => @Fail('recursive 应优先解析为自递归')
        }
    }

    /** 命中注册表 → `UserHelper(slot)`（slot = 注册序）。 */
    @TestCase
    public func registeredNameResolvesToUserHelperSlot(): Unit {
        let snap = Semantics_test.snapshot(['double', 'triple'], [[LocalType.I64], [LocalType.I64]],
            [LocalType.I64, LocalType.I64])
        let r = NameResolver(snap, '{ x: Int64 => triple(x) }')
        match (r.resolve('triple', SourcePos(1, 15))) {
            case ResolvedCall.UserHelper(slot) => @Assert(slot, 1u16)
            case ResolvedCall.Recursive => @Fail('应解析为 user helper')
        }
        // hid = slot + 0x0100（§8.4）
        match (r.resolve('triple', SourcePos(1, 15))) {
            case ResolvedCall.UserHelper(slot) => @Assert(slot + 0x0100u16, 0x0101u16)
            case ResolvedCall.Recursive => @Fail('应解析为 user helper')
        }
    }

    /** 未注册 → `UnregisteredFunction`，消息含**名字 / 行号 / 已注册清单**。 */
    @TestCase
    public func unregisteredFunctionReportsNameAndRegistryList(): Unit {
        let snap = Semantics_test.snapshot(['double'], [[LocalType.I64]], [LocalType.I64])
        let r = NameResolver(snap, '{ x: Int64 => unknown(x) }')
        let e = Semantics_test.captureResolveError(r, 'unknown')
        @Assert(e.kind, DiagKind.UNREGISTERED_FUNCTION)
        @Assert(e.line, 1)
        @Assert(e.hint.contains('unknown'), true)
        @Assert(e.hint.contains('[double]'), true)
        @Assert(e.lineText, '{ x: Int64 => unknown(x) }')
    }

    /** 非调用位置的未定义标识符 → `UndefinedIdentifier`。 */
    @TestCase
    public func undefinedIdentifierInValuePosition(): Unit {
        let snap = PredefinedSnapshot.empty()
        let r = NameResolver(snap, '{ x: Int64 => y }')
        var got = ''
        try {
            r.requireValue('y', SourcePos(1, 15), false)
        } catch (err: SourceCompileException) {
            got = err.kind
        }
        @Assert(got, DiagKind.UNDEFINED_IDENTIFIER)
        // 局部名不报错
        r.requireValue('y', SourcePos(1, 15), true)
    }

    // ==================================================================
    // S3.9 明确赋值
    // ==================================================================

    /** 先写后读通过；参数槽天然已赋值。 */
    @TestCase
    public func writeBeforeReadIsAccepted(): Unit {
        @Assert(Semantics_test.daOf('{ n: Int64 =>\nlet a = n + 1\na }'), true)
    }

    /** 读未赋值 → 编译期拒绝（**不得推迟为运行期错误**）。 */
    @TestCase
    public func readBeforeWriteIsRejected(): Unit {
        let e = Semantics_test.expectDaError('{ =>\nvar x = 1\nlet y = z\nx }')
        @Assert(e.kind, DiagKind.NOT_ASSIGNED)
        @Assert(e.line, 3)
    }

    /** **循环出口不视为已赋值**（回边不动点；§5「明确赋值分析与回边」）。 */
    @TestCase
    public func loopExitDoesNotCountAsAssigned(): Unit {
        let e = Semantics_test.expectDaError('{ c: Bool =>\nvar x: Int64\nwhile (c) { x = 1 }\nx }')
        @Assert(e.kind, DiagKind.NOT_ASSIGNED)
        @Assert(e.line, 4)
        // for-in 同样（隐藏计数局部是另一回事，绑定变量不向出口传播）
        let e2 = Semantics_test.expectDaError('{ xs: List<Int64> =>\nvar last: Int64\nfor (i in xs) { last = i }\nlast }')
        @Assert(e2.kind, DiagKind.NOT_ASSIGNED)
    }

    /** 分支汇合取交集：全部分支都赋值才算出口已赋值。 */
    @TestCase
    public func branchMergeRequiresEveryBranchToAssign(): Unit {
        @Assert(Semantics_test.daOf('{ c: Bool =>\nvar x: Int64\nif (c) { x = 1 } else { x = 2 }\nx }'), true)
        let e = Semantics_test.expectDaError('{ c: Bool =>\nvar x: Int64\nif (c) { x = 1 }\nx }')
        @Assert(e.kind, DiagKind.NOT_ASSIGNED)
    }

    /** `PUSH_NULL` 不得直存句柄型槽（§3.1 空安全 / §7 校验 10）。 */
    @TestCase
    public func nullCannotBeStoredIntoHandleSlot(): Unit {
        let e = Semantics_test.expectDaError('{ =>\nvar s: String = null\ns }')
        @Assert(e.kind, DiagKind.NOT_ASSIGNED)
        @Assert(e.line, 2)
        // 值型槽（Int64）也不是合法落点，但空安全只针对句柄型；此处仅验证句柄型被拒
    }

    /** 闭包捕获：创建点未赋值的变量被捕获 → 编译错误（§8.5「捕获 = 创建时刻的值快照」）。 */
    @TestCase
    public func capturingAnUnassignedVariableIsRejected(): Unit {
        let e = Semantics_test.expectDaError('{ =>\nvar a: Int64\nlet f = { => a }\n1 }')
        @Assert(e.kind, DiagKind.NOT_ASSIGNED)
        // 先赋值再捕获合法
        @Assert(Semantics_test.daOf('{ =>\nvar a: Int64 = 1\nlet f = { => a }\n1 }'), true)
    }

    /** 多重赋值：RHS 先全部求值（读取），之后 LHS 才视为已赋值。 */
    @TestCase
    public func multiAssignReadsBeforeWriting(): Unit {
        @Assert(Semantics_test.daOf('{ =>\nvar a: Int64 = 1\nvar b: Int64 = 2\n(a, b) = (b, a)\na }'), true)
        let e = Semantics_test.expectDaError('{ =>\nvar a: Int64 = 1\n(a, _) = (q, a)\na }')
        @Assert(e.kind, DiagKind.NOT_ASSIGNED)
    }

    // ==================================================================
    // 工具
    // ==================================================================

    private static func snapshot(names: Array<String>, paramTypes: Array<Array<UInt16>>,
        retTypes: Array<UInt16>): PredefinedSnapshot {
        PredefinedSnapshot(names, paramTypes, retTypes)
    }

    private static func captureResolveError(r: NameResolver, name: String): SourceCompileException {
        try {
            r.resolve(name, SourcePos(1, 15))
        } catch (e: SourceCompileException) {
            return e
        }
        @Fail('期望未注册函数诊断')
    }

    /** 跑一遍明确赋值分析（类型查询对未声明名返回 `NONE`）。 */
    private static func daOf(src: String): Bool {
        let lam = Parser(src).parseLambda()
        let da = DefiniteAssignment(src, { _ => LocalType.NONE })
        da.analyze(lam)
    }

    private static func expectDaError(src: String): SourceCompileException {
        try {
            Semantics_test.daOf(src)
        } catch (e: SourceCompileException) {
            return e
        }
        @Fail('期望明确赋值违规被拒')
    }
}
