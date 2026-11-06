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
package fountain::f_rule.fact

import std.sync.Mutex

/**
 * 可字段寻址的事实（`doc/02-fact-model.md` §2）。
 *
 * 实现方必须保证：进入 Rete 网络后 [get] 的返回值不再变化；需要修改时走
 * `FactBase.update()`，内部等价于 retract + assert。
 */
public interface Fact {
    /** 类型标签，alpha 网络的分桶键。同一业务类型必须恒定。 */
    prop typeTag: String
    /** 按字段名取值。字段不存在返回 None；字段存在但值为空也应返回 None。 */
    func get(field: String): ?Any
    /** 字段是否存在（与值为 None 区分）。 */
    func has(field: String): Bool
}

/**
 * 能交出宿主对象的强类型事实。
 *
 * `f_jit` 的脚本形参必须是真实宿主类（`{ o: Order => ... }`），而网络只持有 `Fact`；
 * 这层桥只给 JIT 取原始对象，解释器路径仍走 [Fact.get]，两者语义一致。
 */
public interface HostFact {
    /** 返回注册 `FactSchema` 时的那个对象引用。 */
    func hostObject(): Any
}

/**
 * 包内可见的实例身份。
 *
 * `FactBase` 需要"同一实例重复 assert 抛 DUPLICATE_FACT"，但仓颉的类默认不实现
 * `Hashable`、`Object` 也没有 identity hash，无法用对象本身做键。这里给本模块自己的
 * 事实实现一个进程内单调 id，`FactBase` 用它做 O(1) 判重；外部自定义的 `Fact`
 * 实现退回 `refEq` 线性扫描。
 */
public interface IdentifiedFact {
    prop identity: Int64
}

/** 进程内单调 id 分配器（事实实例身份，不参与任何持久化语义）。 */
class FactIdentity {
    private static let mtx = Mutex()
    private static var counter: Int64 = 0

    private init() {}

    static func next(): Int64 {
        synchronized(mtx) {
            counter += 1
            counter
        }
    }
}

/**
 * 网络内部的事实句柄（`doc/02-fact-model.md` §2）。
 *
 * 网络传播与索引只持有句柄，不直接持有事实对象，避免大量 token 长期滞留业务对象。
 * 相等性与哈希**只看 `(space, id)`**：id 只在同一 `(space, session)` 内唯一，
 * `typeTag` 仅用于调试与桶定位。
 */
public class FactHandle <: Hashable & Equatable<FactHandle> & ToString {
    public let space: String
    public let id: Int64
    public let typeTag: String

    public init(space: String, id: Int64, typeTag: String) {
        this.space = space
        this.id = id
        this.typeTag = typeTag
    }

    public func hashCode(): Int64 {
        // 只用 xor 组合：(space, id) 唯一即可，避免乘法在极端 id 上溢出。
        space.hashCode() ^ id
    }

    public operator func ==(other: FactHandle): Bool {
        this.space == other.space && this.id == other.id
    }

    public operator func !=(other: FactHandle): Bool {
        !(this == other)
    }

    public func toString(): String {
        "${space}#${id}(${typeTag})"
    }
}

/** 保留标签与命名约定；避免各处散落魔法字符串。 */
public class TypeTag {
    private init() {}

    /** 未显式声明空间时的固定空间 id。 */
    public static prop DEFAULT_SPACE: String {
        get() {
            "default"
        }
    }

    /** `DynamicFact` 的默认类型标签（未显式指定时）。 */
    public static prop DYNAMIC_FACT: String {
        get() {
            "DynamicFact"
        }
    }
}
