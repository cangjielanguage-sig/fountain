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
 * RFC 9535 count() function comparison in filter expressions.
 * count(@.*) > 5 — counts nodes from path and compares to a numeric value.
 */
internal class CountCmpFilter <: DataFilter {
    CountCmpFilter(private let left: DataPath, private let right: Int64, private let ordering: Ordering, private let eq: Bool) {}
    init(left: String, right: String, orderingStr: String, eqStr: String, solid: String) {
        this(compilePath(left, solid), Int64.parse(right),
            match (orderingStr) {
                case "LT" => Ordering.LT
                case "GT" => Ordering.GT
                case "EQ" => Ordering.EQ
                case _ => throw DataException('illegal Ordering string')
            }, eqStr == "true")
    }
    public func check(data: Data): Bool {
        // Count nodes from the path
        var count = 0
        let itr = left.get(data)
        for (_ in itr) {
            count++
        }
        let cmp = if (count < right) { Ordering.LT } else if (count > right) { Ordering.GT } else { Ordering.EQ }
        // NOTEQ: ordering=EQ, eq=false → return cmp != EQ
        if (ordering == Ordering.EQ && !eq) {
            cmp != Ordering.EQ
        } else {
            cmp == ordering || (eq && cmp == Ordering.EQ)
        }
    }
}
