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
package fountain::f_jit.base

import std.collection.ArrayList

/**
 * 字段的**类型化绑定**（M2.1）：替代 `InstanceVariableInfo.getValue/setValue` 的反射路径。
 *
 * `get` / `set` 由 `@JitBind` 生成，函数体是 `match (o as C) { … }` 后直接读写字段——
 * 不装箱、不查 MCC，读一次就是一次字段访问加一次类型判断。
 *
 * `set` 为 `None` 表示 `let` 字段（不可写）；`var` 字段必须给出。
 */
public class JitFieldBinding {
    public let name: String
    public let get: (Object) -> Any
    public let set: ?((Object, Any) -> Unit)

    public init(name!: String, get!: (Object) -> Any, set!: ?((Object, Any) -> Unit) = None) {
        this.name = name
        this.get = get
        this.set = set
    }
}

/**
 * 一个类的全部类型化绑定（M2.1）：方法 / 字段 / 构造器三张表。
 *
 * `@JitBind` 在包初始化期用 `JitBindSupport.enrollOf<T>(JitBindings(…))` 登记，
 * `registerType<T>()` 按类全限定名取用；显式传参**合并**其上（同成员以显式为准）。
 */
public class JitBindings {
    public let methods: Array<PublicMethod>
    public let fields: Array<JitFieldBinding>
    public let ctors: Array<PublicCtor>
    /**
     * 静态成员的绑定（静态函数 / 静态只读字段 / 只读静态属性）。
     *
     * 静态成员在注册表里没有 `PublicMethod` 条目，只以「自动包装函数」形式存在（名字即成员名），
     * 因此这里直接存 `PredefinedFunction`，注册时按名替换 `auto` 表里的反射版本。
     */
    public let statics: Array<PredefinedFunction>

    /** 接口的父接口名（`superTypes`，宏登记；类的父类由反射链推导，不在此列）。 */
    public let parents: Array<String>

    /**
     * 成员级退出名单（`@IgnoreJitBinding`，D10）：这些名字**既不由宏登记，也不退回反射包装**。
     *
     * 只有宏能填写它；默认空数组，老调用方（手工构造 `JitBindings`）行为不变。
     */
    public let ignored: Array<String>

    public init(methods!: Array<PublicMethod> = Array<PublicMethod>(),
        fields!: Array<JitFieldBinding> = Array<JitFieldBinding>(),
        ctors!: Array<PublicCtor> = Array<PublicCtor>(),
        statics!: Array<PredefinedFunction> = Array<PredefinedFunction>(),
        parents!: Array<String> = Array<String>(),
        ignored!: Array<String> = Array<String>()) {
        this.methods = methods
        this.fields = fields
        this.ctors = ctors
        this.statics = statics
        this.parents = parents
        this.ignored = ignored
    }

    public static func empty(): JitBindings {
        JitBindings()
    }

    public func isEmpty(): Bool {
        this.methods.size == 0 && this.fields.size == 0 && this.ctors.size == 0 &&
            this.statics.size == 0
    }

    /**
     * 把 `over` **合并**到自身之上：同名/同形参的项由 `over` 顶掉，其余保留。
     *
     * 为什么是合并而不是整体取代：`@JitBind` 的自动登记覆盖整类成员。若显式传参整体取代它，
     * 用户为改一个方法就得把字段/构造器/静态成员的绑定全部重写一遍；漏掉的那些会退回反射，
     * 而引用型签名的成员在反射侧属于「默认拒绝」，于是「只想改一个方法」变成「掉一半成员」。
     * 合并让显式传参只表达「我要改哪几条」。
     */
    public func withOverrides(over: JitBindings): JitBindings {
        var ms = this.methods
        for (o in over.methods) {
            ms = JitBindings.replaceMethod(ms, o)
        }
        var fs = this.fields
        for (o in over.fields) {
            fs = JitBindings.replaceField(fs, o)
        }
        var cs = this.ctors
        for (o in over.ctors) {
            cs = JitBindings.replaceCtor(cs, o)
        }
        var ss = this.statics
        for (o in over.statics) {
            ss = JitBindings.replaceStatic(ss, o)
        }
        JitBindings(methods: ms, fields: fs, ctors: cs, statics: ss, parents: this.parents,
            ignored: JitBindings.union(this.ignored, over.ignored))
    }

    /** 名字数组合并（保持首次出现顺序、去重）：忽略名单可能同时来自自动登记与显式覆盖。 */
    private static func union(a: Array<String>, b: Array<String>): Array<String> {
        if (b.size == 0) {
            return a
        }
        let out = ArrayList<String>()
        for (x in a) {
            out.add(x)
        }
        for (x in b) {
            if (!out.contains(x)) {
                out.add(x)
            }
        }
        out.toArray()
    }

    private static func replaceMethod(xs: Array<PublicMethod>, v: PublicMethod)
        : Array<PublicMethod> {
        var i = 0
        while (i < xs.size) {
            if (xs[i].name == v.name) {
                let out = xs.clone()
                out[i] = v
                return out
            }
            i = i + 1
        }
        let out = Array<PublicMethod>(xs.size + 1, repeat: v)
        i = 0
        while (i < xs.size) {
            out[i] = xs[i]
            i = i + 1
        }
        out[xs.size] = v
        out
    }

    private static func replaceField(xs: Array<JitFieldBinding>, v: JitFieldBinding)
        : Array<JitFieldBinding> {
        var i = 0
        while (i < xs.size) {
            if (xs[i].name == v.name) {
                let out = xs.clone()
                out[i] = v
                return out
            }
            i = i + 1
        }
        let out = Array<JitFieldBinding>(xs.size + 1, repeat: v)
        i = 0
        while (i < xs.size) {
            out[i] = xs[i]
            i = i + 1
        }
        out[xs.size] = v
        out
    }

    private static func replaceCtor(xs: Array<PublicCtor>, v: PublicCtor): Array<PublicCtor> {
        var i = 0
        while (i < xs.size) {
            if (JitBindings.sameParams(xs[i].params, v.params)) {
                let out = xs.clone()
                out[i] = v
                return out
            }
            i = i + 1
        }
        let out = Array<PublicCtor>(xs.size + 1, repeat: v)
        i = 0
        while (i < xs.size) {
            out[i] = xs[i]
            i = i + 1
        }
        out[xs.size] = v
        out
    }

    private static func replaceStatic(xs: Array<PredefinedFunction>, v: PredefinedFunction)
        : Array<PredefinedFunction> {
        var i = 0
        while (i < xs.size) {
            if (xs[i].name == v.name) {
                let out = xs.clone()
                out[i] = v
                return out
            }
            i = i + 1
        }
        let out = Array<PredefinedFunction>(xs.size + 1, repeat: v)
        i = 0
        while (i < xs.size) {
            out[i] = xs[i]
            i = i + 1
        }
        out[xs.size] = v
        out
    }

    /** 按成员名取静态绑定；未登记 → `None`（退回反射包装）。 */
    public func staticOf(name: String): ?PredefinedFunction {
        for (f in this.statics) {
            if (f.name == name) {
                return Some(f)
            }
        }
        None
    }

    /** 按字段名取绑定；未登记 → `None`（该字段退回反射）。 */
    public func fieldOf(name: String): ?JitFieldBinding {
        for (f in this.fields) {
            if (f.name == name) {
                return Some(f)
            }
        }
        None
    }

    /** 按形参码序列取构造器绑定；未登记 → `None`。 */
    public func ctorOf(params: Array<UInt16>): ?PublicCtor {
        for (c in this.ctors) {
            if (JitBindings.sameParams(c.params, params)) {
                return Some(c)
            }
        }
        None
    }

    private static func sameParams(a: Array<UInt16>, b: Array<UInt16>): Bool {
        if (a.size != b.size) {
            return false
        }
        var i = 0
        while (i < a.size) {
            if (a[i] != b[i]) {
                return false
            }
            i = i + 1
        }
        true
    }
}
