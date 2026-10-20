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

import std.reflect.TypeInfo
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.base.DummyDiagnosticsSink
import fountain::f_jit.base.JitBindings
import fountain::f_jit.base.JitFieldBinding
import fountain::f_jit.base.LocalType
import fountain::f_jit.base.PredefinedFunction
import fountain::f_jit.base.PublicCtor
import fountain::f_jit.base.PublicMethod
import fountain::f_jit.macros.*

/**
 * M2.1：`@JitBind` 修饰类，一次生成**方法 / 字段 / 属性 / 构造器**四类类型化绑定。
 *
 * 目的是性能：把 `InstanceFunctionInfo.apply`、`InstanceVariableInfo.getValue/setValue`、
 * `ConstructorInfo.apply` 三条 MCC 路径一起换成静态调用。属性按 get/set 各算一条方法绑定。
 */
@JitBind
public class JitBindUser {
    public var name: String
    public let id: Int64
    private var _score: Int64

    /** 重载构造器 1：只有名字。 */
    public init(name: String) {
        this.name = name
        this.id = 0
        this._score = 0
    }

    /** 重载构造器 2：名字 + id。 */
    public init(name: String, id: Int64) {
        this.name = name
        this.id = id
        this._score = 0
    }

    /** 静态只读字段。 */
    public static let version: Int64 = 3

    /** 静态只读属性。 */
    public static prop label: String {
        get() {
            'v${JitBindUser.version}'
        }
    }

    /** 静态函数。 */
    public static func parse(s: String): String {
        'p${s}'
    }

    public func greet(s: String): String {
        'macro hi ${s}'
    }

    public func bump(n: Int64): Unit {
        this._score = this._score + n
    }

    public prop score: Int64 {
        get() {
            this._score
        }
    }

    public mut prop tag: String {
        get() {
            this.name
        }
        set(v) {
            this.name = v
        }
    }

    private func hidden(): Int64 {
        0
    }
}

@Test
public class JitBind_test {
    private static func bindings(): JitBindings {
        JitBindSupport.enrolledOf(TypeInfo.of<JitBindUser>().name)
    }

    private static func methodOf(name: String): PublicMethod {
        for (m in JitBind_test.bindings().methods) {
            if (m.name == name) {
                return m
            }
        }
        throw Exception('未生成方法「${name}」的绑定')
    }

    /** 四类成员都要进表，私有成员不能进。 */
    @TestCase
    public func macroEnrollsAllMemberKinds(): Unit {
        let b = JitBind_test.bindings()
        // 方法：greet / bump + 属性 getter(score) / getter(tag) / setter(setTag)
        @Assert(b.methods.size, 5)
        let _ = JitBind_test.methodOf('greet')
        let _ = JitBind_test.methodOf('bump')
        let _ = JitBind_test.methodOf('score')
        let _ = JitBind_test.methodOf('tag')
        let _ = JitBind_test.methodOf('setTag')

        // 字段：name(var，带 setter) / id(let，无 setter)
        @Assert(b.fields.size, 2)
        var nameField: ?JitFieldBinding = None
        var idField: ?JitFieldBinding = None
        for (f in b.fields) {
            if (f.name == 'name') {
                nameField = Some(f)
            }
            if (f.name == 'id') {
                idField = Some(f)
            }
        }
        match (nameField) {
            case Some(f) => @Assert(f.set.isSome(), true)
            case None => @Fail('字段 name 未生成绑定')
        }
        match (idField) {
            case Some(f) => @Assert(f.set.isNone(), true)
            case None => @Fail('字段 id 未生成绑定')
        }

        // 构造器：两条重载 (String) / (String, Int64)
        @Assert(b.ctors.size, 2)
        var hasOne = false
        var hasTwo = false
        for (c in b.ctors) {
            if (c.params.size == 1 && c.params[0] == LocalType.STRING) {
                hasOne = true
            }
            if (c.params.size == 2 && c.params[0] == LocalType.STRING &&
                c.params[1] == LocalType.I64) {
                hasTwo = true
            }
        }
        @Assert(hasOne, true)
        @Assert(hasTwo, true)

        // 静态成员：version / label / parse
        @Assert(b.statics.size, 3)
        var hasVersion = false
        var hasLabel = false
        var hasParse = false
        for (f in b.statics) {
            if (f.name == 'version') {
                hasVersion = true
            }
            if (f.name == 'label') {
                hasLabel = true
            }
            if (f.name == 'parse') {
                hasParse = true
            }
        }
        @Assert(hasVersion, true)
        @Assert(hasLabel, true)
        @Assert(hasParse, true)

        // 私有方法不入表
        for (m in b.methods) {
            @Assert(m.name == 'hidden', false)
        }
    }

    /** 端到端：注册不传 bindings，方法/字段/属性/构造器全部走类型化绑定。 */
    @TestCase
    public func allMemberKindsWorkEndToEnd(): Unit {
        let c = Compiler(CompileOptions(DummyDiagnosticsSink()))
        c.registerType<JitBindUser>()
        let u = JitBindUser('bob', 7)

        CompileCache.reset()
        let greet = c.compile('{ u: JitBindUser => u.greet("z") }')
        @Assert(greet.call<String>([u]), 'macro hi z')

        CompileCache.reset()
        let fieldGet = c.compile('{ u: JitBindUser => u.name }')
        @Assert(fieldGet.call<String>([u]), 'bob')

        CompileCache.reset()
        let fieldSet = c.compile('{ u: JitBindUser => u.name = "x"\n u.name }')
        @Assert(fieldSet.call<String>([u]), 'x')

        CompileCache.reset()
        let propGet = c.compile('{ u: JitBindUser => score(u) }')
        @Assert(propGet.call<Int64>([JitBindUser('ann', 1)]), 0)

        CompileCache.reset()
        let propSet = c.compile('{ u: JitBindUser => setTag(u, "t")\n tag(u) }')
        @Assert(propSet.call<String>([u]), 't')

        CompileCache.reset()
        let ctor = c.compile('{ => JitBindUser("cid", 2) }')
        @Assert(ctor.call<JitBindUser>([]).id, 2)

        CompileCache.reset()
        let ctor1 = c.compile('{ => JitBindUser("only") }')
        @Assert(ctor1.call<JitBindUser>([]).id, 0)

        CompileCache.reset()
        let staticField = c.compile('{ => version() }')
        @Assert(staticField.call<Int64>([]), 3)

        CompileCache.reset()
        let staticProp = c.compile('{ => label() }')
        @Assert(staticProp.call<String>([]), 'v3')

        CompileCache.reset()
        let staticFunc = c.compile('{ => parse("x") }')
        @Assert(staticFunc.call<String>([]), 'px')
    }

    /** 性能路径的回归：全部走类型化绑定后 300 次调用不崩、结果稳定。 */
    @TestCase
    public func typedBindingsSurviveRepeatedCalls(): Unit {
        let c = Compiler(CompileOptions(DummyDiagnosticsSink()))
        c.registerType<JitBindUser>()
        CompileCache.reset()
        let f = c.compile('{ u: JitBindUser => u.greet("z") }')
        let u = JitBindUser('bob', 0)
        var i = 0
        var ok = true
        while (i < 300) {
            if (f.call<String>([u]) != 'macro hi z') {
                ok = false
            }
            i = i + 1
        }
        @Assert(ok, true)
    }
}
