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
import fountain::f_jit.base.ClassDescriptor
import fountain::f_jit.base.DummyDiagnosticsSink
import fountain::f_jit.base.LocalType
import fountain::f_jit.base.PublicCtor
import fountain::f_jit.base.PublicField
import fountain::f_jit.base.PublicMethod
import fountain::f_jit.base.Version
import fountain::f_jit.compiler.ClassRegistrySnapshot
import fountain::f_jit.compiler.PredefinedSnapshot
import fountain::f_jit.compiler.SourceCompiler
import fountain::f_jit.runtime.HandleTable
import fountain::f_jit.runtime.HostCallback
import fountain::f_jit.runtime.HostFieldTable
import fountain::f_jit.runtime.SignatureDescriptor
import fountain::f_jit.test.TCase
import fountain::f_jit.test.diff.DiffCase
import fountain::f_jit.test.diff.DiffSession
import fountain::f_jit.test.diff.InterpRunner
import fountain::f_jit.test.diff.NativeRunner

/**
 * GAP-07：把 M2 新增面纳入三引擎差分。
 *
 * verify 认定 `糖与手写对拍`、`对象身份` 只到「单引擎正确」——`Q6Compiler_test` 的
 * `DiffSession` 原先只覆盖 HostCall 的值型/String/异常/重入。本文件补三类：
 *
 * 1. **14 实参**（类实例作源入口实参，`tag=11` 槽）——含对象身份；
 * 2. **成员访问糖**（`u.f` 的降级链 + 字段访问器）；
 * 3. **句柄型实参**（String 先 pin 成句柄，再经 13 槽调宿主闭包）。
 *
 * 放在**根包**而非 `compiler`：新用例要建 `ClassRegistrySnapshot`（compiler 包）与 `Compiler`（根包），
 * 而 `compiler` 包已被根包依赖——反向 import 会成环（`fountain::f_jit <-> …compiler`）。
 */
@Test
public class Q6DiffCoverage_test {
    private static func pinHost(fn: Any, params: Array<UInt16>, ret: UInt16): Int64 {
        HandleTable.pin(HostCallback(fn, SignatureDescriptor(params, ret)))
    }

    /** 带类注册的编译（`classes` 提供类型注解与成员访问所需的静态知识）。 */
    private static func rawOfWith(src: String, classes: ClassRegistrySnapshot): Array<UInt8> {
        let sc = SourceCompiler(PredefinedSnapshot.empty(), DummyDiagnosticsSink(),
            verMajor: Version.M2_MAJOR, classes: classes)
        sc.compile(src).raw
    }

    private static func diffWith(id: String, src: String, args: Array<Any>,
        classes: ClassRegistrySnapshot): DiffSession {
        let session = DiffSession([InterpRunner(), NativeRunner()])
        session.assertTripleEqual(DiffCase(id, Q6DiffCoverage_test.rawOfWith(src, classes), args))
        session
    }

    /** 最小注册类 `DiffEntity`：一个句柄型字段 + 一个值型字段，并装好字段访问器。 */
    private static func entityClasses(): ClassRegistrySnapshot {
        let c = Compiler(CompileOptions(DummyDiagnosticsSink()))
        c.registerClass(ClassDescriptor(name: 'DiffEntity',
            fields: [
                PublicField(name: 'name', `type`: LocalType.STRING, index: 0u16,
                    mutable: true, typeRef: None),
                PublicField(name: 'age', `type`: LocalType.I64, index: 1u16,
                    mutable: true, typeRef: None)
            ],
            methods: Array<PublicMethod>(), ctors: Array<PublicCtor>()))
        HostFieldTable.register(index: 0u16, `type`: LocalType.STRING, mutable: true,
            accepts: { o => o is DiffEntity },
            getter: { o => match (o) { case e: DiffEntity => e.name; case _ => '' } },
            setter: { o, v => match ((o, v)) {
                case (e: DiffEntity, s: String) => e.name = s
                case _ => ()
            } })
        HostFieldTable.register(index: 1u16, `type`: LocalType.I64, mutable: true,
            accepts: { o => o is DiffEntity },
            getter: { o => match (o) { case e: DiffEntity => e.age; case _ => 0 } },
            setter: { o, v => match ((o, v)) {
                case (e: DiffEntity, n: Int64) => e.age = n
                case _ => ()
            } })
        c.classSnapshot()
    }

    /**
     * T57：**类实例作源入口实参**进差分（14 槽）。
     *
     * 两引擎看到同一句柄表条目（同一 `tag=11` 槽），故「同一对象」这条在差分里也成立；
     * 结果同时验证 `u.name` 的字段读在两引擎上逐位一致。
     */
    @TestCase
    public func t57HostObjectArgIsTripleEqual(): Unit {
        HandleTable.resetForTest()
        HostFieldTable.resetForTest()
        let classes = Q6DiffCoverage_test.entityClasses()
        let e = DiffEntity('ann', 7)
        let session = Q6DiffCoverage_test.diffWith('T57/host-object-arg',
            '{ u: DiffEntity => u.name }', [e], classes)
        @Assert(TCase.hit('T57/host-object-arg-diff',
            session.skipped() == 0 && session.ran() >= 2), true)
        HandleTable.resetForTest()
        HostFieldTable.resetForTest()
    }

    /** T35：**成员访问糖**进差分（`u.f` 降级链 + 字段访问器在两引擎上逐位一致）。 */
    @TestCase
    public func t35SugarIsTripleEqual(): Unit {
        HandleTable.resetForTest()
        HostFieldTable.resetForTest()
        let classes = Q6DiffCoverage_test.entityClasses()
        let e = DiffEntity('bob', 41)
        let session = Q6DiffCoverage_test.diffWith('T35/sugar-field-get',
            '{ u: DiffEntity => u.age + 1 }', [e], classes)
        @Assert(TCase.hit('T35/sugar-field-diff',
            session.skipped() == 0 && session.ran() >= 2), true)
        HandleTable.resetForTest()
        HostFieldTable.resetForTest()
    }

    /** T33：**句柄型实参**（String）进差分——实参先 pin 成句柄，再经 13 槽调宿主闭包。 */
    @TestCase
    public func t33HandleArgIsTripleEqual(): Unit {
        HandleTable.resetForTest()
        let h = Q6DiffCoverage_test.pinHost({ s: String => s + '!' },
            [LocalType.STRING], LocalType.STRING)
        // String 实参：pin 成 4 型句柄，机器码侧按句柄槽传
        let sh = HandleTable.pin('hi')
        let session = DiffSession([InterpRunner(), NativeRunner()])
        session.assertTripleEqual(DiffCase('T33/handle-arg',
            Q6DiffCoverage_test.rawOfWith('{ f: (String) -> String, s: String => f(s) }',
                ClassRegistrySnapshot.empty()), [h, sh]))
        @Assert(TCase.hit('T33/handle-arg-diff',
            session.skipped() == 0 && session.ran() >= 2), true)
        HandleTable.resetForTest()
    }
}

/** 差分用例的最小注册类（字段访问器装在 `entityClasses` 里）。 */
public class DiffEntity {
    public var name: String
    public var age: Int64

    public init(name: String, age: Int64) {
        this.name = name
        this.age = age
    }
}
