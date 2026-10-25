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
import fountain::f_jit.base.ErrCode
import fountain::f_jit.base.JitException
import fountain::f_jit.base.PublicCtor
import fountain::f_jit.base.PublicField
import fountain::f_jit.base.PublicMethod
import fountain::f_jit.test.TCase

/** Q5.12：槽 14 链内传参 + HostClosure 签名含 14（m2 §16.3/§16.4）。 */
@Test
public class Slot14_test {
    private static func compiler(): Compiler {
        CompileCache.reset()
        let c = Compiler(CompileOptions(DummyDiagnosticsSink()))
        c.registerClass(ClassDescriptor(name: 'ManualUser', fields: Array<PublicField>(),
            methods: Array<PublicMethod>(), ctors: Array<PublicCtor>()))
        c
    }

    /** 14 形参 / 局部 / 返回声明。 */
    @TestCase
    public func paramLocalReturn14(): Unit {
        let c = Slot14_test.compiler()
        let f = c.compile('{ u: ManualUser => let a = u\n a }')
        let u = ManualUser('bob', 1)
        let r = f.call<ManualUser>([u])
        @Assert(refEq(r, u), true)
        @Assert(TCase.hit('T58/param-local-return14', refEq(r, u)), true)
    }

    /** 跨 CALL_FUNC/闭包链传参 × 深度 ≥3；链内返回 14。 */
    @TestCase
    public func chainDepthThreeKeeps14(): Unit {
        let c = Slot14_test.compiler()
        let f = c.compile(
            '{ u: ManualUser =>' +
            ' let a = { x: ManualUser => x }\n' +
            ' let b = { x: ManualUser => a(x) }\n' +
            ' let cc = { x: ManualUser => b(x) }\n' +
            ' cc(u) }')
        let u = ManualUser('deep', 3)
        let r = f.call<ManualUser>([u])
        @Assert(refEq(r, u), true)
        @Assert(TCase.hit('T58/chain-depth3', refEq(r, u)), true)
    }

    /** 嵌套闭包捕获 14 局部（快照 = ID 拷贝）——非逃逸。 */
    @TestCase
    public func captured14InsideCall(): Unit {
        let c = Slot14_test.compiler()
        let f = c.compile('{ u: ManualUser => let a = { x: Int64 => u }\n a(1) }')
        let u = ManualUser('cap', 4)
        @Assert(refEq(f.call<ManualUser>([u]), u), true)
        @Assert(TCase.hit('T58/capture14', refEq(f.call<ManualUser>([u]), u)), true)
    }

    /** 逃逸闭包捕获 14：提升组保留 ID，包装器调用后仍能取回同一对象。 */
    @TestCase
    public func captured14EscapesAndSurvives(): Unit {
        let c = Slot14_test.compiler()
        let unit = c.compile('{ u: ManualUser => let a = { x: Int64 => u }\n a }')
        let u = ManualUser('esc', 5)
        let w = unit.callForFn<(Int64) -> ManualUser>([u])
        @Assert(refEq(w.call<ManualUser>([1]), u), true)
        let labelOk = refEq(w.call<ManualUser>([1]), u)
        w.unloadFn()
        @Assert(TCase.hit('T58/capture14-promoted', labelOk), true)
    }

    /** HostClosure 签名含 14：参数 14 验签/执行（R=String）。 */
    @TestCase
    public func hostClosureParam14(): Unit {
        let c = Slot14_test.compiler()
        let unit = c.compile('{ f: (ManualUser) -> String, u: ManualUser => f(u) }')
        // 反射验签按 `TypeInfo.name` 判具体类，宿主函数可直接写 `ManualUser`（GAP-04 已解）。
        let f: (ManualUser) -> String = { u => u.name }
        let u = ManualUser('host', 6)
        @Assert(unit.call<String>([f, u]), 'host')
        @Assert(TCase.hit('T59/host-closure-param14', unit.call<String>([f, u]) == 'host'), true)
    }

    /** HostClosure 签名含 14：R=14 返回（窗口登记 1 槽，取回实例引用）。 */
    @TestCase
    public func hostClosureRet14(): Unit {
        let c = Slot14_test.compiler()
        let unit = c.compile('{ f: () -> ManualUser => f() }')
        let made = ManualUser('ret', 7)
        let f: () -> ManualUser = { => made }
        @Assert(refEq(unit.call<ManualUser>([f]), made), true)
        @Assert(TCase.hit('T59/host-closure-ret14', refEq(unit.call<ManualUser>([f]), made)), true)
    }

    /** 验签失败（返回类型不符）→ 19（site=-1）。 */
    @TestCase
    public func hostClosureSigMismatchIs19(): Unit {
        let c = Slot14_test.compiler()
        let unit = c.compile('{ f: (ManualUser) -> String, u: ManualUser => f(u) }')
        let wrong: (ManualUser) -> Int64 = { _ => 1 }
        let u = ManualUser('x', 0)
        var code: Int64 = 0
        var site: Int64 = 0
        try {
            let _ = unit.call<String>([wrong, u])
        } catch (e: JitException) {
            code = e.code
            site = e.site
        }
        @Assert(code, ErrCode.CALL_CONTRACT)
        @Assert(site, -1)
    }
}
