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
 * `registerType<T>()` 未显式传参时按类全限定名取用；显式传参优先。
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

    public init(methods!: Array<PublicMethod> = Array<PublicMethod>(),
        fields!: Array<JitFieldBinding> = Array<JitFieldBinding>(),
        ctors!: Array<PublicCtor> = Array<PublicCtor>(),
        statics!: Array<PredefinedFunction> = Array<PredefinedFunction>()) {
        this.methods = methods
        this.fields = fields
        this.ctors = ctors
        this.statics = statics
    }

    public static func empty(): JitBindings {
        JitBindings()
    }

    public func isEmpty(): Bool {
        this.methods.size == 0 && this.fields.size == 0 && this.ctors.size == 0 &&
            this.statics.size == 0
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
