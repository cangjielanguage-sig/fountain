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

import std.collection.ArrayList
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.base.ClassDescriptor
import fountain::f_jit.base.DummyDiagnosticsSink
import fountain::f_jit.base.PredefinedFunction
import fountain::f_jit.base.PublicCtor
import fountain::f_jit.base.PublicField
import fountain::f_jit.base.PublicMethod

/**
 * 并发注册的注册表完整性（H5）。
 *
 * 4 线程各注册 20 个类（每类 1 个方法），注册后立即断言「类可见 ⇒ 方法也可见」。
 * 旧实现把 `classes.register` 放在 `Compiler.mtx` 之外，存在「类已可见、方法尚未进入
 * 函数快照」的窗口；本用例的成对断言是该窗口的直接探针。
 *
 * 注册完成后，再逐个编译引用这些方法的源码（80 次），确认快照完整。
 */
@Test
public class CompilerRegistrationConcurrency_test {
    @TestCase
    public func concurrentRegistrationKeepsRegistryComplete(): Unit {
        CompileCache.reset()
        let c = Compiler(CompileOptions(DummyDiagnosticsSink()))
        let threads = Int64(4)
        let per = Int64(20)
        let fs = ArrayList<Future<Int64>>()
        var t = 0
        while (t < threads) {
            let base = Int64(t * 1000)
            fs.add(spawn {
                var bad = 0
                var k = 0
                while (k < per) {
                    let name = 'ConcReg_${base + Int64(k)}'
                    let bindName = '${name}.m'
                    let pf = PredefinedFunction(bindName,
                        [LocalType.HOST_OBJECT, LocalType.I64], LocalType.I64,
                        { _ => Int64(1) })
                    c.registerClass(ClassDescriptor(name: name, fields: Array<PublicField>(),
                        methods: [PublicMethod(name: 'm', bind: pf)], ctors: Array<PublicCtor>()))
                    // 同一临界区语义：看到类 ⇒ 方法也已进函数面。
                    if (!c.hasClass(name)) {
                        bad = bad + 1
                    }
                    if (!c.hasFunction(bindName)) {
                        bad = bad + 1
                    }
                    k = k + 1
                }
                bad
            })
            t = t + 1
        }
        var bad = 0
        for (x in fs) {
            bad = bad + x.get()
        }
        @Assert(bad, 0)
        // 注册完成后，每个类的成员调用都能编译（名字解析要查到 Cls.m）。
        var i = 0
        while (i < threads * per) {
            let name = 'ConcReg_${(i / per) * 1000 + (i % per)}'
            let f = c.compile('{ u: ${name} => u.m(1) }')
            @Assert(f.isJitBacked(), true)
            let _ = f.close(0)
            i = i + 1
        }
        @Assert(c.registeredNames().size >= threads * per, true)
    }
}
