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

import std.collection.{ArrayList, HashMap, HashSet}
import fountain::f_rule.agenda.{Activation, ActivationSink}

/**
 * 记录型激活汇（`doc/04-rete-network.md` §12）。
 *
 * 保留插入顺序，`remove` 按激活相等性删除。测试与差分基准用它代替议程；
 * 生产路径由 `agenda.Agenda` 实现 `ActivationSink`。
 *
 * 撤销走"槽位墓碑 + 位置索引"：`activations()` 跳过墓碑，顺序与插入一致；
 * 墓碑超过一半时整理一次，均摊 O(1)。大规模用例下不能退化为线性扫描。
 */
public class RecordingSink <: ActivationSink {
    private let items: ArrayList<Activation>
    private let index: HashMap<String, Int64>
    private let dead: HashSet<Int64>

    public init() {
        this.items = ArrayList<Activation>()
        this.index = HashMap<String, Int64>()
        this.dead = HashSet<Int64>()
    }

    public func add(activation: Activation): Unit {
        let key = activation.sortKey()
        match (index.get(key)) {
            case Some(slot) =>
                // 同一激活重复加入：覆盖原槽位，保持"集合"语义且不制造重复条目。
                items[slot] = activation
                return
            case None => ()
        }
        index[key] = Int64(items.size)
        items.add(activation)
    }

    public func remove(activation: Activation): Unit {
        let key = activation.sortKey()
        match (index.remove(key)) {
            case Some(slot) =>
                dead.add(slot)
                compactIfNeeded()
            case None => ()
        }
    }

    public func activations(): Array<Activation> {
        let out = ArrayList<Activation>()
        var i: Int64 = 0
        while (i < Int64(items.size)) {
            if (!dead.contains(i)) {
                out.add(items[i])
            }
            i += 1
        }
        out.toArray()
    }

    public func size(): Int64 {
        Int64(items.size) - Int64(dead.size)
    }

    public func clear(): Unit {
        items.clear()
        index.clear()
        dead.clear()
    }

    private func compactIfNeeded(): Unit {
        if (Int64(dead.size) * 2 <= Int64(items.size)) {
            return
        }
        let kept = ArrayList<Activation>()
        var i: Int64 = 0
        while (i < Int64(items.size)) {
            if (!dead.contains(i)) {
                index[items[i].sortKey()] = Int64(kept.size)
                kept.add(items[i])
            }
            i += 1
        }
        items.clear()
        for (item in kept) {
            items.add(item)
        }
        dead.clear()
    }
}
