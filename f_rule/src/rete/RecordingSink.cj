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

import std.collection.ArrayList
import fountain::f_rule.agenda.{Activation, ActivationSink}

/**
 * 记录型激活汇（`doc/04-rete-network.md` §12）。
 *
 * 保留插入顺序，`remove` 按激活相等性删除。测试与差分基准用它代替议程；
 * 生产路径由 `agenda.Agenda` 实现 `ActivationSink`。
 */
public class RecordingSink <: ActivationSink {
    private let items: ArrayList<Activation>

    public init() {
        this.items = ArrayList<Activation>()
    }

    public func add(activation: Activation): Unit {
        items.add(activation)
    }

    public func remove(activation: Activation): Unit {
        var i = 0
        while (i < items.size) {
            if (items[i] == activation) {
                items.remove(at: i)
                return
            }
            i += 1
        }
    }

    public func activations(): Array<Activation> {
        items.toArray()
    }

    public func size(): Int64 {
        items.size
    }

    public func clear(): Unit {
        items.clear()
    }
}
