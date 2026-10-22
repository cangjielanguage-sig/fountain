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
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.base.ClassDescriptor
import fountain::f_jit.base.PublicCtor
import fountain::f_jit.base.PublicField
import fountain::f_jit.base.PublicMethod
import fountain::f_jit.base.RegistrationException
import fountain::f_jit.base.RegistrationRejectKind
import fountain::f_jit.compiler.ClassRegistryView
import fountain::f_jit.test.TCase

/** Q5.1：`ClassRegistry.register/snapshot/resolve`（m2 §12.4/§12.5、design-m2 §6.1.1）。 */
@Test
public class ClassRegistry_test {
    private static func desc(name: String): ClassDescriptor {
        ClassDescriptor(name: name, fields: Array<PublicField>(),
            methods: Array<PublicMethod>(), ctors: Array<PublicCtor>())
    }

    /** 注册后可查询；未注册 → None。 */
    @TestCase
    public func registerAndResolve(): Unit {
        let reg = ClassRegistry()
        reg.register(ClassRegistry_test.desc('User'))
        match (reg.resolve('User')) {
            case Some(d) => @Assert(TCase.hit('T55/registry-resolve', d.name == 'User'), true)
            case None => @Fail('已注册类解析失败')
        }
        @Assert(reg.resolve('Nope').isNone(), true)
        @Assert(reg.snapshot().classes.size, 1)
    }

    /** 同名类重复注册 → `RegistrationException(DuplicateClass)`，且注册表不变。 */
    @TestCase
    public func duplicateClassIsRejected(): Unit {
        let reg = ClassRegistry()
        reg.register(ClassRegistry_test.desc('User'))
        var caught: ?RegistrationException = None
        try {
            reg.register(ClassRegistry_test.desc('User'))
        } catch (e: RegistrationException) {
            caught = Some(e)
        }
        @Assert(caught.isSome(), true)
        match (caught) {
            case Some(e) =>
                @Assert(e.kind, RegistrationRejectKind.DuplicateClass)
                @Assert(e.name, 'User')
                match (e.occupiedBy) {
                    case Some(v) => @Assert(v, 'class:User')
                    case None => @Fail('occupiedBy 缺失')
                }
            case None => ()
        }
        @Assert(reg.snapshot().classes.size, 1)
        @Assert(TCase.hit('T55/duplicate-not-registered', reg.resolve('User').isSome()), true)
    }

    /** 类名与已注册函数名冲突 → `FunctionNameClash`，且不登记。 */
    @TestCase
    public func functionNameClashIsRejected(): Unit {
        let reg = ClassRegistry()
        reg.noteFunction('size')
        var caught: ?RegistrationException = None
        try {
            reg.register(ClassRegistry_test.desc('size'))
        } catch (e: RegistrationException) {
            caught = Some(e)
        }
        @Assert(caught.isSome(), true)
        match (caught) {
            case Some(e) =>
                @Assert(e.kind, RegistrationRejectKind.FunctionNameClash)
                @Assert(e.name, 'size')
                match (e.occupiedBy) {
                    case Some(v) => @Assert(v, 'func:size')
                    case None => @Fail('occupiedBy 缺失')
                }
            case None => ()
        }
        @Assert(reg.resolve('size').isNone(), true)
        @Assert(TCase.hit('T55/function-clash-not-registered', reg.snapshot().classes.size == 0), true)
    }

    /** 快照隔离：注册后旧快照不感知（m2 §8.4 快照语义）。 */
    @TestCase
    public func snapshotIsIsolated(): Unit {
        let reg = ClassRegistry()
        let old = reg.snapshot()
        reg.register(ClassRegistry_test.desc('User'))
        let view = ClassRegistryView(old)
        @Assert(view.isRegistered('User'), false)
        @Assert(old.classes.size, 0)
        @Assert(TCase.hit('T55/registry-snapshot', ClassRegistryView(reg.snapshot()).isRegistered('User')), true)
    }

    /** 并发注册：锁保护下所有类都可查（不丢更新）。 */
    @TestCase
    public func concurrentRegistrationIsSerialized(): Unit {
        let reg = ClassRegistry()
        let futures = ArrayList<Future<Unit>>()
        for (i in 0..8) {
            futures.add(spawn {
                reg.register(ClassRegistry_test.desc('C${i}'))
            })
        }
        for (f in futures) {
            f.get()
        }
        @Assert(reg.snapshot().classes.size, 8)
        for (i in 0..8) {
            @Assert(reg.resolve('C${i}').isSome(), true)
        }
    }
}
