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

import std.collection.{ArrayList, HashMap}
import fountain::f_rule.exception.*

/**
 * 规则集级空间注册表（`doc/02-fact-model.md` §6、§8）。
 *
 * 构建期单线程；`freeze()` 后空间集合与全部类型描述只读，运行期新增抛 `NETWORK_FROZEN`。
 */
public class FactSpaceRegistry {
    private let spaces_: HashMap<String, FactSpace>
    private let order_: ArrayList<String>
    private var frozen_: Bool

    public init() {
        this.spaces_ = HashMap<String, FactSpace>()
        this.order_ = ArrayList<String>()
        this.frozen_ = false
    }

    public prop frozen: Bool {
        get() {
            frozen_
        }
    }

    /** 声明空间；已存在时返回同一实例。冻结后抛 `NETWORK_FROZEN`。 */
    public func declare(id: String): FactSpace {
        match (spaces_.get(id)) {
            case Some(existing) => return existing
            case None => ()
        }
        if (frozen_) {
            throw RuleException(
                RuleErrorCode.NETWORK_FROZEN,
                "事实空间集合已冻结，不能声明空间 ${id}"
            )
        }
        let space = FactSpace(id)
        spaces_[id] = space
        order_.add(id)
        space
    }

    public func has(id: String): Bool {
        spaces_.contains(id)
    }

    public func get(id: String): ?FactSpace {
        spaces_.get(id)
    }

    /** 按声明顺序返回全部空间。 */
    public func spaces(): Array<FactSpace> {
        let out = ArrayList<FactSpace>()
        for (id in order_) {
            match (spaces_.get(id)) {
                case Some(space) => out.add(space)
                case None => ()
            }
        }
        out.toArray()
    }

    public func ids(): Array<String> {
        order_.toArray()
    }

    /** 冻结空间集合与全部类型描述；可重复调用。 */
    public func freeze(): Unit {
        frozen_ = true
        for (id in order_) {
            match (spaces_.get(id)) {
                case Some(space) => space.freeze()
                case None => ()
            }
        }
    }
}
