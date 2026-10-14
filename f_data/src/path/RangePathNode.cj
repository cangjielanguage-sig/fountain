/*
Copyright (c) 2025 WuJingrun（吴京润）

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
package fountain::f_data.path

import std.collection.ArrayList

internal class RangePathNode <: DataPathNode {
    private static let UNSET: Int64 = Int64.Max
    RangePathNode(private let start: Int64, private let end: Int64, private let step: Int64) {}
    init(start: Int64, end: Int64) {
        this(start, end, 1)
    }
    init(end: Int64) {
        this(UNSET, end, 1)
    }
    init() {
        this(UNSET, UNSET, 1)
    }
    public func get(data: Data): Iterator<Data> {
        match (data) {
            case x: Collection<Data> =>
                let len = x.size
                let actualStart = if (start == UNSET) {
                    if (step >= 0) { 0 } else { len - 1 }
                } else {
                    normalize(start, len)
                }
                let actualEnd = if (end == UNSET) {
                    // RFC 9535：负步长且 end 缺省时为 -1（降序循环走到 0 结束）。
                    // 旧实现写 -len-1，再靠下面那次「二次归一化」折算成 -1；去掉二次归一化后必须直接用 -1。
                    if (step >= 0) { len } else { -1 }
                } else {
                    normalize(end, len)
                }
                if (step == 0) {
                    OptionIterator<Data>()
                } else {
                    buildIndices(actualStart, actualEnd, step).iterator()
                        .map {idx => IndexPathNode(idx)}
                        .flatMap {n => n.get(data).iterator()}
                }
            case _ => OptionIterator<Data>()
        }
    }
    /**
     * RFC 9535 §2.3.4.2.2 的 Normalize：非负值夹到 [0, len]，负值先按 len + i 折算再夹到 [0, len]。
     * 修复历史缺陷：旧实现对负值折算两次（`len+start` 后又 `len+actualStart`），
     * 导致 `$.arr[-7:]`（len=5）只返回后 2 个元素，而按 RFC 应返回全部 5 个。
     */
    private static func normalize(i: Int64, len: Int64): Int64 {
        if (i >= 0) {
            if (i > len) { len } else { i }
        } else {
            let shifted = len + i
            if (shifted < 0) { 0 } else { shifted }
        }
    }
    private static func buildIndices(start: Int64, end: Int64, step: Int64): ArrayList<Int64> {
        let indices = ArrayList<Int64>()
        if (step > 0) {
            var i = start
            while (i < end) {
                indices.add(i)
                i += step
            }
        } else {
            var i = start
            while (i > end) {
                indices.add(i)
                i += step
            }
        }
        indices
    }
}
