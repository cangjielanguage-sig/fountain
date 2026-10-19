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
package fountain::f_jit.test

/**
 * 反射自动注册（Q5.2/Q5.3）的宿主侧夹具。
 *
 * 覆盖面刻意对齐 m2 §12.5：`public let/var`、`prop/mut prop`、`func`、
 * `static let/prop/func`、`constructors`；`static var` / `static mut prop` 与
 * 支撑面外类型（`Int32`）用于验证「跳过 + diagnostics」。
 */
public open class ReflectUser {
    public let id: Int64
    public var name: String
    public let raw: Int32
    private var _age: Int64
    private var _score: Int64

    public init() {
        this.id = 0
        this.name = ''
        this.raw = 0
        this._age = 0
        this._score = 0
    }

    public init(name: String) {
        this.id = 0
        this.name = name
        this.raw = 0
        this._age = 0
        this._score = 0
    }

    public init(name: String, id: Int64) {
        this.id = id
        this.name = name
        this.raw = 0
        this._age = 0
        this._score = 0
    }

    public prop age: Int64 {
        get() {
            this._age
        }
    }

    public mut prop score: Int64 {
        get() {
            this._score
        }
        set(v) {
            this._score = v
        }
    }

    public func greet(s: String): String {
        'hi ${s}'
    }

    public func bump(n: Int64): Unit {
        this._age = this._age + n
    }

    public static let version: Int64 = 1

    public static prop label: String {
        get() {
            'v${ReflectUser.version}'
        }
    }

    public static func parse(s: String): ReflectUser {
        ReflectUser(s)
    }

    public static var counter: Int64 = 0

    public static mut prop global: Int64 {
        get() {
            ReflectUser.counter
        }
        set(v) {
            ReflectUser.counter = v
        }
    }
}

/** 子类夹具：验证 `is C` 的继承语义。 */
public class ReflectAdmin <: ReflectUser {
    public init(name: String) {
        super(name)
    }
}

/** 泛型类夹具：`registerType<Box<Int64>>()` 的具体实例化。 */
public class ReflectBox<T> {
    public var value: T

    public init(value: T) {
        this.value = value
    }
}

/** 不可映射构造器参数夹具：`Int32` 不在 LocalType 映射表。 */
public class CtorBad {
    public let value: Int32

    public init(value: Int32) {
        this.value = value
    }
}

// JSON 谱系名夹具（M3 内建码 16–19；M2 只做名字拒绝，不参与 14 映射）。
public class JsonValue {}
public class JsonObject {}
public class JsonArray {}
public class JsonNull {}
