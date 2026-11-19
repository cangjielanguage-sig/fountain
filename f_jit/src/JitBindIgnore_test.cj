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

import std.collection.HashSet
import std.reflect.TypeInfo
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.base.DummyDiagnosticsSink
import fountain::f_jit.base.SourceCompileException
import fountain::f_jit.macros.*

/**
 * `@IgnoreJitBinding`（D10）：成员级退出标记。
 *
 * 覆盖四类成员（静态函数 / 实例方法 / 实例字段 / 属性）的忽略、未标注成员的登记不变，
 * 以及脚本面是否真的看不到被忽略的成员。
 */
@JitBind
public class JitBindIgnoreUser {
    /** 未被忽略的静态只读字段，必须继续进 `statics`。 */
    public static let version: Int64 = 7

    /** 未被忽略的静态函数，必须继续进 `statics`。 */
    public static func keep(s: String): String {
        'k${s}'
    }

    /** 宿主专用静态入口，不得进脚本静态名空间。 */
    @IgnoreJitBinding
    public static func hostOnly(): String {
        'host'
    }

    /** 未被忽略的实例字段。 */
    public var name: String

    /** 被忽略的实例字段（无 getter 绑定）。 */
    @IgnoreJitBinding
    public var secret: String

    public init(name: String) {
        this.name = name
        this.secret = ''
    }

    /** 未被忽略的实例方法。 */
    public func greet(): String {
        'hi ${this.name}'
    }

    /** 被忽略的实例方法。 */
    @IgnoreJitBinding
    public func hidden(): String {
        'hidden'
    }

    /** 未被忽略的只读属性（getter 进 `methods`）。 */
    public prop label: String {
        get() {
            'label'
        }
    }

    /** 被忽略的只读属性（getter 不得进 `methods`）。 */
    @IgnoreJitBinding
    public prop ignoredProp: String {
        get() {
            'ignored'
        }
    }

    /** 被忽略的可变属性（getter 与 `setIgnoredTag` 都不得进 `methods`）。 */
    @IgnoreJitBinding
    public mut prop ignoredTag: String {
        get() {
            'ignored-tag'
        }
        set(v) {
            this.name = v
        }
    }
}

@Test
public class JitBindIgnore_test {
    private static func bindings(): JitBindings {
        JitBindSupport.enrolledOf(TypeInfo.of<JitBindIgnoreUser>().name)
    }

    private static func methodNames(): HashSet<String> {
        let names = HashSet<String>()
        for (m in JitBindIgnore_test.bindings().methods) {
            names.add(m.name)
        }
        names
    }

    private static func staticNames(): HashSet<String> {
        let names = HashSet<String>()
        for (f in JitBindIgnore_test.bindings().statics) {
            names.add(f.name)
        }
        names
    }

    private static func fieldNames(): HashSet<String> {
        let names = HashSet<String>()
        for (f in JitBindIgnore_test.bindings().fields) {
            names.add(f.name)
        }
        names
    }

    /** 静态函数：标注的 `hostOnly` 不在 `statics`，其余静态成员仍在。 */
    @TestCase
    public func ignoredStaticFuncStaysOutOfStatics(): Unit {
        let statics = JitBindIgnore_test.staticNames()
        @Assert(statics.size, 2)
        @Assert(statics.contains('version'), true)
        @Assert(statics.contains('keep'), true)
        @Assert(statics.contains('hostOnly'), false)
    }

    /** 实例方法：`hidden` 与两个被忽略属性的 getter/setter 都不进 `methods`。 */
    @TestCase
    public func ignoredInstanceMethodsAreNotEnrolled(): Unit {
        let methods = JitBindIgnore_test.methodNames()
        @Assert(methods.contains('greet'), true)
        @Assert(methods.contains('label'), true)
        @Assert(methods.contains('hidden'), false)
        @Assert(methods.contains('ignoredProp'), false)
        @Assert(methods.contains('ignoredTag'), false)
        @Assert(methods.contains('setIgnoredTag'), false)
        @Assert(methods.size, 2)
    }

    /** 实例字段：`secret` 不进 `fields`，`name` 仍在。 */
    @TestCase
    public func ignoredInstanceFieldIsNotEnrolled(): Unit {
        let fields = JitBindIgnore_test.fieldNames()
        @Assert(fields.size, 1)
        @Assert(fields.contains('name'), true)
        @Assert(fields.contains('secret'), false)
    }

    /** 反向守卫：同一类里未标注的成员仍被登记（忽略名单不能误伤）。 */
    @TestCase
    public func unannotatedMembersStillBound(): Unit {
        let b = JitBindIgnore_test.bindings()
        var kept = 0
        for (f in b.statics) {
            if (f.name == 'keep') {
                kept = kept + 1
            }
        }
        @Assert(kept, 1)
        var greeted = 0
        for (m in b.methods) {
            if (m.name == 'greet') {
                greeted = greeted + 1
            }
        }
        @Assert(greeted, 1)
    }

    /** 端到端：被忽略的成员在脚本里既调不到、也不占据全局名。 */
    @TestCase
    public func ignoredMembersAreInvisibleToScripts(): Unit {
        let c = Compiler(CompileOptions(DummyDiagnosticsSink()))
        c.registerType<JitBindIgnoreUser>()
        let u = JitBindIgnoreUser('bob')

        CompileCache.reset()
        @Assert(c.compile('{ => keep("x") }').call<String>([]), 'kx')

        CompileCache.reset()
        @Assert(c.compile('{ u: JitBindIgnoreUser => u.greet() }').call<String>([u]), 'hi bob')

        CompileCache.reset()
        @Assert(c.compile('{ u: JitBindIgnoreUser => label(u) }').call<String>([u]), 'label')

        CompileCache.reset()
        let staticErr = try {
            let _ = c.compile('{ => hostOnly() }')
            ''
        } catch (e: SourceCompileException) {
            e.message
        }
        @Assert(staticErr.size > 0, true)

        CompileCache.reset()
        let methodErr = try {
            let _ = c.compile('{ u: JitBindIgnoreUser => u.hidden() }')
            ''
        } catch (e: SourceCompileException) {
            e.message
        }
        @Assert(methodErr.size > 0, true)

        CompileCache.reset()
        let fieldErr = try {
            let _ = c.compile('{ u: JitBindIgnoreUser => u.secret }')
            ''
        } catch (e: SourceCompileException) {
            e.message
        }
        @Assert(fieldErr.size > 0, true)
    }
}
