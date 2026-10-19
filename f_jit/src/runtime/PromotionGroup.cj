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
package fountain::f_jit.runtime

import std.collection.ArrayList
import std.collection.HashMap

/**
 * 逃逸闭包回桥的**提升组**（m2 §14.1/§14.2、design-m2 §5.1.3）。
 *
 * 每个逃逸闭包一个实例；组内条目 = 闭包自身槽 + 各句柄型捕获所指的槽（**槽级**，不进入
 * 容器/对象内部——§14.6 免级联）。三规则：
 *
 * 1. **清单与幂等计数**：重复 `add`（多闭包共享捕获）只提升一次、计数 +1；
 * 2. **释放链**：`release` 计数 −1，归零释放（gen+1、槽位可复用）；
 * 3. **路径 A 常量不入组、不释放**（常量有效期 = 单元存活期）。
 *
 * `contains` 同时支撑 `close` 与调用 `try/finally` 的豁免判定：提升槽不随普通清理释放
 * （唯一释放路径 = `close`）。
 */
public class PromotionGroup {
    private let ids = ArrayList<Int64>()
    private let refs = HashMap<Int64, Int64>()

    public init() {}

    /**
     * 提升一个槽并计数 +1。
     *
     * 非活句柄 / 常量 → 静默忽略（常量按规则 3 不入组；陈旧 ID 无可提升）。
     * 首次 `add` 即执行原地提升（`moveOutGroup`：迁出窗口记账、ID/gen 不变、不参与重用）。
     */
    public func add(id: Int64): Unit {
        if (id <= 0 || HandleTable.isConst(id) || !HandleTable.isLiveHandle(id)) {
            return
        }
        let c = this.countOf(id)
        if (c == 0) {
            this.ids.add(id)
        }
        this.refs.add(id, c + 1)
        HandleTable.moveOutGroup([id])
    }

    /** 计数 −1；归零 ⇒ 从清单移除并释放（gen+1、可复用）。 */
    public func release(id: Int64): Unit {
        if (id <= 0 || HandleTable.isConst(id)) {
            return
        }
        let c = this.countOf(id)
        if (c == 0) {
            return
        }
        if (c > 1) {
            this.refs.add(id, c - 1)
            return
        }
        this.refs.remove(id)
        this.dropId(id)
        HandleTable.releaseEscaped(id)
    }

    /** 是否在组内（`close` / `try/finally` 豁免判定）。 */
    public func contains(id: Int64): Bool {
        this.ids.contains(id)
    }

    /** 组规模（诊断 / 容量对账）。 */
    public func size(): Int64 {
        this.ids.size
    }

    private func countOf(id: Int64): Int64 {
        match (this.refs.get(id)) {
            case Some(v) => v
            case None => 0
        }
    }

    private func dropId(id: Int64): Unit {
        var i = 0
        while (i < this.ids.size) {
            if (this.ids[i] == id) {
                this.ids.remove(at: i)
                return
            }
            i = i + 1
        }
    }
}
