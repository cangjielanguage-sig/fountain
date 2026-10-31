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
package fountain::f_excel

import std.collection.{ArrayList, HashMap}

/** 单元格坐标的文本键：`Sheet1!A1`。 */
internal func cellKey(sheet: String, row: Int64, col: Int64): String {
    "${sheet}!${columnLetters(col)}${row}"
}

/**
 * 依赖图（设计 7.6.2）。
 *
 * 只收录**公式单元格**：常量单元格没有出边，拓扑序里出现也没有意义。
 * 环上的节点不进入 `order()`，由 `cycles()` 单独给出。
 */
public class DependencyGraph {
    /** 节点 → 它依赖的单元格键（保持插入顺序，便于测试稳定）。 */
    private let deps = HashMap<String, ArrayList<String>>()
    private let nodeOrder = ArrayList<String>()

    public init() {}

    /** 加入一个公式单元格；语法错误时只记节点，不产生依赖。 */
    public func add(sheet: String, row: Int64, col: Int64, formula: String): Unit {
        let key = cellKey(sheet, row, col)
        if (!this.deps.contains(key)) {
            this.deps.add(key, ArrayList<String>())
            this.nodeOrder.add(key)
        }
        let list = this.deps.get(key).getOrThrow()
        match (FormulaParser.parse(formula)) {
            case Some(expr) =>
                let refs = ArrayList<(String, Int64, Int64)>()
                collectRefs(expr, sheet, refs)
                for (item in refs) {
                    let depKey = cellKey(item[0], item[1], item[2])
                    if (!list.contains(depKey)) {
                        list.add(depKey)
                    }
                }
            case None => ()
        }
    }

    /** 某格直接依赖的单元格键。 */
    public func dependenciesOf(sheet: String, row: Int64, col: Int64): ArrayList<String> {
        match (this.deps.get(cellKey(sheet, row, col))) {
            case Some(list) => list
            case None => ArrayList<String>()
        }
    }

    /** 拓扑序（依赖在前）；环上节点不出现。 */
    public func order(): ArrayList<String> {
        // 反向边：dependency → 依赖它的节点
        let dependents = HashMap<String, ArrayList<String>>()
        for (key in this.nodeOrder) {
            dependents.add(key, ArrayList<String>())
        }
        let indegree = HashMap<String, Int64>()
        for (key in this.nodeOrder) {
            var count: Int64 = 0
            let list = this.deps.get(key).getOrThrow()
            for (dep in list) {
                if (dependents.contains(dep)) {
                    count++
                    dependents.get(dep).getOrThrow().add(key)
                }
            }
            indegree.add(key, count)
        }
        let ready = ArrayList<String>()
        for (key in this.nodeOrder) {
            if (indegree.get(key).getOrThrow() == 0) {
                ready.add(key)
            }
        }
        let result = ArrayList<String>()
        var head: Int64 = 0
        while (head < ready.size) {
            let key = ready[head]
            head++
            result.add(key)
            for (next in dependents.get(key).getOrThrow()) {
                let left = indegree.get(next).getOrThrow() - 1
                indegree.add(next, left)
                if (left == 0) {
                    ready.add(next)
                }
            }
        }
        result
    }

    /** 环上的节点（Kahn 之后仍有入度的）。 */
    public func cycles(): ArrayList<String> {
        let ordered = this.order()
        let result = ArrayList<String>()
        for (key in this.nodeOrder) {
            if (!ordered.contains(key)) {
                result.add(key)
            }
        }
        result
    }

    /** 节点总数。 */
    public func size(): Int64 {
        Int64(this.nodeOrder.size)
    }
}
