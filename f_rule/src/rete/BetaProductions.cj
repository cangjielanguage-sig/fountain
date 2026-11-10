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
package fountain::f_rule.rete

import std.collection.{ArrayList, HashMap}
import fountain::f_rule.fact.FactHandle

/**
 * 单个 beta 节点在**某个会话内**的产出索引（`doc/04-rete-network.md` §6）。
 *
 * `右侧事实句柄 → 子令牌` 让 `rightRetract` 为 O(k)；`父令牌 → 子令牌` 让
 * `leftRetract` 为 O(k)。两者都是会话运行态，必须挂在 `(space, session)` 上：
 * 若放在共享的 `BetaNode` 上，第二个会话插入同一批事实时会命中上一个会话的索引，
 * 表现为"新会话没有激活"。
 */
public class BetaProductions {
    private let byHandle_: HashMap<FactHandle, ArrayList<Token>>
    private let byParent_: HashMap<Token, ArrayList<Token>>

    public init() {
        this.byHandle_ = HashMap<FactHandle, ArrayList<Token>>()
        this.byParent_ = HashMap<Token, ArrayList<Token>>()
    }

    /** 登记一条产出；子令牌已按 `(parent, handle)` 去重，不会重复登记。 */
    public func record(handle: FactHandle, parent: Token, child: Token): Unit {
        BetaProductions.append(byHandle_, handle, child)
        BetaProductions.append(byParent_, parent, child)
    }

    /** 取走该父令牌产出的全部子令牌（调用方负责移除与通知下游）。 */
    public func takeByParent(parent: Token): ?ArrayList<Token> {
        byParent_.remove(parent)
    }

    /** 取走该右侧事实产出的全部子令牌。 */
    public func takeByHandle(handle: FactHandle): ?ArrayList<Token> {
        byHandle_.remove(handle)
    }

    /** 撤销单条子令牌在两个索引里的登记。 */
    public func forget(child: Token): Unit {
        match (child.parent) {
            case Some(parent) => BetaProductions.removeFrom(byParent_, parent, child)
            case None => ()
        }
        BetaProductions.removeFrom(byHandle_, child.handle, child)
    }

    /** 该 (父令牌, 右侧事实) 是否已经产出过子令牌。 */
    public func contains(parent: Token, handle: FactHandle): Bool {
        match (byHandle_.get(handle)) {
            case Some(children) =>
                for (child in children) {
                    match (child.parent) {
                        case Some(existing) =>
                            if (existing == parent) {
                                return true
                            }
                        case None => ()
                    }
                }
                false
            case None => false
        }
    }

    private static func append<K>(map: HashMap<K, ArrayList<Token>>, key: K, token: Token): Unit
        where K <: Hashable & Equatable<K> {
        match (map.get(key)) {
            case Some(found) => found.add(token)
            case None =>
                let created = ArrayList<Token>()
                created.add(token)
                map[key] = created
        }
    }

    private static func removeFrom<K>(map: HashMap<K, ArrayList<Token>>, key: K,
        token: Token): Unit where K <: Hashable & Equatable<K> {
        match (map.get(key)) {
            case Some(children) =>
                var i = 0
                while (i < children.size) {
                    if (children[i] == token) {
                        children.remove(at: i)
                        break
                    }
                    i += 1
                }
                if (children.isEmpty()) {
                    map.remove(key)
                }
            case None => ()
        }
    }
}
