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

/**
 * CountFilterResult: evaluates an inner DataFilter against each child of the
 * input data, counts how many match, and compares the count against a value.
 *
 * Enables nested function expressions like count(match(@.name, 'Alice')) > 0
 */
internal class CountFilterResult <: DataFilter {
    CountFilterResult(private let inner: DataFilter, private let right: Int64,
                      private let ordering: Ordering, private let eq: Bool) {}

    init(inner: DataFilter, right: Int64, orderingStr: String, eqStr: String) {
        this(inner, right,
            match (orderingStr) {
                case "LT" => Ordering.LT
                case "GT" => Ordering.GT
                case "EQ" => Ordering.EQ
                case _ => throw DataException('illegal Ordering string in CountFilterResult')
            }, eqStr == "true")
    }

    public func check(data: Data): Bool {
        var count = 0
        match (data) {
            case x: Iterable<Data> =>
                for (d in x) {
                    if (inner.check(d)) { count++ }
                }
            case x: Iterable<(String, Data)> =>
                for ((_, d) in x) {
                    if (inner.check(d)) { count++ }
                }
            case _ =>
                if (inner.check(data)) { count = 1 }
        }
        let cmp = if (count < right) { Ordering.LT } else if (count > right) { Ordering.GT } else { Ordering.EQ }
        if (ordering == Ordering.EQ && !eq) {
            cmp != Ordering.EQ
        } else {
            cmp == ordering || (eq && cmp == Ordering.EQ)
        }
    }
}
