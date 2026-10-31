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
package fountain::f_rule.rule

import std.collection.{ArrayList, HashMap}
import fountain::f_rule.fact.Fact

/**
 * 绑定表：绑定名 → 事实（`doc/08-api.md` §4）。
 *
 * 不可变视图：[merged] 返回新实例，原实例不被修改，便于令牌共享与回溯。
 */
public class Bindings {
    private let map_: HashMap<String, Fact>

    private init(map: HashMap<String, Fact>) {
        this.map_ = map
    }

    public static func empty(): Bindings {
        Bindings(HashMap<String, Fact>())
    }

    public static func of(map: HashMap<String, Fact>): Bindings {
        Bindings(map)
    }

    public func get(binding: String): ?Fact {
        map_.get(binding)
    }

    public func merged(binding: String, fact: Fact): Bindings {
        let copy = HashMap<String, Fact>()
        for ((key, value) in map_) {
            copy[key] = value
        }
        copy[binding] = fact
        Bindings(copy)
    }

    public func bindings(): Array<String> {
        let names = ArrayList<String>()
        for ((key, _) in map_) {
            names.add(key)
        }
        names.toArray()
    }

    public func toMap(): HashMap<String, Fact> {
        let copy = HashMap<String, Fact>()
        for ((key, value) in map_) {
            copy[key] = value
        }
        copy
    }

    public func size(): Int64 {
        map_.size
    }

    public func isEmpty(): Bool {
        map_.isEmpty()
    }
}
