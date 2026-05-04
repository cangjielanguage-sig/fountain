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
                } else if (start < 0) {
                    len + start
                } else {
                    start
                }
                let actualEnd = if (end == UNSET) {
                    if (step >= 0) { len } else { -len - 1 }
                } else if (end < 0) {
                    len + end
                } else {
                    end
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
