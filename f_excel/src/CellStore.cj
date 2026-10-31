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

import std.collection.ArrayList

/**
 * 紧凑单元格存储（M3-d）。
 *
 * 单个按 `(row, col)` 升序排列的数组，取代 `HashMap<Int64, CellValue>`：
 * 省掉哈希桶与扩容空洞，顺序解析时是追加，随机写入是二分插入。
 * 公开 API 与稀疏语义（`Some(Empty)` ≠ 不存在）保持不变。
 */
internal class CellStore {
    private let items = ArrayList<(Int64, CellValue)>()

    func size(): Int64 {
        Int64(this.items.size)
    }

    /** 第一个 key >= target 的位置。 */
    private func lowerBound(target: Int64): Int64 {
        var low: Int64 = 0
        var high = Int64(this.items.size)
        while (low < high) {
            let mid = (low + high) / 2
            if (this.items[mid][0] < target) {
                low = mid + 1
            } else {
                high = mid
            }
        }
        low
    }

    func get(key: Int64): ?CellValue {
        let index = this.lowerBound(key)
        if (index < Int64(this.items.size) && this.items[index][0] == key) {
            return Some(this.items[index][1])
        }
        None<CellValue>
    }

    /** 存在则覆盖，不存在则按序插入。 */
    func add(key: Int64, value: CellValue): Unit {
        let index = this.lowerBound(key)
        if (index < Int64(this.items.size) && this.items[index][0] == key) {
            this.items[index] = (key, value)
        } else if (index == Int64(this.items.size)) {
            this.items.add((key, value))
        } else {
            this.items.add((key, value), at: index)
        }
    }

    func remove(key: Int64): Bool {
        let index = this.lowerBound(key)
        if (index < Int64(this.items.size) && this.items[index][0] == key) {
            this.items.remove(at: index)
            return true
        }
        false
    }

    /** 一行的 `(col, value)`，按列升序。 */
    func rowEntries(row: Int64, maxCol: Int64): ArrayList<(Int64, CellValue)> {
        let scale = EXCEL_MAX_COL + 1
        let start = row * scale
        let end = start + maxCol
        let out = ArrayList<(Int64, CellValue)>()
        var index = this.lowerBound(start)
        while (index < Int64(this.items.size) && this.items[index][0] <= end) {
            out.add((this.items[index][0] - start, this.items[index][1]))
            index++
        }
        out
    }
}
